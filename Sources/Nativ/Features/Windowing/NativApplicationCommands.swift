import SwiftUI

struct NativApplicationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.nativWindowState) private var focusedWindow

    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: appDelegate.softwareUpdater.updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                perform(.newChat)
            }
            .keyboardShortcut("n")

            Button("New Window", action: openNewWindow)
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                perform(.toggleSidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandGroup(after: .sidebar) {
            Button("Collapse All Sections") {
                perform(.collapseSidebarSections)
            }
            .keyboardShortcut(".", modifiers: [.command, .option])

            Button("Increase Chat Font Size") {
                appDelegate.increaseChatFontSize()
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Chat Font Size") {
                appDelegate.decreaseChatFontSize()
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Reset Chat Font Size") {
                appDelegate.resetChatFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                perform(.openTab(.settings))
            }
            .keyboardShortcut(",")
        }
    }

    private func openNewWindow() {
        openWindow(id: "main")
    }

    private func perform(_ intent: NativWindowIntent) {
        if let focusedWindow {
            focusedWindow.perform(intent)
        } else {
            appDelegate.performWindowIntent(intent)
        }
    }
}
