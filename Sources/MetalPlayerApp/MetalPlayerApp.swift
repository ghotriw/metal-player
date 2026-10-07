import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@main
struct MetalPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(onConfigurationChanged: { newConfig in
                appDelegate.updateConfiguration(newConfig)
            })
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File…") {
                    appDelegate.promptOpenFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Playback") {
                Button("Play / Pause") {
                    appDelegate.playerWindowController?.engine.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Divider()

                Button("Step Forward (1 Frame)") {
                    appDelegate.playerWindowController?.engine.stepFrameForward()
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)

                Button("Step Backward (1 Frame)") {
                    appDelegate.playerWindowController?.engine.stepFrameBackward()
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)

                Divider()

                Button("Jump Forward (5s)") {
                    appDelegate.playerWindowController?.engine.seekRelative(by: 5.0)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Jump Backward (5s)") {
                    appDelegate.playerWindowController?.engine.seekRelative(by: -5.0)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            CommandMenu("Audio") {
                Button("Increase Volume") {
                    if let engine = appDelegate.playerWindowController?.engine {
                        engine.volume = min(engine.volume + 0.05, 1.0)
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [])

                Button("Decrease Volume") {
                    if let engine = appDelegate.playerWindowController?.engine {
                        engine.volume = max(engine.volume - 0.05, 0.0)
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [])

                Button("Mute / Unmute") {
                    if let engine = appDelegate.playerWindowController?.engine {
                        engine.isMuted.toggle()
                    }
                }
                .keyboardShortcut("m", modifiers: .command)
            }

            CommandMenu("Video") {
                Menu("Render Mode") {
                    Button("Auto (Display Adaptive)") {
                        appDelegate.playerWindowController?.engine.renderMode = .auto
                    }
                    Button("System (Apple DisplayLayer)") {
                        appDelegate.playerWindowController?.engine.renderMode = .system
                    }
                    Button("Custom Metal Tone-Mapping") {
                        appDelegate.playerWindowController?.engine.renderMode = .metalToneMap
                    }
                }
            }

            CommandMenu("View") {
                Button("Toggle Performance HUD") {
                    if let engine = appDelegate.playerWindowController?.engine {
                        engine.showDebugHUD.toggle()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command])
            }
        }
    }
}
