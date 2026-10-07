import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct WelcomeView: View {
    public var onOpenFile: () -> Void
    public var onFileDropped: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargetedForDrop: Bool = false

    public init(
        onOpenFile: @escaping () -> Void,
        onFileDropped: @escaping (String) -> Void
    ) {
        self.onOpenFile = onOpenFile
        self.onFileDropped = onFileDropped
    }

    public var body: some View {
        ZStack {
            // Adaptive gradient overlay for depth over vibrancy
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(0.15), Color.black.opacity(0.35)]
                    : [Color.white.opacity(0.20), Color.black.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .gesture(WindowDragGesture())

            VStack(spacing: 28) {
                // App Logo / Symbol (play button design)
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.9),
                                    Color.accentColor.opacity(0.6),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)
                        .shadow(
                            color: Color.accentColor.opacity(colorScheme == .dark ? 0.4 : 0.25), radius: 16, x: 0, y: 8)

                    Image(systemName: "play.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 3)
                }

                // Title & Subtitle
                VStack(spacing: 6) {
                    Text("MetalPlayer")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Drop video here or open a file to start watching")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                // Action buttons
                HStack(spacing: 14) {
                    Button(action: onOpenFile) {
                        Label("Open File…", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 120, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(action: {}) {
                        Label("Open URL…", systemImage: "link")
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 120, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(true)
                    .opacity(0.55)
                    .help("Open URL will be available in a future update")
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)

            // Drop highlight border
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .frame(width: 520, height: 350)
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    DispatchQueue.main.async {
                        onFileDropped(url.path)
                    }
                }
            }
            return true
        }
    }
}
