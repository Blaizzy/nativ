import Foundation
import Testing

struct VoiceWakeWordPowerPolicyTests {
    private let battery = VoiceWakeWordPowerPolicy.PowerState(onBattery: true, lowPowerMode: false)
    private let lowPower = VoiceWakeWordPowerPolicy.PowerState(onBattery: true, lowPowerMode: true)

    @Test func testInactivityDeadlinesAndExternalPower() {
        let policy = VoiceWakeWordPowerPolicy()
        #expect(policy.remainingTime(at: 1_000, idleSeconds: 299, power: battery, mode: .automatic) == 1)
        #expect(policy.remainingTime(at: 1_000, idleSeconds: 300, power: battery, mode: .automatic) == 0)
        #expect(policy.remainingTime(at: 1_000, idleSeconds: 59, power: lowPower, mode: .automatic) == 1)
        #expect(policy.remainingTime(at: 1_000, idleSeconds: 60, power: lowPower, mode: .automatic) == 0)
        for lowPowerMode in [false, true] {
            let ac = VoiceWakeWordPowerPolicy.PowerState(onBattery: false, lowPowerMode: lowPowerMode)
            #expect(policy.remainingTime(at: 10_000, idleSeconds: 10_000, power: ac, mode: .automatic) == nil)
        }
        #expect(policy.remainingTime(at: 10_000, idleSeconds: 10_000, power: lowPower, mode: .alwaysListening) == nil)
    }

    @Test func testExplicitAndSystemInputActivityExtendTheDeadline() {
        var policy = VoiceWakeWordPowerPolicy()
        policy.recordActivity(at: 1_000)
        #expect(policy.remainingTime(at: 1_299, idleSeconds: 10_000, power: battery, mode: .automatic) == 1)
        // Input since the last deadline check is observed without a per-event callback.
        #expect(policy.remainingTime(at: 1_300, idleSeconds: 2, power: battery, mode: .automatic) == 298)
        policy.recordActivity(at: 1_300)
        #expect(policy.remainingTime(at: 1_300, idleSeconds: 10_000, power: battery, mode: .automatic) == 300)
    }

    @Test func testSuccessfulDictationGrantsTenMinutesIncludingLowPowerMode() {
        var policy = VoiceWakeWordPowerPolicy()
        policy.recordDictation(at: 1_000)
        for power in [battery, lowPower] {
            #expect(policy.remainingTime(at: 1_599, idleSeconds: 10_000, power: power, mode: .automatic) == 1)
            #expect(policy.remainingTime(at: 1_600, idleSeconds: 10_000, power: power, mode: .automatic) == 0)
        }
        policy.recordDictation(at: 1_590)
        #expect(policy.remainingTime(at: 1_600, idleSeconds: 10_000, power: lowPower, mode: .automatic) == 590)
        // Recent keyboard/mouse activity can also extend beyond the grace period.
        #expect(policy.remainingTime(at: 2_190, idleSeconds: 10, power: battery, mode: .automatic) == 290)
    }

    @Test func testInvalidIdleMeasurementsDoNotDisableVoiceAccess() {
        let policy = VoiceWakeWordPowerPolicy()
        for idle in [Double.nan, .infinity, -1] {
            #expect(policy.remainingTime(at: 1_000, idleSeconds: idle, power: battery, mode: .automatic) == nil)
        }
    }
}

@MainActor
struct VoiceWakeWordPowerMonitorTests {
    @Test func testPowerChangesPauseAndResumeWithoutResettingActivity() {
        var now = 0.0
        var idle = 10_000.0
        var power = VoiceWakeWordPowerPolicy.PowerState(onBattery: true, lowPowerMode: false)
        let monitor = VoiceWakeWordPowerMonitor(now: { now }, idleSeconds: { idle }, powerState: { power }, observesSystemEvents: false)
        var changes: [Bool] = []
        monitor.onChange = { changes.append(monitor.isPaused) }
        defer { monitor.configure(enabled: false, mode: .automatic); monitor.onChange = nil }
        monitor.configure(enabled: true, mode: .automatic)
        now = 200
        monitor.refresh()
        #expect(!monitor.isPaused)
        power.lowPowerMode = true
        monitor.refresh()
        #expect(monitor.isPaused)
        power.onBattery = false
        monitor.refresh()
        #expect(!monitor.isPaused)
        power.onBattery = true
        monitor.refresh()
        #expect(monitor.isPaused)
        // The first input event rearms even if the OS idle counter has not updated.
        monitor.recordActivity()
        #expect(!monitor.isPaused)
        now = 260
        idle = 0
        monitor.refresh()
        #expect(!monitor.isPaused)
        #expect(changes == [true, false, true, false])
    }

    @Test func testModeChangesDisableAndReenableInactivityPolicy() {
        var now = 0.0
        let monitor = VoiceWakeWordPowerMonitor(
            now: { now }, idleSeconds: { 10_000 },
            powerState: { .init(onBattery: true, lowPowerMode: false) }, observesSystemEvents: false
        )
        defer { monitor.configure(enabled: false, mode: .automatic) }
        monitor.configure(enabled: true, mode: .automatic)
        now = 300
        monitor.refresh()
        #expect(monitor.isPaused)
        monitor.configure(enabled: true, mode: .alwaysListening)
        #expect(!monitor.isPaused)
        now = 10_000
        monitor.refresh()
        #expect(!monitor.isPaused)
        monitor.configure(enabled: true, mode: .automatic)
        #expect(!monitor.isPaused)
        now += 300
        monitor.refresh()
        #expect(monitor.isPaused)
        monitor.configure(enabled: false, mode: .automatic)
        #expect(!monitor.isPaused)
        now += 1_000
        monitor.refresh()
        #expect(!monitor.isPaused)
        // Re-enabling after display/session wake gets a fresh activity window.
        monitor.configure(enabled: true, mode: .automatic)
        #expect(!monitor.isPaused)
    }

    @Test func testDictationGraceSurvivesPowerChangesAndExpires() {
        var now = 0.0
        var power = VoiceWakeWordPowerPolicy.PowerState(onBattery: true, lowPowerMode: false)
        let monitor = VoiceWakeWordPowerMonitor(now: { now }, idleSeconds: { 10_000 }, powerState: { power }, observesSystemEvents: false)
        defer { monitor.configure(enabled: false, mode: .automatic) }
        monitor.configure(enabled: true, mode: .automatic)
        now = 300
        monitor.refresh()
        #expect(monitor.isPaused)
        monitor.recordSuccessfulDictation()
        #expect(!monitor.isPaused)
        power.lowPowerMode = true
        now = 899
        monitor.refresh()
        #expect(!monitor.isPaused)
        now = 900
        monitor.refresh()
        #expect(monitor.isPaused)
    }

    @Test func testInactivityPauseCancelsPendingMicrophoneStartup() async throws {
        let listener = VoiceWakeWordMonitor()
        listener.configure(enabled: true, suspended: false, deviceID: nil)
        #expect(listener.state == .preparing)
        listener.configure(enabled: true, suspended: false, deviceID: nil, powerSavingPaused: true)
        #expect(listener.state == .pausedForInactivity)
        try await Task.sleep(for: .milliseconds(800))
        #expect(listener.state == .pausedForInactivity)
        listener.configure(enabled: true, suspended: false, deviceID: nil, powerSavingPaused: false)
        #expect(listener.state == .preparing)
        listener.configure(enabled: false, suspended: false, deviceID: nil)
        #expect(listener.state == .off)
    }

    @Test func testOtherAudioSuspensionTakesPriorityOverInactivity() {
        let listener = VoiceWakeWordMonitor()
        listener.configure(enabled: true, suspended: true, deviceID: nil, powerSavingPaused: true)
        #expect(listener.state == .paused)
        listener.configure(enabled: true, suspended: true, deviceID: nil, powerSavingPaused: false)
        #expect(listener.state == .paused)
        listener.configure(enabled: true, suspended: false, deviceID: nil, powerSavingPaused: true)
        #expect(listener.state == .pausedForInactivity)
        listener.configure(enabled: false, suspended: false, deviceID: nil, powerSavingPaused: true)
        #expect(listener.state == .off)
    }

    @Test func testListeningModePersistsAndMigratesWithoutEnablingWakeWords() throws {
        let suite = "VoiceWakeWordPowerMonitorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VoiceShortcutPreferences(defaults: defaults)
        #expect(preferences.wakeWordListeningMode == .automatic)
        #expect(!preferences.isWakeWordEnabled)
        preferences.wakeWordListeningMode = .alwaysListening
        preferences.isWakeWordEnabled = true
        let restored = VoiceShortcutPreferences(defaults: defaults)
        #expect(restored.wakeWordListeningMode == .alwaysListening)
        #expect(restored.isWakeWordEnabled)
        let data = try #require(defaults.data(forKey: "voiceShortcutPreferences.v1"))
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "wakeWordListeningMode")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "voiceShortcutPreferences.v1")
        let migrated = VoiceShortcutPreferences(defaults: defaults)
        #expect(migrated.wakeWordListeningMode == .automatic)
        #expect(migrated.isWakeWordEnabled)
        #expect(migrated.recordShortcut == preferences.recordShortcut)
    }
}
