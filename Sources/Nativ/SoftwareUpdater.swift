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
final class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private let defaults: UserDefaults
    private let installedVersion: String
    private static let pendingBuildKey = "softwareUpdatePendingBuild"
    @Published private(set) var channel: SoftwareUpdateChannel
    @Published private(set) var sessionInProgress = false
    @Published private(set) var hasPendingUpdate: Bool

    var canChangeChannel: Bool { !sessionInProgress && !hasPendingUpdate }

    var channelDescription: String {
        if !canChangeChannel {
            return "Finish or skip the pending update in Check for Updates before changing channels."
        }
        if ReleaseVersion(installedVersion)?.candidate != nil && channel == .stable {
            return "You’ll stay on this release candidate until a newer stable release is available."
        }
        return channel == .stable
            ? "Receive stable releases only."
            : "Receive stable releases and early release candidates, which may contain bugs."
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    init(defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary) {
        self.defaults = defaults
        installedVersion = ReleaseVersion.displayString(in: info)
        channel = defaults.string(forKey: SoftwareUpdateChannel.storageKey)
            .flatMap(SoftwareUpdateChannel.init(rawValue:)) ?? .stable
        let pendingBuild = defaults.string(forKey: Self.pendingBuildKey)
        let installedBuild = info?["CFBundleVersion"] as? String ?? "0"
        hasPendingUpdate = pendingBuild.map {
            SUStandardVersionComparator.default.compareVersion(installedBuild, toVersion: $0) == .orderedAscending
        } ?? false
        super.init()
        if !hasPendingUpdate { defaults.removeObject(forKey: Self.pendingBuildKey) }
        NativApplicationIcon.registerForInAppUse()
        updater.publisher(for: \.sessionInProgress)
            .receive(on: RunLoop.main)
            .assign(to: &$sessionInProgress)
    }

    func start() {
        updaterController.startUpdater()
    }

    func setChannel(_ channel: SoftwareUpdateChannel) {
        guard !updater.sessionInProgress, !hasPendingUpdate, self.channel != channel else { return }
        self.channel = channel
        defaults.set(channel.rawValue, forKey: SoftwareUpdateChannel.storageKey)
        updater.resetUpdateCycleAfterShortDelay()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel.allowedChannels }

    func feedURLString(for updater: SPUUpdater) -> String? {
        channel == .releaseCandidates ? "https://github.com/Blaizzy/nativ/releases/download/preview/appcast.xml" : nil
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        bestUpdate(in: appcast.items) ?? SUAppcastItem.empty()
    }

    func bestUpdate(in items: [SUAppcastItem]) -> SUAppcastItem? {
        // Sparkle already filters OS requirements, skipped updates, and channels.
        // Compare public versions first: timestamps alone can rank a backport above an RC.
        items.filter {
            channel.permits(version: $0.displayVersionString, channel: $0.channel, installedVersion: installedVersion)
        }.max { left, right in
            let lhs = ReleaseVersion(left.displayVersionString)!
            let rhs = ReleaseVersion(right.displayVersionString)!
            if lhs != rhs { return lhs < rhs }
            return SUStandardVersionComparator.default.compareVersion(left.versionString, toVersion: right.versionString)
                == .orderedAscending
        }
    }

    // Sparkle can resume a downloaded update without re-running channel selection.
    // Keep channel changes locked until that update is installed, skipped, or aborted.
    private func setPendingBuild(_ build: String?) {
        defaults.set(build, forKey: Self.pendingBuildKey)
        hasPendingUpdate = build != nil
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        setPendingBuild(item.versionString)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            setPendingBuild(nil)
        } else if state.stage != .notDownloaded {
            setPendingBuild(item.versionString)
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        setPendingBuild(item.versionString)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        setPendingBuild(nil)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { setPendingBuild(nil) }
    func userDidCancelDownload(_ updater: SPUUpdater) { setPendingBuild(nil) }
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
