import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let engine: NativePlayerEngine
    let uiState = PlayerUIState()
    var onClose: (() -> Void)?
    var onKeyStatusChanged: ((Bool) -> Void)?

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
        let window = PlayerWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        window.actionHandler = self

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
            uiState: uiState,
            onFileLoaded: { [weak self] url in
                self?.window?.title = url.lastPathComponent
            },
            onControlsVisibilityChanged: { [weak self] isVisible in
                self?.updateTrafficLightsVisibility(isVisible: isVisible)
                if !isVisible, self?.window?.isKeyWindow == true {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            },
            onToggleFullscreen: { [weak self] in
                self?.toggleFullscreen()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        window.initialFirstResponder = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openFile(url: URL) {
        openStream(url: url, headers: [:])
    }

    func openStream(url: URL, headers: [String: String]) {
        let isNetwork = MediaDemuxer.isNetworkURL(url.absoluteString)
        window?.title =
            isNetwork
            ? (url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent)
            : url.lastPathComponent
        let pathString = isNetwork ? url.absoluteString : url.path
        engine.load(path: pathString, headers: headers)
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        updateTrafficLightsVisibility(isVisible: true)
        onKeyStatusChanged?(true)
    }

    func exitFullscreen() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        if window?.styleMask.contains(.fullScreen) == true {
            exitFullscreen()
        } else {
            super.cancelOperation(sender)
        }
    }

    private func updateTrafficLightsVisibility(isVisible: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
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

    func windowDidBecomeKey(_ notification: Notification) {
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        onKeyStatusChanged?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onKeyStatusChanged?(false)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: true)
        window?.titleVisibility = .visible
        window?.titlebarAppearsTransparent = false
        uiState.isFullscreen = true
        for button in standardButtons {
            button.alphaValue = 1.0
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        updateToolbar(isFullscreen: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.titleVisibility = .hidden
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: false)
        window?.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    func windowWillClose(_ notification: Notification) {
        engine.stop()
        onClose?()
    }
}

extension PlayerWindowController: PlayerActions {
    var renderMode: RenderMode {
        get { engine.renderMode }
        set {
            engine.renderMode = newValue
            uiState.showControlsTemporarily()
        }
    }

    var metalSharpness: Float {
        get { engine.metalSharpness }
        set {
            engine.metalSharpness = newValue
            uiState.showControlsTemporarily()
        }
    }

    var isMuted: Bool {
        engine.isMuted
    }

    var showDebugHUD: Bool {
        engine.showDebugHUD
    }

    func togglePlayPause() {
        engine.togglePlayPause()
        uiState.showControlsTemporarily()
    }

    func stepFrameForward() {
        engine.stepFrameForward()
        uiState.showControlsTemporarily()
    }

    func stepFrameBackward() {
        engine.stepFrameBackward()
        uiState.showControlsTemporarily()
    }

    func seekRelative(by seconds: Double) {
        engine.seekRelative(by: seconds)
        uiState.showControlsTemporarily()
    }

    func stepVolume(by delta: Float) {
        engine.stepVolume(by: delta)
        uiState.showControlsTemporarily()
    }

    func toggleMute() {
        engine.toggleMute()
        uiState.showControlsTemporarily()
    }

    func toggleDebugHUD() {
        withAnimation {
            engine.toggleDebugHUD()
        }
    }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
}
