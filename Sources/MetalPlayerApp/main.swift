import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindowController: WelcomeWindowController?
    private var playerWindowController: PlayerWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var configuration = PlayerConfiguration()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupAppIcon()
        setupMainMenu()

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

    func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                onConfigurationChanged: { [weak self] newConfig in
                    guard let self else { return }
                    self.configuration.enableToneMapping = newConfig.enableToneMapping
                    self.configuration.sharpness = newConfig.sharpness
                    self.configuration.targetNits = newConfig.targetNits
                    self.playerWindowController?.applyConfiguration(self.configuration)
                }
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
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

    private func setupAppIcon() {
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = icon
        }
    }

    @objc func settingsMenuItemClicked(_ sender: Any?) {
        showSettingsWindow()
    }

    @objc func openFileMenuItemClicked(_ sender: Any?) {
        if let playerWC = playerWindowController, playerWC.window?.isVisible == true {
            if let url = MediaOpenPanel.promptForMediaFile() {
                openMediaFile(at: url)
            }
        } else {
            welcomeWindowController?.promptOpenFile()
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

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu (MetalPlayer)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsMenuItem = NSMenuItem(
            title: "Settings…",
            action: #selector(settingsMenuItemClicked(_:)),
            keyEquivalent: ","
        )
        settingsMenuItem.target = self
        appMenu.addItem(settingsMenuItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit MetalPlayer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let openMenuItem = NSMenuItem(
            title: "Open File…",
            action: #selector(openFileMenuItemClicked(_:)),
            keyEquivalent: "o"
        )
        openMenuItem.target = self
        fileMenu.addItem(openMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        let closeMenuItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(closeMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
