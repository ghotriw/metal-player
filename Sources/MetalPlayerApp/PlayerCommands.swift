import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

struct PlayerCommands: Commands {
    @FocusedValue(\.playerActions) private var focusedPlayer: (any PlayerActions)?
    let appDelegate: AppDelegate

    private var playerActions: (any PlayerActions)? {
        focusedPlayer ?? appDelegate.activePlayer
    }

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") {
                playerActions?.togglePlayPause()
            }
            .disabled(playerActions == nil)

            Divider()

            Button("Step Forward (1 Frame)") {
                playerActions?.stepFrameForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(playerActions == nil)

            Button("Step Backward (1 Frame)") {
                playerActions?.stepFrameBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(playerActions == nil)

            Divider()

            Button("Jump Forward (5s)") {
                playerActions?.seekRelative(by: 5.0)
            }
            .disabled(playerActions == nil)

            Button("Jump Backward (5s)") {
                playerActions?.seekRelative(by: -5.0)
            }
            .disabled(playerActions == nil)
        }

        CommandMenu("Audio") {
            Button("Increase Volume") {
                playerActions?.stepVolume(by: 0.05)
            }
            .disabled(playerActions == nil)

            Button("Decrease Volume") {
                playerActions?.stepVolume(by: -0.05)
            }
            .disabled(playerActions == nil)

            Divider()

            Toggle(
                "Mute",
                isOn: Binding(
                    get: { playerActions?.isMuted ?? false },
                    set: { _ in playerActions?.toggleMute() }
                )
            )
            .disabled(playerActions == nil)
        }

        CommandMenu("Video") {
            Picker(
                "Render Mode",
                selection: Binding(
                    get: { playerActions?.renderMode ?? .auto },
                    set: { mode in
                        if let playerActions {
                            playerActions.renderMode = mode
                        }
                    }
                )
            ) {
                ForEach(RenderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(playerActions == nil)
        }

        CommandMenu("View") {
            Toggle(
                "Performance HUD",
                isOn: Binding(
                    get: { playerActions?.showDebugHUD ?? false },
                    set: { _ in playerActions?.toggleDebugHUD() }
                )
            )
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(playerActions == nil)

            Divider()

            Button("Toggle Full Screen") {
                playerActions?.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
            .disabled(playerActions == nil)
        }
    }
}
