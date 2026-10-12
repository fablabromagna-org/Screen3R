//
//  main.swift
//  Screen3R (host) — menu bar app, no Dock icon (LSUIElement).
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
