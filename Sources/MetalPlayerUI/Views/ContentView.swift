import AppKit
import MetalPlayerCore
import SwiftUI

public struct ContentView: View {
    public let engine: NativePlayerEngine
    public var onFileLoaded: ((URL) -> Void)?
    public var onControlsVisibilityChanged: ((Bool) -> Void)?

    @State private var isControlsVisible: Bool = true
    @State private var isUserInteracting: Bool = false
    @State private var hideTimer: Task<Void, Never>?

    public init(
        engine: NativePlayerEngine,
        onFileLoaded: ((URL) -> Void)? = nil,
        onControlsVisibilityChanged: ((Bool) -> Void)? = nil
    ) {
        self.engine = engine
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

            // Controls Overlay
            if isControlsVisible || !engine.isLoaded || isUserInteracting {
                ControlsOverlay(engine: engine, isInteracting: $isUserInteracting) {
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
        .onAppear {
            onControlsVisibilityChanged?(isControlsVisible)
        }
        // Keyboard shortcuts
        .onKeyPress(.space) {
            engine.togglePlayPause()
            showControlsTemporarily()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            engine.seekRelative(by: -5)
            showControlsTemporarily()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.seekRelative(by: 5)
            showControlsTemporarily()
            return .handled
        }
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
