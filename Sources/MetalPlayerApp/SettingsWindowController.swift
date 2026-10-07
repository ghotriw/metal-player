import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let onConfigurationChanged: (PlayerConfiguration) -> Void

    init(onConfigurationChanged: @escaping (PlayerConfiguration) -> Void) {
        self.onConfigurationChanged = onConfigurationChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let rootView = SettingsView(onConfigurationChanged: onConfigurationChanged)
        window.contentView = NSHostingView(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
