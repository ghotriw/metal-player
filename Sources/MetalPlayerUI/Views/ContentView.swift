import SwiftUI
import AppKit
import MetalPlayerCore

public struct ContentView: View {
    @State private var engine = NativePlayerEngine()
    @State private var isControlsVisible: Bool = true
    @State private var isUserInteracting: Bool = false
    @State private var hideTimer: Task<Void, Never>?

    public init() {}

    public var body: some View {
        ZStack {
            // Video Surface View
            VideoSurfaceView(engine: engine) { filePath in
                engine.load(path: filePath)
                scheduleControlsHide()
            }
            .ignoresSafeArea()

            // Empty state placeholder
            if !engine.isLoaded {
                VStack(spacing: 16) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("Drop video file here")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))

                    Button("Open File") {
                        openFileDialog()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(40)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
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
        .onAppear {
            if CommandLine.arguments.count > 1 {
                let filePath = CommandLine.arguments[1]
                if FileManager.default.fileExists(atPath: filePath) {
                    engine.load(path: filePath)
                    scheduleControlsHide()
                }
            }
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie]

        if panel.runModal() == .OK, let url = panel.url {
            engine.load(path: url.path)
            scheduleControlsHide()
        }
    }
}
