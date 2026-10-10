import AppKit
import NitsCore
import NitsUI
import SwiftUI

@MainActor
public final class LogViewerWindowController: NSWindowController {
    public static let shared = LogViewerWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 850, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nits Console & Logs"
        window.minSize = NSSize(width: 600, height: 350)
        window.isReleasedWhenClosed = false
        window.center()

        let rootView = LogViewerView()
        window.contentView = NSHostingView(rootView: rootView)

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showLogs() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
