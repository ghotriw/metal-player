import AppKit
import MetalPlayerCore
import MetalPlayerUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindowController: WelcomeWindowController?
    private var playerWindowController: PlayerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupAppIcon()
        setupMainMenu()

        // Check if file passed via command line argument
        if CommandLine.arguments.count > 1 {
            let filePath = CommandLine.arguments[1]
            if FileManager.default.fileExists(atPath: filePath) {
                openMediaFile(at: URL(fileURLWithPath: filePath))
                NSApp.activate(ignoringOtherApps: true)
                return
            }
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
            let controller = PlayerWindowController()
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
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
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
