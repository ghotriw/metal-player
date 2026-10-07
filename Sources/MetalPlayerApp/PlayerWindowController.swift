import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let engine: NativePlayerEngine
    var onClose: (() -> Void)?

    func applyConfiguration(_ config: PlayerConfiguration) {
        engine.isToneMappingPermitted = config.enableToneMapping
        engine.metalSharpness = config.sharpness
        engine.metalTargetNits = config.targetNits
    }

    private var standardButtons: [NSButton] {
        ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
            window?.standardWindowButton($0)
        }
    }

    init(configuration: PlayerConfiguration = PlayerConfiguration()) {
        self.engine = NativePlayerEngine(configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "MetalPlayer"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true

        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        updateToolbar(isFullscreen: false)

        let contentView = ContentView(
            engine: engine,
            onFileLoaded: { [weak self] url in
                self?.window?.title = url.lastPathComponent
            },
            onControlsVisibilityChanged: { [weak self] isVisible in
                self?.updateTrafficLightsVisibility(isVisible: isVisible)
            }
        )
        window.contentView = NSHostingView(rootView: contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openFile(url: URL) {
        window?.title = url.lastPathComponent
        engine.load(path: url.path)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        updateTrafficLightsVisibility(isVisible: true)
    }

    private func updateTrafficLightsVisibility(isVisible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for button in standardButtons {
                button.animator().alphaValue = isVisible ? 1.0 : 0.0
            }
        }
    }

    private func updateToolbar(isFullscreen: Bool) {
        guard let window else { return }
        if isFullscreen {
            window.toolbar = nil
        } else {
            let toolbar = NSToolbar()
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: false)
    }

    func windowWillClose(_ notification: Notification) {
        engine.pause()
        onClose?()
    }
}
