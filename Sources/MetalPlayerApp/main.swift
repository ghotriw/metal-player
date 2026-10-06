import AppKit
import SwiftUI
import MetalPlayerUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "MetalPlayer"
window.center()
window.contentView = NSHostingView(rootView: ContentView())
window.makeKeyAndOrderFront(nil)

app.activate(ignoringOtherApps: true)

print("Starting NSApplication.run() - window is visible:", window.isVisible)
app.run()
