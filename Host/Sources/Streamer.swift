//
//  Streamer.swift
//  Screen3R (host)
//
//  Captures one display with ScreenCaptureKit and encodes it to H.264 with
//  VideoToolbox in low-latency mode. H.264 (not HEVC) because a 2011 iMac
//  cannot decode HEVC.
//
//  Flow control: before encoding a captured frame we ask `canSend()`; if too
//  many frames are still unacknowledged by the viewer we skip it (skipping
//  *input* frames is always safe for H.264 — the encoder just references the
//  last frame it actually encoded). A small timer then re-encodes the latest
//  image once the network catches up, and a couple of extra times when the
//  screen goes still, so static text converges to full sharpness.
//

import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia

enum Quality: String, CaseIterable {
    case wifi, balanced, high

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi (12 Mbit/s)"
        case .balanced: return "Balanced (25 Mbit/s)"
        case .high: return "Ethernet (50 Mbit/s)"
        }
    }

    var bitrate: Int {
        switch self {
        case .wifi: return 12_000_000
        case .balanced: return 25_000_000
        case .high: return 50_000_000
        }
    }

    /// Upper bound on quantizer: keeps text readable at the cost of bitrate spikes.
    var maxQP: Int? {
        switch self {
        case .wifi: return nil
        case .balanced: return 34
        case .high: return 30
        }
    }
}

// Thread safety is handled by hand: mutable state lives on `queue` (see comments).
final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    private(set) var quality: Quality
    /// false when the viewer draws the pointer itself (see CursorTracker).
    let showsCursor: Bool

    /// Called on the encoder's thread. Parameter sets (SPS, PPS) + NAL length size.
    var onFormat: (([Data], Int32) -> Void)?
    /// Called on the encoder's thread. AVCC (length-prefixed) data.
    var onFrame: ((Data, Bool) -> Void)?
    /// Asked on the capture queue before every encode.
    var canSend: (() -> Bool)?
    /// Called on an arbitrary thread when capture stops unexpectedly.
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "screen3r.capture", qos: .userInteractive)
    private var captureStream: SCStream?   // guarded by `queue`
    private var session: VTCompressionSession?
    private var timer: DispatchSourceTimer?

    // State below is only touched on `queue`.
    private var lastBuffer: CVPixelBuffer?
    private var lastEncode: CFAbsoluteTime = 0
    private var pendingChange = false
    private var refreshPasses = 0
    private var forceKeyframe = true
    private var lastRequestedKeyframe: CFAbsoluteTime = 0
    private var stopped = false

    /// After the screen has been still this long, the last image is re-encoded once at
    /// near-lossless quality ("refinement"), so small text becomes sharp (an "i" stays an "i").
    private static let refreshDelay: CFAbsoluteTime = 0.15
    private static let refineQP = 14
    private static let maxRefreshPasses = 1

    init(displayID: CGDirectDisplayID, width: Int, height: Int, quality: Quality, showsCursor: Bool) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.quality = quality
        self.showsCursor = showsCursor
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        let display = try await findDisplay()

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // colorMatrix left at its default (BT.709); the CGDisplayStream constants are deprecated.
        config.showsCursor = showsCursor
        config.queueDepth = 4
        config.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        // stop() may have been called while we were waiting for the display.
        let proceed: Bool = try queue.sync {
            guard !stopped else { return false }
            try makeEncoder()
            captureStream = stream
            return true
        }
        guard proceed else { return }

        try await stream.startCapture()
        if queue.sync(execute: { stopped }) {
            // Stopped while startCapture() was in flight: make sure capture does not keep running.
            try? await stream.stopCapture()
            return
        }
        queue.async { if !self.stopped { self.startTimer() } }
    }

    func stop() {
        let stream: SCStream? = queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            lastBuffer = nil
            if let session {
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            let s = captureStream
            captureStream = nil
            return s
        }
        stream?.stopCapture { _ in }
    }

    /// Keyframe requests from the viewer are rate-limited: a keyframe is big and expensive,
    /// and a misbehaving viewer must not be able to make us send one on every tick.
    func requestKeyframe() {
        queue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastRequestedKeyframe >= 0.5 else { return }
            self.lastRequestedKeyframe = now
            self.forceKeyframe = true
        }
    }

    func setQuality(_ q: Quality) {
        queue.async {
            self.quality = q
            if let session = self.session { self.applyRateSettings(session) }
        }
    }

    // MARK: - Capture

    /// The virtual display takes a moment to show up in ScreenCaptureKit.
    private func findDisplay() async throws -> SCDisplay {
        for _ in 0..<40 {
            if queue.sync(execute: { stopped }) { throw CancellationError() }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let d = content.displays.first(where: { $0.displayID == displayID }) {
                return d
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw NSError(domain: "Screen3R", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The virtual display did not appear in ScreenCaptureKit."])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped else { return }
        // Only "complete" frames carry new pixels; "idle" frames mean nothing changed.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastBuffer = pixelBuffer
        refreshPasses = 0
        if canSend?() ?? true {
            encode(pixelBuffer)
            pendingChange = false
        } else {
            pendingChange = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.stopped else { return }
            self.onError?("Screen capture stopped: \(error.localizedDescription)")
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Runs on `queue` every 50 ms.
    private func tick() {
        guard !stopped, let buffer = lastBuffer, canSend?() ?? true else { return }
        if pendingChange || forceKeyframe {
            pendingChange = false
            encode(buffer)
            return
        }
        if refreshPasses < Self.maxRefreshPasses,
           CFAbsoluteTimeGetCurrent() - lastEncode > Self.refreshDelay {
            refreshPasses += 1
            encode(buffer, refine: refreshPasses == 1)
        }
    }

    // MARK: - Encoding

    private func makeEncoder() throws {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession)
        guard status == noErr, let session = newSession else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the H.264 encoder (\(status))."])
        }

        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))
        // Keyframes only on demand (start, viewer request): they are big and cause a hiccup.
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 60 * 60 * 10))
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 60 * 10))
        set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        applyRateSettings(session)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    private func applyRateSettings(_ session: VTCompressionSession) {
        set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: quality.bitrate))
        // 51 = no cap; set it explicitly so switching back to Wi-Fi removes a previous cap.
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, NSNumber(value: quality.maxQP ?? 51))
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            NSLog("Screen3R: encoder property %@ not accepted (%d)", key as String, status)
        }
    }

    /// Runs on `queue`.
    private func encode(_ pixelBuffer: CVPixelBuffer, refine: Bool = false) {
        guard let session else { return }
        if refine {
            // Cap the quantizer very low for this one frame. The frame is big (a few hundred KB
            // for a screen full of text) but it is sent only once, when nothing is moving.
            set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, NSNumber(value: Self.refineQP))
        }
        defer {
            if refine {
                // Make sure the refinement frame has been encoded before restoring the normal cap.
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                applyRateSettings(session)
            }
        }
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        lastEncode = CFAbsoluteTimeGetCurrent()
        // Host clock: always increasing, also for re-encodes of the same buffer.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer, let self else { return }
                self.handleEncoded(sampleBuffer)
            }
        if status != noErr {
            NSLog("Screen3R: encode failed (%d)", status)
            forceKeyframe = true
        }
    }

    /// Runs on VideoToolbox's output thread (callbacks are delivered in order).
    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        if stopped { return }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let params = Self.parameterSets(of: format) {
            onFormat?(params.0, params.1)
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        onFrame?(data, isKeyframe)
    }

    private static func parameterSets(of format: CMFormatDescription) -> ([Data], Int32)? {
        var count = 0
        var nalLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength) == noErr,
              count > 0 else { return nil }

        var sets: [Data] = []
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, nalLength)
    }
}
