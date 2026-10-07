import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindowController: WelcomeWindowController?
    private(set) var playerWindowController: PlayerWindowController?
    private var configuration = PlayerConfiguration()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupAppIcon()

        let baseConfig = PlayerConfiguration.loadFromUserDefaults()
        let parsed = PlayerConfiguration.parse(base: baseConfig)
        self.configuration = parsed.configuration

        if let mediaPath = parsed.mediaPath, FileManager.default.fileExists(atPath: mediaPath) {
            openMediaFile(at: URL(fileURLWithPath: mediaPath))
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        showWelcomeWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWelcomeWindow() {
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController(
                onOpenURL: { [weak self] url in
                    self?.openMediaFile(at: url)
                }
            )
        }
        welcomeWindowController?.showWindow(nil)
        welcomeWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func openMediaFile(at url: URL) {
        if playerWindowController == nil {
            let controller = PlayerWindowController(configuration: configuration)
            controller.onClose = { [weak self] in
                // When player window closes, return to welcome window if app is still running
                self?.showWelcomeWindow()
            }
            playerWindowController = controller
        }

        // Close/hide welcome window
        welcomeWindowController?.close()

        // Open file in main player window
        playerWindowController?.openFile(url: url)
    }

    func promptOpenFile() {
        if let playerWC = playerWindowController, playerWC.window?.isVisible == true {
            if let url = MediaOpenPanel.promptForMediaFile() {
                openMediaFile(at: url)
            }
        } else {
            welcomeWindowController?.promptOpenFile()
        }
    }

    func updateConfiguration(_ newConfig: PlayerConfiguration) {
        self.configuration.enableToneMapping = newConfig.enableToneMapping
        self.configuration.sharpness = newConfig.sharpness
        self.configuration.targetNits = newConfig.targetNits
        self.playerWindowController?.applyConfiguration(self.configuration)
    }

    private func setupAppIcon() {
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWelcomeWindow()
        }
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard let firstFile = filenames.first else { return }
        openMediaFile(at: URL(fileURLWithPath: firstFile))
    }
}
