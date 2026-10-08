import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
public final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    public let engine: NativePlayerEngine
    public let uiState = PlayerUIState()
    public var onClose: (() -> Void)?
    public var onKeyStatusChanged: ((Bool) -> Void)?

    public func applyConfiguration(_ config: PlayerConfiguration) {
        engine.isToneMappingPermitted = config.enableToneMapping
        engine.metalSharpness = config.sharpness
        engine.metalTargetNits = config.targetNits
    }

    private var standardButtons: [NSButton] {
        ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
            window?.standardWindowButton($0)
        }
    }

    public init(configuration: PlayerConfiguration = PlayerConfiguration()) {
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
        .focusedSceneValue(\.playerActions, self)

        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        window.initialFirstResponder = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func openFile(url: URL) {
        openStream(url: url, headers: [:])
    }

    public func openStream(url: URL, headers: [String: String]) {
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

    public func exitFullscreen() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    public override func cancelOperation(_ sender: Any?) {
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

    public func windowDidBecomeKey(_ notification: Notification) {
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        onKeyStatusChanged?(true)
    }

    public func windowDidResignKey(_ notification: Notification) {
        onKeyStatusChanged?(false)
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: true)
        window?.titleVisibility = .visible
        window?.titlebarAppearsTransparent = false
        uiState.isFullscreen = true
        for button in standardButtons {
            button.alphaValue = 1.0
        }
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        updateToolbar(isFullscreen: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        window?.titleVisibility = .hidden
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: false)
        window?.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    public func windowWillClose(_ notification: Notification) {
        engine.stop()
        onClose?()
    }
}

extension PlayerWindowController: PlayerActions {
    public var renderMode: RenderMode {
        get { engine.renderMode }
        set {
            engine.renderMode = newValue
            uiState.showControlsTemporarily()
        }
    }

    public var metalSharpness: Float {
        get { engine.metalSharpness }
        set {
            engine.metalSharpness = newValue
            uiState.showControlsTemporarily()
        }
    }

    public var isMuted: Bool {
        engine.isMuted
    }

    public var showDebugHUD: Bool {
        engine.showDebugHUD
    }

    public func togglePlayPause() {
        engine.togglePlayPause()
        uiState.showControlsTemporarily()
    }

    public func stepFrameForward() {
        engine.stepFrameForward()
        uiState.showControlsTemporarily()
    }

    public func stepFrameBackward() {
        engine.stepFrameBackward()
        uiState.showControlsTemporarily()
    }

    public func seekRelative(by seconds: Double) {
        engine.seekRelative(by: seconds)
        uiState.showControlsTemporarily()
    }

    public func stepVolume(by delta: Float) {
        engine.stepVolume(by: delta)
        uiState.showControlsTemporarily()
    }

    public func toggleMute() {
        engine.toggleMute()
        uiState.showControlsTemporarily()
    }

    public func toggleDebugHUD() {
        withAnimation {
            engine.toggleDebugHUD()
        }
    }

    public func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
}
