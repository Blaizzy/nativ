import AVFoundation
import Foundation

@MainActor
protocol AudioInputEngineDriving: AnyObject {
    var isRunning: Bool { get }
    var failure: Error? { get }
    var onConfigurationChange: (() -> Void)? { get set }
    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async throws
    func stop() async
}

extension AudioInputEngineDriving {
    var failure: Error? { nil }
}

@MainActor
final class AudioInputEngineSession {
    private let makeEngine: () -> any AudioInputEngineDriving
    private let retryDelays: [Duration]
    private var engine: (any AudioInputEngineDriving)?
    private var recoveryTask: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var generation = UUID()
    private var remainingRecoveryAttempts = 0
    private var runningSince = ContinuousClock.now

    init(
        retryDelays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500)],
        makeEngine: @escaping () -> any AudioInputEngineDriving = { CoreAudioInputEngine() }
    ) {
        self.retryDelays = retryDelays
        self.makeEngine = makeEngine
    }

    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws {
        try Task.checkCancellation()
        let request = UUID()
        generation = request
        recoveryTask?.cancel()
        recoveryTask = nil
        await retireEngine().value
        guard generation == request else { throw CancellationError() }
        remainingRecoveryAttempts = retryDelays.count
        var failure: Error = VoiceAudioRecorderError.couldNotStart
        for delay in [.zero] + retryDelays {
            try Task.checkCancellation()
            guard generation == request else { throw CancellationError() }
            if delay != .zero { try await Task.sleep(for: delay) }
            do {
                try await startEngine(
                    request: request, deviceUniqueID: deviceUniqueID, tap: tap, onFailure: onFailure)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        throw failure
    }

    func stop() async {
        await cancel().value
    }

    @discardableResult
    func cancel() -> Task<Void, Never> {
        generation = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        return retireEngine()
    }

    private func retireEngine() -> Task<Void, Never> {
        let old = engine
        engine = nil
        old?.onConfigurationChange = nil
        let previous = retirementTask
        let retirement = Task {
            await previous?.value
            await old?.stop()
        }
        retirementTask = retirement
        return retirement
    }

    private func startEngine(
        request: UUID,
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard generation == request else { throw CancellationError() }
        let next = makeEngine()
        engine = next
        do {
            try await next.start(deviceUniqueID: deviceUniqueID, tap: tap)
            try Task.checkCancellation()
            guard generation == request, engine === next else { throw CancellationError() }
            guard next.isRunning else { throw next.failure ?? CoreAudioCaptureError.noAudio }
        } catch {
            if engine === next { await retireEngine().value } else { await retirementTask?.value }
            throw error
        }
        runningSince = .now
        next.onConfigurationChange = { [weak self, weak next] in
            guard let self, let next, self.generation == request,
                self.engine === next, !next.isRunning, self.recoveryTask == nil
            else { return }
            if self.runningSince.duration(to: .now) >= .seconds(5) {
                self.remainingRecoveryAttempts = self.retryDelays.count
            }
            self.recoveryTask = Task { [weak self] in
                await self?.recover(
                    request: request, deviceUniqueID: deviceUniqueID, tap: tap,
                    initialFailure: next.failure, onFailure: onFailure)
            }
        }
    }

    private func recover(
        request: UUID,
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        initialFailure: Error?,
        onFailure: @escaping (Error) -> Void
    ) async {
        guard generation == request, !Task.isCancelled else { return }
        await retireEngine().value
        var failure = initialFailure ?? VoiceAudioRecorderError.couldNotStart
        for delay in retryDelays {
            guard remainingRecoveryAttempts > 0 else { break }
            do { try await Task.sleep(for: delay) } catch { return }
            guard generation == request, !Task.isCancelled else { return }
            remainingRecoveryAttempts -= 1
            do {
                try await startEngine(
                    request: request, deviceUniqueID: deviceUniqueID, tap: tap, onFailure: onFailure)
                recoveryTask = nil
                return
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
        }
        guard generation == request, !Task.isCancelled else { return }
        recoveryTask = nil
        onFailure(failure)
    }

    isolated deinit {
        recoveryTask?.cancel()
        engine?.onConfigurationChange = nil
        let old = engine
        let previous = retirementTask
        Task {
            await previous?.value
            await old?.stop()
        }
    }
}

@MainActor
private final class CoreAudioInputEngine: AudioInputEngineDriving {
    var onConfigurationChange: (() -> Void)?
    private(set) var isRunning = false
    private(set) var failure: Error?
    private let capture = CoreAudioMicrophoneCapture()
    private var generation = UUID()

    func start(deviceUniqueID: String?, tap: @escaping CoreAudioMicrophoneCapture.Receiver) async throws {
        let request = UUID()
        generation = request
        failure = nil
        try await capture.start(deviceUniqueID: deviceUniqueID, receive: tap) { [weak self] error in
            await self?.interrupted(request: request, error: error)
        }
        guard generation == request else { throw CancellationError() }
        if let failure { throw failure }
        isRunning = true
    }

    private func interrupted(request: UUID, error: Error) {
        guard generation == request else { return }
        isRunning = false
        failure = error
        onConfigurationChange?()
    }

    func stop() async {
        generation = UUID()
        isRunning = false
        await capture.stop()
    }
}
