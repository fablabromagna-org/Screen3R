//
//  VirtualDisplay.swift
//  Screen3R (host)
//
//  Creates a real (virtual) monitor that macOS treats like any other display:
//  you can drag windows onto it and arrange it in System Settings › Displays.
//  The display exists as long as this object is alive.
//

import Foundation
import CoreGraphics

final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let width: Int
    let height: Int

    var displayID: CGDirectDisplayID { display.displayID }

    /// - Parameters:
    ///   - serial: keep it stable per viewer so macOS remembers the arrangement.
    init?(name: String, width: Int, height: Int, serial: UInt32) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // Physical size: assume ~102 ppi (a 21.5" 1080p iMac). Only used by macOS for scaling hints.
        let mmPerPixel = 25.4 / 102.5
        descriptor.sizeInMillimeters = CGSize(width: Double(width) * mmPerPixel,
                                              height: Double(height) * mmPerPixel)
        descriptor.vendorID = 0x5244   // "RD"
        descriptor.productID = 0x0001
        descriptor.serialNum = serial

        guard let d = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)
        ]
        guard d.apply(settings), d.displayID != 0 else { return nil }

        self.display = d
        self.width = width
        self.height = height
    }

    /// FNV-1a hash of the viewer name, so each viewer gets its own stable serial.
    static func stableSerial(for name: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash == 0 ? 1 : hash
    }
}
