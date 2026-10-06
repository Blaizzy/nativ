import AppKit
import IOKit.ps

enum VoiceWakeWordListeningMode: String, CaseIterable, Sendable {
    case automatic
    case alwaysListening

    var title: String {
        switch self {
        case .automatic: "Automatic power saving"
        case .alwaysListening: "Always listening"
        }
    }
}

/// All times use system uptime, so wall-clock adjustments cannot change deadlines.
struct VoiceWakeWordPowerPolicy {
    struct PowerState {
        var onBattery: Bool
        var lowPowerMode: Bool
    }

    private var lastActivity: TimeInterval?
    private var lastDictation: TimeInterval?

    mutating func recordActivity(at now: TimeInterval) { lastActivity = now }

    mutating func recordDictation(at now: TimeInterval) {
        lastActivity = now
        lastDictation = now
    }

    /// Nil means keep listening without an inactivity deadline; zero means pause.
    func remainingTime(
        at now: TimeInterval, idleSeconds: TimeInterval,
        power: PowerState, mode: VoiceWakeWordListeningMode
    ) -> TimeInterval? {
        guard mode == .automatic, power.onBattery else { return nil }
        // If the system cannot report input activity, keep listening rather than
        // silently disabling voice access based on an invalid measurement.
        guard idleSeconds.isFinite, idleSeconds >= 0 else { return nil }
        let activity = max(now - idleSeconds, lastActivity ?? -.infinity)
        let deadline = max(activity + (power.lowPowerMode ? 60 : 300),
                           lastDictation.map { $0 + 600 } ?? -.infinity)
        return max(0, deadline - now)
    }
}

/// Checks global idle time only at the next deadline. Input event observers exist
/// only while paused, to rearm on the first keyboard or mouse event without polling.
@MainActor
final class VoiceWakeWordPowerMonitor {
    var onChange: (() -> Void)?
    private(set) var isPaused = false
    private var enabled = false
    private var mode = VoiceWakeWordListeningMode.automatic
    private var policy = VoiceWakeWordPowerPolicy()
    private let now: () -> TimeInterval
    private let idleSeconds: () -> TimeInterval
    private let powerState: () -> VoiceWakeWordPowerPolicy.PowerState
    private let observesSystemEvents: Bool
    private var deadlineTask: Task<Void, Never>?
    private var powerSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    private var globalInputMonitor: Any?
    private var localInputMonitor: Any?

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        idleSeconds: @escaping () -> TimeInterval = { VoiceWakeWordPowerMonitor.systemIdleSeconds() },
        powerState: @escaping () -> VoiceWakeWordPowerPolicy.PowerState = { VoiceWakeWordPowerMonitor.systemPowerState() },
        observesSystemEvents: Bool = true
    ) {
        self.now = now
        self.idleSeconds = idleSeconds
        self.powerState = powerState
        self.observesSystemEvents = observesSystemEvents
    }

    func configure(enabled: Bool, mode: VoiceWakeWordListeningMode) {
        guard self.enabled != enabled || self.mode != mode else { return }
        self.enabled = enabled
        self.mode = mode
        if enabled, mode == .automatic {
            policy.recordActivity(at: now())
            startPowerObservations()
        } else {
            stopPowerObservations()
        }
        refresh()
    }

    func recordActivity() {
        policy.recordActivity(at: now())
        refresh()
    }

    func recordSuccessfulDictation() {
        policy.recordDictation(at: now())
        refresh()
    }

    func refresh() {
        deadlineTask?.cancel()
        deadlineTask = nil
        let remaining = enabled
            ? policy.remainingTime(at: now(), idleSeconds: idleSeconds(), power: powerState(), mode: mode)
            : nil
        let paused = remaining == 0
        if paused { startInputObservations() } else { stopInputObservations() }
        if let remaining, remaining > 0 {
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.refresh()
            }
        }
        guard isPaused != paused else { return }
        isPaused = paused
        onChange?()
    }

    private func startPowerObservations() {
        guard observesSystemEvents, lowPowerObserver == nil else { return }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        powerSource = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<VoiceWakeWordPowerMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }

    private func stopPowerObservations() {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
    }

    private func startInputObservations() {
        guard observesSystemEvents, localInputMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordActivity() }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.recordActivity() }
            return event
        }
    }

    private func stopInputObservations() {
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        globalInputMonitor = nil
        localInputMonitor = nil
    }

    private static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private static func systemPowerState() -> VoiceWakeWordPowerPolicy.PowerState {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = snapshot.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() } as String?
        return .init(onBattery: source == kIOPSBatteryPowerValue,
                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    isolated deinit {
        deadlineTask?.cancel()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
    }
}
