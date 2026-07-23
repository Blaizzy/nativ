import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
enum NativApplicationIcon {
    static let image: NSImage = {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        icon.isTemplate = false
        return icon
    }()

    static func registerForInAppUse() {
        let applicationIconName = NSImage.applicationIconName
        if let existingImage = NSImage(named: applicationIconName), existingImage !== image {
            existingImage.setName(nil)
        }
        image.setName(applicationIconName)
    }
}

@MainActor
final class SoftwareUpdater {
    private let updaterController: SPUStandardUpdaterController

    var updater: SPUUpdater {
        updaterController.updater
    }

    init() {
        NativApplicationIcon.registerForInAppUse()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    @MainActor
    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
