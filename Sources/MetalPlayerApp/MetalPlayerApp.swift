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

                Button("Open URL…") {
                    appDelegate.promptOpenURL()
                }
                .keyboardShortcut("u", modifiers: .command)
            }

            PlayerCommands(appDelegate: appDelegate)
        }
    }
}
