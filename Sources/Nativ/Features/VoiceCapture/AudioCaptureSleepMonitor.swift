import AppKit
import IOKit
import IOKit.pwr_mgt

/// Holds the system's sleep acknowledgment only while an active recording is saved.
@MainActor
final class AudioCaptureSleepMonitor {
    // IOMessage.h defines these using C macros that Swift cannot import.
    static let canSystemSleep: natural_t = 0xe0000270
    static let systemWillSleep: natural_t = 0xe0000280
    static let systemHasPoweredOn: natural_t = 0xe0000300

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pendingAcknowledgment: Int?
    private var deadlineTask: Task<Void, Never>?
    private let onSleep: @MainActor () async -> Void
    private let acknowledge: (io_connect_t, Int) -> Void
    private let deadline: Duration
    private let workspaceNotifications: NotificationCenter
    private var displayObservers: [NSObjectProtocol] = []
    private var systemIsSleeping = false
    private var displayIsSleeping = false
    var isSleeping: Bool { systemIsSleeping || displayIsSleeping }
    var onWake: (@MainActor () -> Void)?

    init(
        deadline: Duration = .seconds(30),
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        acknowledge: @escaping (io_connect_t, Int) -> Void = { port, token in
            IOAllowPowerChange(port, token)
        },
        onSleep: @escaping @MainActor () async -> Void
    ) {
        self.deadline = deadline
        self.workspaceNotifications = workspaceNotifications
        self.acknowledge = acknowledge
        self.onSleep = onSleep
    }

    func start() {
        guard rootPort == 0 else { return }
        if displayObservers.isEmpty {
            for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
                displayObservers.append(workspaceNotifications.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    let isAsleep = notification.name == NSWorkspace.screensDidSleepNotification
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.displayIsSleeping = isAsleep
                        if self.displayIsSleeping {
                            // ScreenCaptureKit can stop on display sleep without any
                            // system-sleep notification or error delegate callback.
                            Task { await self.onSleep() }
                        } else {
                            self.onWake?()
                        }
                    }
                })
            }
        }
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort,
            { context, _, message, argument in
                guard let context else { return }
                // This notification source is installed exclusively on the main run loop.
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<AudioCaptureSleepMonitor>
                        .fromOpaque(context).takeUnretainedValue()
                    monitor.handle(message, token: Int(bitPattern: argument))
                }
            },
            &notifier
        )
        guard rootPort != 0, let notificationPort else {
            NSLog("Nativ could not register for audio capture sleep notifications.")
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
            .commonModes
        )
    }

    func stop() {
        displayObservers.forEach { workspaceNotifications.removeObserver($0) }
        displayObservers.removeAll()
        systemIsSleeping = false
        displayIsSleeping = false
        if let token = pendingAcknowledgment {
            allowSleep(token)
        }
        guard rootPort != 0 else { return }
        if let notificationPort {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
                .commonModes
            )
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        rootPort = 0
        notificationPort = nil
    }

    func handle(_ message: natural_t, token: Int) {
        switch message {
        case Self.canSystemSleep:
            acknowledge(rootPort, token)
        case Self.systemWillSleep:
            systemIsSleeping = true
            pendingAcknowledgment = token
            // Use macOS's full 30-second allowance, releasing sooner if saving finishes.
            deadlineTask = Task { [weak self, deadline] in
                do { try await Task.sleep(for: deadline) } catch { return }
                self?.allowSleep(token)
            }
            Task { [weak self] in
                guard let self else { return }
                await onSleep()
                allowSleep(token)
            }
        case Self.systemHasPoweredOn:
            systemIsSleeping = false
            pendingAcknowledgment = nil
            deadlineTask?.cancel()
            deadlineTask = nil
            onWake?()
        default:
            break
        }
    }

    private func allowSleep(_ token: Int) {
        guard pendingAcknowledgment == token else { return }
        pendingAcknowledgment = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        acknowledge(rootPort, token)
    }
}
