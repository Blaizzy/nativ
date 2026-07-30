import NativExtensionSDK
import XCTest

final class NativExtensionStateStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "NativExtensionStateStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testIncludedExtensionDefaultsToEnabled() {
        let store = NativExtensionStateStore(defaults: defaults)

        XCTAssertEqual(store.state(for: makeManifest(included: true)), .enabled)
    }

    func testExternalExtensionDefaultsToDisabled() {
        let store = NativExtensionStateStore(defaults: defaults)

        XCTAssertEqual(store.state(for: makeManifest(included: false)), .disabled)
    }

    func testRemovedTombstoneSurvivesStoreRecreation() {
        let key = "state.\(UUID().uuidString)"
        let manifest = makeManifest(included: true)
        let firstStore = NativExtensionStateStore(defaults: defaults, key: key)
        firstStore.set(.removed, for: manifest.id)

        let restoredStore = NativExtensionStateStore(defaults: defaults, key: key)

        XCTAssertEqual(restoredStore.state(for: manifest), .removed)
    }

    func testClearingStateRestoresDefault() {
        let manifest = makeManifest(included: true)
        let store = NativExtensionStateStore(defaults: defaults)
        store.set(.disabled, for: manifest.id)

        store.clear(extensionID: manifest.id)

        XCTAssertEqual(store.state(for: manifest), .enabled)
    }

    private func makeManifest(included: Bool) -> NativExtensionManifest {
        NativExtensionManifest(
            id: "com.example.extension",
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "Example",
            summary: "Example extension",
            developer: "Example",
            systemImage: "puzzlepiece.extension",
            included: included,
            runtime: .extensionFoundation,
            runtimeBundleIdentifier: "com.example.extension.runtime"
        )
    }
}
