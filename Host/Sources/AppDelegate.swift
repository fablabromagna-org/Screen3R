//
//  AppDelegate.swift
//  Screen3R (host)
//
//  Menu bar UI: finds viewers on the local network (Bonjour), connects,
//  creates the virtual display and starts streaming it.
//

import AppKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case idle
        case connecting(String)
        case streaming(String, Int, Int)
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var browser: NWBrowser?
    private var discovered: [(name: String, endpoint: NWEndpoint)] = []

    private var state: State = .idle
    private var peer: PeerConnection?
    private var virtualDisplay: VirtualDisplay?
    private var streamer: Streamer?
    private var cursorTracker: CursorTracker?
    private var inputInjector: InputInjector?
    private var inputEffective: Bool?       // what the current session was last told
    private var viewerSupportsInput = false
    private var statsText: String?
    private var decoderText: String?
    private var lastError: String?
    private var pairingAlert: NSAlert?   // shown (modal) while the user compares pairing codes
    private var resettingScreen = false  // Reset Old Mac's Screen in progress

    private var quality: Quality {
        get { Quality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .balanced }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "quality") }
    }

    /// Let the old Mac's keyboard and mouse control this Mac (default off).
    private var allowInput: Bool {
        get { UserDefaults.standard.bool(forKey: "allowInput") }
        set { UserDefaults.standard.set(newValue, forKey: "allowInput") }
    }

    /// Encrypt the stream (default on). Takes effect on the next connection.
    private var encryptStream: Bool {
        get { UserDefaults.standard.object(forKey: "encrypt") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "encrypt") }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Screen3R")
                ?? NSImage(systemSymbolName: "display", accessibilityDescription: "Screen3R")
            if button.image == nil { button.title = "RD" }
        }
        menu.delegate = self
        statusItem.menu = menu

        // Ask for Screen Recording permission up front (shows the system prompt once).
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        startBrowsing()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown()
    }

    // MARK: - Discovery

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: RD.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            var list: [(String, NWEndpoint)] = []
            for result in results {
                if case let .service(rawName, _, _, _) = result.endpoint {
                    let name = sanitizedName(rawName)
                    guard !seen.contains(name) else { continue }
                    seen.insert(name)
                    list.append((name, result.endpoint))
                }
            }
            list.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            let snapshot = list.map { (name: $0.0, endpoint: $0.1) }   // immutable copy for the main queue
            DispatchQueue.main.async { self?.discovered = snapshot }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("Screen3R: Bonjour browsing failed: %@", error.localizedDescription)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch state {
        case .idle:
            menu.addItem(disabled("Not connected"))
        case .connecting(let name):
            menu.addItem(disabled("Connecting to \(name)…"))
        case .streaming(let name, let w, let h):
            menu.addItem(disabled("Streaming to \(name) — \(w)×\(h)"))
            if let statsText { menu.addItem(disabled(statsText)) }
            if let decoderText { menu.addItem(disabled(decoderText)) }
            if let inputText = inputStatusText() { menu.addItem(disabled(inputText)) }
        }
        if let lastError, case .idle = state {
            let item = disabled("⚠︎ " + lastError)
            item.toolTip = lastError
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if case .idle = state {
            menu.addItem(disabled(discovered.isEmpty ? "Searching for viewers…" : "Available screens:"))
            for (index, entry) in discovered.enumerated() {
                let item = NSMenuItem(title: "    " + entry.name, action: #selector(connectToDiscovered(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            let manual = NSMenuItem(title: "Connect to IP Address…", action: #selector(connectManually), keyEquivalent: "")
            manual.target = self
            menu.addItem(manual)
        } else {
            if case .streaming = state, let display = virtualDisplay {
                let mirror = NSMenuItem(title: "Mirror Main Display", action: #selector(toggleMirror),
                                        keyEquivalent: "m")
                mirror.target = self
                mirror.state = CGDisplayMirrorsDisplay(display.displayID) != 0 ? .on : .off
                menu.addItem(mirror)
                let reset = NSMenuItem(title: "Reset Old Mac's Screen", action: #selector(resetOldMacScreen),
                                       keyEquivalent: "")
                reset.target = self
                reset.toolTip = "Use it if the old Mac stays on a full-screen app (e.g. Windows App) and won't switch to a desktop."
                menu.addItem(reset)
            }
            let item = NSMenuItem(title: "Disconnect", action: #selector(disconnectClicked), keyEquivalent: "d")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let input = NSMenuItem(title: "Use Old Mac's Keyboard & Mouse", action: #selector(toggleInput), keyEquivalent: "")
        input.target = self
        input.state = allowInput ? .on : .off
        input.toolTip = "The keyboard and mouse of the old Mac control this Mac. Needs Encrypt Stream."
        menu.addItem(input)

        let qualityItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let qualityMenu = NSMenu()
        for q in Quality.allCases {
            let item = NSMenuItem(title: q.title, action: #selector(qualityClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q.rawValue
            item.state = (q == quality) ? .on : .off
            qualityMenu.addItem(item)
        }
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)

        let securityItem = NSMenuItem(title: "Security", action: nil, keyEquivalent: "")
        let securityMenu = NSMenu()
        let encryptItem = NSMenuItem(title: "Encrypt Stream", action: #selector(toggleEncryption), keyEquivalent: "")
        encryptItem.target = self
        encryptItem.state = encryptStream ? .on : .off
        encryptItem.toolTip = "Applies from the next connection."
        securityMenu.addItem(encryptItem)
        let forget = NSMenuItem(title: "Forget Paired Screens…", action: #selector(forgetPairings), keyEquivalent: "")
        forget.target = self
        securityMenu.addItem(forget)
        securityItem.submenu = securityMenu
        menu.addItem(securityItem)

        let displays = NSMenuItem(title: "Arrange Displays…", action: #selector(openDisplaySettings), keyEquivalent: "")
        displays.target = self
        menu.addItem(displays)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screen3R", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEncryption() {
        encryptStream.toggle()
    }

    // MARK: - Keyboard & mouse of the old Mac

    @objc private func toggleInput() {
        allowInput.toggle()
        if allowInput && !InputInjector.hasPermission {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Allow Screen3R to control this Mac"
            alert.informativeText = """
                To type and click with the old Mac's keyboard and mouse, turn on Screen3R in \
                System Settings › Privacy & Security › Accessibility.

                Screen3R starts using them as soon as the permission is on (if it doesn't, quit \
                and reopen Screen3R).
                """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = CGRequestPostEventAccess()   // also adds Screen3R to the list in Settings
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        updateInput()
    }

    /// Tells the session whether to accept input; called on changes and every second
    /// (to notice the Accessibility permission being granted).
    private func updateInput() {
        guard case .streaming = state, let peer else { return }
        let effective = allowInput && viewerSupportsInput && peer.encrypt && InputInjector.hasPermission
        guard effective != inputEffective else { return }
        inputEffective = effective
        peer.setInputEnabled(effective)
    }

    private func inputStatusText() -> String? {
        guard allowInput, case .streaming = state, let peer else { return nil }
        if !viewerSupportsInput { return "Keyboard & mouse: update Screen3R Viewer on the old Mac" }
        if !peer.encrypt { return "Keyboard & mouse: turn on Security › Encrypt Stream, then reconnect" }
        if !InputInjector.hasPermission { return "⚠︎ Keyboard & mouse: allow Screen3R in Privacy & Security › Accessibility" }
        return "Keyboard & mouse: the old Mac's are in use"
    }

    @objc private func forgetPairings() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget all paired screens?"
        alert.informativeText = "Next time you connect, you will have to pair again by comparing the code shown on both Macs."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PairingKeychain.removeAll()
    }

    /// Switches the old Mac between showing its own extra desktop (extended) and a copy of
    /// the main display (mirrored), like the option in System Settings › Displays.
    @objc private func toggleMirror() {
        guard let display = virtualDisplay else { return }
        let mirrored = CGDisplayMirrorsDisplay(display.displayID) != 0
        var main = CGMainDisplayID()
        if main == display.displayID {
            // The menu bar was moved to the virtual display: mirror the first other display.
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            CGGetActiveDisplayList(16, &ids, &count)
            guard let other = ids.prefix(Int(count)).first(where: { $0 != display.displayID }) else { return }
            main = other
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, display.displayID, mirrored ? 0 : main)
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            lastError = "Could not change the mirroring setting."
        }
    }

    /// macOS sometimes leaves the old Mac's screen stuck on a full-screen Space (a Windows App
    /// session, for instance) that can't be switched away. Mirroring and un-mirroring the display
    /// makes macOS set up its Spaces again: the same as choosing Mirror Main Display twice.
    @objc private func resetOldMacScreen() {
        guard let display = virtualDisplay, !resettingScreen else { return }
        let id = display.displayID
        resettingScreen = true
        toggleMirror()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.resettingScreen = false
            guard let current = self.virtualDisplay, current.displayID == id else { return }   // disconnected meanwhile
            self.toggleMirror()
        }
    }

    @objc private func connectToDiscovered(_ sender: NSMenuItem) {
        guard discovered.indices.contains(sender.tag) else { return }
        let entry = discovered[sender.tag]
        connect(to: entry.endpoint, name: entry.name)
    }

    @objc private func connectManually() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect to a viewer"
        alert.informativeText = "Enter the IP address shown on the iMac screen."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "192.168.1.20"
        field.stringValue = UserDefaults.standard.string(forKey: "lastManualAddress") ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UserDefaults.standard.set(text, forKey: "lastManualAddress")
        var host = text
        var port = RD.port
        // Accept "host:port" (IPv4 or hostname).
        if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1,
           let p = UInt16(text[text.index(after: colon)...]) {
            host = String(text[..<colon])
            port = p
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), name: host)
    }

    @objc private func disconnectClicked() {
        disconnect(reason: nil)
    }

    @objc private func qualityClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let q = Quality(rawValue: raw) else { return }
        quality = q
        streamer?.setQuality(q)
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Session

    private func connect(to endpoint: NWEndpoint, name: String) {
        teardown()
        lastError = nil
        let peer = PeerConnection(endpoint: endpoint, displayName: name, encrypt: encryptStream)
        peer.onHello = { [weak self, weak peer] hello in
            guard let self, let peer, self.peer === peer else { return }
            self.startStreaming(hello, peer: peer)
        }
        peer.onClosed = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.disconnect(reason: reason)
        }
        peer.onStats = { [weak self] stats in
            self?.updateInput()
            self?.statsText = String(format: "%ld fps · %.1f Mbit/s · %.0f ms", stats.fps, stats.mbps, stats.rttMs)
                + (stats.encrypted ? " · encrypted" : " · not encrypted")
            if let v = stats.viewer {
                let kind = v.hw == true ? "hardware" : (v.hw == false ? "software" : "?")
                self?.decoderText = String(format: "Viewer decoder: %@ · %.1f ms/frame", kind, v.decodeMs ?? 0)
            }
        }
        peer.onPairingCode = { [weak self, weak peer] code, viewerName, decide in
            guard let self, let peer, self.peer === peer else { return decide(false) }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Pair with “\(viewerName)”?"
            alert.informativeText = """
                Check that the old Mac shows the same code:

                \(code)

                Pair only if the codes match. If this is not the first Mac paired with that screen, \
                also press Return on the old Mac.
                """
            alert.addButton(withTitle: "Codes Match – Pair")
            alert.addButton(withTitle: "Cancel")
            self.pairingAlert = alert
            let response = alert.runModal()   // aborted by teardown() if the connection ends
            if self.pairingAlert === alert { self.pairingAlert = nil }
            decide(response == .alertFirstButtonReturn)
        }
        self.peer = peer
        state = .connecting(name)
        peer.start()
    }

    private func startStreaming(_ hello: ViewerHello, peer: PeerConnection) {
        // Sanity: even sizes, within what H.264 level 5.2 / the encoder handle comfortably.
        let width = max(640, min(4096, hello.width & ~1))
        let height = max(480, min(2304, hello.height & ~1))

        let viewerName = sanitizedName(hello.name)
        guard let display = VirtualDisplay(name: viewerName, width: width, height: height,
                                           serial: VirtualDisplay.stableSerial(for: viewerName)) else {
            disconnect(reason: "Could not create the virtual display.")
            return
        }
        virtualDisplay = display

        // Viewers that can draw the pointer themselves get it as tiny position messages
        // (~8 ms polling) instead of inside the video: the mouse no longer waits for
        // capture → encode → decode.
        let localCursor = hello.features?.contains("cursor") ?? false
        let streamer = Streamer(displayID: display.displayID, width: width, height: height,
                                quality: quality, showsCursor: !localCursor)
        streamer.canSend = { [weak peer] in peer?.canSendFrame() ?? false }
        streamer.onFormat = { [weak peer] sets, nal in peer?.sendFormat(sets, nalLength: nal) }
        streamer.onFrame = { [weak peer] data, key in peer?.sendFrame(data, keyframe: key) }
        streamer.onError = { [weak self, weak streamer] message in
            DispatchQueue.main.async {
                // Ignore errors from a streamer that has already been replaced/torn down.
                guard let self, let streamer, self.streamer === streamer else { return }
                self.disconnect(reason: message)
            }
        }
        peer.onKeyframeRequest = { [weak streamer] in streamer?.requestKeyframe() }
        self.streamer = streamer
        state = .streaming(viewerName, width, height)

        if localCursor {
            let tracker = CursorTracker(displayID: display.displayID, streamWidth: width, streamHeight: height)
            tracker.onPosition = { [weak peer] x, y, visible, seq in
                peer?.sendCursorPosition(x: x, y: y, visible: visible, inputSeq: seq)
            }
            tracker.onImage = { [weak peer] cursor in peer?.sendCursorImage(cursor) }
            tracker.start()
            cursorTracker = tracker
        }

        // Keyboard & mouse of the old Mac: the injector is always ready, the session only
        // forwards events while the user allows it (see updateInput).
        viewerSupportsInput = localCursor && (hello.features?.contains("input") ?? false)
        if viewerSupportsInput {
            let injector = InputInjector(displayID: display.displayID, streamWidth: width, streamHeight: height)
            injector.onMoved = { [weak tracker = cursorTracker] location, seq in tracker?.injected(at: location, seq: seq) }
            peer.onInput = { [weak injector] event in injector?.handle(event) }
            inputInjector = injector
        }
        inputEffective = nil
        updateInput()

        // The Task inherits the main actor from this method; start() itself runs off the main actor.
        Task { [weak self] in
            do {
                try await streamer.start()
            } catch {
                guard let self, self.streamer === streamer else { return }
                self.disconnect(reason: "Screen capture failed: \(error.localizedDescription) — allow Screen3R in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app.")
            }
        }
    }

    private func disconnect(reason: String?) {
        teardown()
        if let reason {
            lastError = reason
            NSLog("Screen3R: %@", reason)
        }
    }

    private func teardown() {
        if pairingAlert != nil {
            // The connection is gone (cancelled, timed out, refused by the viewer): don't leave
            // a pairing question on screen that no longer leads anywhere.
            pairingAlert = nil
            NSApp.abortModal()
        }
        inputInjector?.releaseAll()   // before anything else: no key may stay pressed
        inputInjector = nil
        inputEffective = nil
        viewerSupportsInput = false
        cursorTracker?.stop()
        cursorTracker = nil
        streamer?.stop()
        streamer = nil
        virtualDisplay = nil   // removes the display
        if let peer {
            peer.onClosed = nil
            peer.onHello = nil
            peer.onStats = nil
            peer.cancel()
        }
        peer = nil
        statsText = nil
        decoderText = nil
        state = .idle
    }
}
