import AppKit
import MetalPlayerCore
import SwiftUI

public struct ContentView: View {
    public let engine: NativePlayerEngine
    public var uiState: PlayerUIState
    public let actions: any PlayerActions
    public var onFileLoaded: ((URL) -> Void)?
    public var onControlsVisibilityChanged: ((Bool) -> Void)?

    @State private var isControlsVisible: Bool = true
    @State private var isUserInteracting: Bool = false
    @State private var hideTimer: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    public init(
        engine: NativePlayerEngine,
        uiState: PlayerUIState = PlayerUIState(),
        actions: any PlayerActions,
        onFileLoaded: ((URL) -> Void)? = nil,
        onControlsVisibilityChanged: ((Bool) -> Void)? = nil
    ) {
        self.engine = engine
        self.uiState = uiState
        self.actions = actions
        self.onFileLoaded = onFileLoaded
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
    }

    public var body: some View {
        ZStack {
            // Video Surface View
            VideoSurfaceView(engine: engine) { filePath in
                let url = URL(fileURLWithPath: filePath)
                engine.load(path: filePath)
                onFileLoaded?(url)
                scheduleControlsHide()
            }
            .ignoresSafeArea()

            // Subtle loading indicator while engine is parsing/decoding first frame
            if !engine.isLoaded {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .shadow(radius: 8)
            }

            // Performance Telemetry HUD
            if engine.showDebugHUD {
                VStack {
                    HStack {
                        Spacer()
                        PerformanceHUDView(engine: engine)
                            .padding(.top, 46)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Controls Overlay
            if isControlsVisible || !engine.isLoaded || isUserInteracting {
                ControlsOverlay(
                    engine: engine,
                    isInteracting: $isUserInteracting,
                    isFullscreen: uiState.isFullscreen
                ) {
                    openFileDialog()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showControlsTemporarily()
            case .ended:
                break
            }
        }
        .onChange(of: isUserInteracting) { _, interacting in
            if interacting {
                hideTimer?.cancel()
                withAnimation { isControlsVisible = true }
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: isControlsVisible) { _, visible in
            onControlsVisibilityChanged?(visible)
        }
        .onChange(of: uiState.controlsVisibilityTrigger) { _, _ in
            showControlsTemporarily()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .onAppear {
            onControlsVisibilityChanged?(isControlsVisible)
        }
        // Scene and focus actions for application menu shortcuts
        .focusedSceneValue(\.playerActions, actions)
        .focusedValue(\.playerActions, actions)
    }

    private func showControlsTemporarily() {
        withAnimation {
            isControlsVisible = true
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        guard engine.isLoaded, !isUserInteracting else { return }
        hideTimer?.cancel()
        hideTimer = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled && !isUserInteracting {
                withAnimation {
                    isControlsVisible = false
                }
            }
        }
    }

    private func openFileDialog() {
        if let url = MediaOpenPanel.promptForMediaFile() {
            engine.load(path: url.path)
            onFileLoaded?(url)
            scheduleControlsHide()
        }
    }
}
