import SwiftUI

struct NativApplicationCommands: Commands {
    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: appDelegate.softwareUpdater.updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                appDelegate.performWindowIntent(.newChat)
            }
            .keyboardShortcut("n")
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                appDelegate.performWindowIntent(.toggleSidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandGroup(after: .sidebar) {
            Button("Collapse All Sections") {
                appDelegate.performWindowIntent(.collapseSidebarSections)
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
                appDelegate.performWindowIntent(.openTab(.settings))
            }
            .keyboardShortcut(",")
        }
    }
}
