import AppKit
import NitsCore
import NitsUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WelcomeWindowController: NSWindowController {
    private let onOpenURL: (URL) -> Void
    private let onPromptOpenURL: (() -> Void)?

    init(
        onOpenURL: @escaping (URL) -> Void,
        onPromptOpenURL: (() -> Void)? = nil
    ) {
        self.onOpenURL = onOpenURL
        self.onPromptOpenURL = onPromptOpenURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 350),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow(window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        // Background frosted glass visual effect view
        let visualEffectView = NSVisualEffectView()
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .underWindowBackground
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]

        let welcomeView = WelcomeView(
            onOpenFile: { [weak self] in
                self?.promptOpenFile()
            },
            onOpenURL: { [weak self] in
                self?.onPromptOpenURL?()
            },
            onFileDropped: { [weak self] path in
                self?.onOpenURL(URL(fileURLWithPath: path))
            }
        )

        let hostingView = NSHostingView(rootView: welcomeView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = visualEffectView.bounds

        visualEffectView.addSubview(hostingView)
        window.contentView = visualEffectView
    }

    func promptOpenFile() {
        if let url = MediaOpenPanel.promptForMediaFile() {
            onOpenURL(url)
        }
    }
}
