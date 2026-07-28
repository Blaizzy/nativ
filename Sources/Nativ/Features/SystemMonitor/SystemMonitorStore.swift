import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import IOKit
import Metal
import QuartzCore

struct SystemHistorySample: Identifiable, Equatable, Sendable {
    let recordedAt: Date
    let value: Double

    var id: Date { recordedAt }
}

struct SystemCPUMetrics: Equatable, Sendable {
    var totalUsage: Double = 0
    var userUsage: Double = 0
    var systemUsage: Double = 0
    var idleUsage: Double = 1
    var coreUsage: [Double] = []
    var loadAverages: [Double] = [0, 0, 0]
}

struct SystemGPUMetrics: Equatable, Sendable {
    var deviceUsage: Double?
    var aneUsage: Double?
    var framesPerSecond: Double?
    var allocatedMemoryBytes: UInt64?
}

struct SystemMemoryMetrics: Equatable, Sendable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var activeBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0

    var usage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    var pressureLabel: String {
        switch usage {
        case ..<0.70:
            "Normal"
        case ..<0.90:
            "Elevated"
        default:
            "Critical"
        }
    }
}

struct SystemDiskMetrics: Equatable, Sendable {
    var totalBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var cumulativeReadBytes: UInt64 = 0
    var cumulativeWriteBytes: UInt64 = 0

    var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    var usage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

struct SystemDiskIdentity: Equatable, Sendable {
    var volumeName = "Macintosh HD"
    var fileSystem = "APFS"
    var mountPoint = "/"
    var deviceIdentifier = "--"
    var model = "Internal storage"
    var connection = "Internal"
    var isEncrypted: Bool?
    var isWritable: Bool?
    var smartStatus: String?
    var healthPercent: Int?
    var temperatureCelsius: Int?
    var powerCycles: UInt64?
    var powerOnHours: UInt64?
    var unsafeShutdowns: UInt64?
    var mediaErrors: UInt64?
    var availableSparePercent: Int?
    var lifetimeReadBytes: UInt64?
    var lifetimeWrittenBytes: UInt64?
}

struct SystemMonitorIdentity: Equatable, Sendable {
    var computerName = Host.current().localizedName ?? "This Mac"
    var modelIdentifier = "--"
    var modelNumber: String?
    var productionYear: Int?
    var serialNumber = "--"
    var chipName = "Apple silicon"
    var physicalCoreCount = ProcessInfo.processInfo.processorCount
    var logicalCoreCount = ProcessInfo.processInfo.activeProcessorCount
    var efficiencyCoreCount = 0
    var performanceCoreCount = 0
    var gpuName = "Apple GPU"
    var gpuCoreCount: Int?
    var aneCoreCount: Int?
    var nominalCPUFrequencyHz: UInt64?
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var displayName = "Built-in display"
    var displayResolution = "--"
    var displayRefreshRate: Double?
    var disk = SystemDiskIdentity()
}

struct SystemMonitorSnapshot: Equatable, Sendable {
    var recordedAt = Date()
    var identity = SystemMonitorIdentity()
    var cpu = SystemCPUMetrics()
    var gpu = SystemGPUMetrics()
    var memory = SystemMemoryMetrics()
    var disk = SystemDiskMetrics()
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
}

@MainActor
final class SystemMonitorStore: ObservableObject {
    @Published private(set) var snapshot = SystemMonitorSnapshot()
    @Published private(set) var cpuHistory: [SystemHistorySample] = []
    @Published private(set) var gpuHistory: [SystemHistorySample] = []
    @Published private(set) var aneHistory: [SystemHistorySample] = []
    @Published private(set) var fpsHistory: [SystemHistorySample] = []
    @Published private(set) var memoryHistory: [SystemHistorySample] = []
    @Published private(set) var swapHistory: [SystemHistorySample] = []
    @Published private(set) var diskReadHistory: [SystemHistorySample] = []
    @Published private(set) var diskWriteHistory: [SystemHistorySample] = []
    @Published private(set) var isSampling = false

    private let collector = SystemMetricsCollector()
    private let displayFPSSampler = SystemDisplayFPSSampler()
    private let aneSampler = SystemANEUtilizationSampler()
    private var samplingTask: Task<Void, Never>?
    private let historyLimit = 300

    deinit {
        samplingTask?.cancel()
    }

    func start() {
        guard samplingTask == nil else { return }
        isSampling = true
        displayFPSSampler.start()
        aneSampler.start()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var nextSnapshot = await collector.collect()
                nextSnapshot.gpu.framesPerSecond = displayFPSSampler.takeFramesPerSecond()
                nextSnapshot.gpu.aneUsage = aneSampler.takeUtilization()
                apply(nextSnapshot)

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        displayFPSSampler.stop()
        aneSampler.stop()
        isSampling = false
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            apply(await collector.collect())
        }
    }

    func collectSnapshot() async -> SystemMonitorSnapshot {
        await collector.collect()
    }

    private func apply(_ nextSnapshot: SystemMonitorSnapshot) {
        snapshot = nextSnapshot
        append(nextSnapshot.cpu.totalUsage, at: nextSnapshot.recordedAt, to: &cpuHistory)
        append(nextSnapshot.memory.usage, at: nextSnapshot.recordedAt, to: &memoryHistory)

        if let value = nextSnapshot.gpu.deviceUsage {
            append(value, at: nextSnapshot.recordedAt, to: &gpuHistory)
        }
        if let value = nextSnapshot.gpu.aneUsage {
            append(value, at: nextSnapshot.recordedAt, to: &aneHistory)
        }
        if let value = nextSnapshot.gpu.framesPerSecond {
            append(value, at: nextSnapshot.recordedAt, to: &fpsHistory)
        }

        let swapUsage: Double
        if nextSnapshot.memory.swapTotalBytes > 0 {
            swapUsage = Double(nextSnapshot.memory.swapUsedBytes)
                / Double(nextSnapshot.memory.swapTotalBytes)
        } else {
            swapUsage = 0
        }
        append(swapUsage, at: nextSnapshot.recordedAt, to: &swapHistory)
        append(
            nextSnapshot.disk.readBytesPerSecond,
            at: nextSnapshot.recordedAt,
            to: &diskReadHistory
        )
        append(
            nextSnapshot.disk.writeBytesPerSecond,
            at: nextSnapshot.recordedAt,
            to: &diskWriteHistory
        )
    }

    private func append(
        _ value: Double,
        at date: Date,
        to samples: inout [SystemHistorySample]
    ) {
        samples.append(SystemHistorySample(recordedAt: date, value: value))
        if samples.count > historyLimit {
            samples.removeFirst(samples.count - historyLimit)
        }
    }
}

private struct SystemCPUTicks: Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64

    var total: UInt64 { user + system + idle }
}

private struct SystemDiskCounters: Sendable {
    let readBytes: UInt64
    let writeBytes: UInt64
}

@MainActor
private final class SystemDisplayFPSSampler: NSObject {
    private var displayLink: CADisplayLink?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var frameCount = 0

    func start() {
        guard displayLink == nil, let screen = NSScreen.main else { return }
        let createdDisplayLink = screen.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        firstTimestamp = nil
        lastTimestamp = nil
        frameCount = 0
        displayLink = createdDisplayLink
        createdDisplayLink.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        firstTimestamp = nil
        lastTimestamp = nil
        frameCount = 0
    }

    @objc private func displayLinkDidFire(_ sender: CADisplayLink) {
        if firstTimestamp == nil {
            firstTimestamp = sender.timestamp
        }
        lastTimestamp = sender.timestamp
        frameCount += 1
    }

    func takeFramesPerSecond() -> Double? {
        guard let firstTimestamp,
              let lastTimestamp,
              lastTimestamp > firstTimestamp,
              frameCount > 1
        else {
            return nil
        }

        let elapsed = lastTimestamp - firstTimestamp
        guard elapsed > 0 else { return nil }
        let fps = Double(frameCount - 1) / elapsed

        self.firstTimestamp = lastTimestamp
        self.lastTimestamp = lastTimestamp
        frameCount = 1
        return fps
    }
}

private final class SystemANEUtilizationSampler: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.local.Nativ.system-monitor.ane",
        qos: .utility
    )
    private var services: [io_service_t] = []
    private var timer: DispatchSourceTimer?
    private var sampleCount = 0
    private var busySampleCount = 0

    func start() {
        queue.sync {
            guard timer == nil else { return }

            let serviceClasses = [
                "H1xANELoadBalancer",
                "H11ANEIn",
                "AppleT6031ANEHAL",
            ]
            services = serviceClasses.compactMap { className in
                guard let matching = IOServiceMatching(className) else { return nil }
                let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                return service == IO_OBJECT_NULL ? nil : service
            }
            guard !services.isEmpty else { return }

            sampleCount = 0
            busySampleCount = 0
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now(),
                repeating: .milliseconds(10),
                leeway: .milliseconds(2)
            )
            source.setEventHandler { [weak self] in
                self?.sampleBusyState()
            }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            services.forEach { IOObjectRelease($0) }
            services = []
            sampleCount = 0
            busySampleCount = 0
        }
    }

    func takeUtilization() -> Double? {
        queue.sync {
            guard !services.isEmpty, sampleCount > 0 else { return nil }
            let utilization = Double(busySampleCount) / Double(sampleCount)
            sampleCount = 0
            busySampleCount = 0
            return min(max(utilization, 0), 1)
        }
    }

    private func sampleBusyState() {
        sampleCount += 1
        for service in services {
            var busyState: UInt32 = 0
            if IOServiceGetBusyState(service, &busyState) == KERN_SUCCESS,
               busyState > 0 {
                busySampleCount += 1
                return
            }
        }
    }
}

private actor SystemMetricsCollector {
    private var identity: SystemMonitorIdentity?
    private var previousCPUTicks: [SystemCPUTicks] = []
    private var previousDiskCounters: SystemDiskCounters?
    private var previousDiskSampleDate: Date?

    func collect() -> SystemMonitorSnapshot {
        let now = Date()
        let resolvedIdentity: SystemMonitorIdentity
        if let identity {
            resolvedIdentity = identity
        } else {
            let capturedIdentity = Self.captureIdentity()
            identity = capturedIdentity
            resolvedIdentity = capturedIdentity
        }

        let ticks = Self.cpuTicks()
        let cpu = Self.cpuMetrics(current: ticks, previous: previousCPUTicks)
        previousCPUTicks = ticks

        let counters = Self.diskCounters()
        let disk = Self.diskMetrics(
            current: counters,
            previous: previousDiskCounters,
            elapsed: previousDiskSampleDate.map { now.timeIntervalSince($0) }
        )
        previousDiskCounters = counters
        previousDiskSampleDate = now

        return SystemMonitorSnapshot(
            recordedAt: now,
            identity: resolvedIdentity,
            cpu: cpu,
            gpu: Self.gpuMetrics(),
            memory: Self.memoryMetrics(),
            disk: disk,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func captureIdentity() -> SystemMonitorIdentity {
        var identity = SystemMonitorIdentity()
        identity.modelIdentifier = sysctlString("hw.model") ?? identity.modelIdentifier
        identity.chipName = sysctlString("machdep.cpu.brand_string") ?? identity.chipName
        identity.physicalCoreCount = sysctlInteger("hw.physicalcpu")
            ?? identity.physicalCoreCount
        identity.logicalCoreCount = sysctlInteger("hw.logicalcpu")
            ?? identity.logicalCoreCount
        identity.performanceCoreCount = sysctlInteger("hw.perflevel0.physicalcpu") ?? 0
        identity.efficiencyCoreCount = sysctlInteger("hw.perflevel1.physicalcpu") ?? 0
        identity.nominalCPUFrequencyHz = sysctlInteger("hw.cpufrequency_max").map(UInt64.init)
        identity.serialNumber = platformSerialNumber() ?? identity.serialNumber

        if let profile = hardwareProfile() {
            identity.computerName = profile["machine_name"] as? String
                ?? identity.computerName
            identity.modelNumber = profile["model_number"] as? String
            identity.serialNumber = profile["serial_number"] as? String
                ?? identity.serialNumber
        }
        identity.productionYear = productionYear(modelIdentifier: identity.modelIdentifier)

        if let device = MTLCreateSystemDefaultDevice() {
            identity.gpuName = device.name
        }

        if let gpuConfiguration = gpuProperty("GPUConfigurationVariable") as? NSDictionary {
            identity.gpuCoreCount = number(gpuConfiguration["num_cores"]).map(Int.init)
        }
        if let aneProperties = registryProperty(
            serviceClass: "H11ANEIn",
            key: "DeviceProperties"
        ) as? NSDictionary {
            identity.aneCoreCount = number(
                aneProperties["ANEDevicePropertyNumANECores"]
            ).map(Int.init)
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        identity.operatingSystem = [
            "\(version.majorVersion)",
            "\(version.minorVersion)",
            version.patchVersion > 0 ? "\(version.patchVersion)" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ".")
        .withPrefix("macOS ")

        if let screen = NSScreen.main {
            identity.displayName = screen.localizedName
            if let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
               let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(screenNumber.uint32Value)) {
                identity.displayResolution = "\(mode.pixelWidth) × \(mode.pixelHeight)"
                if mode.refreshRate > 0 {
                    identity.displayRefreshRate = mode.refreshRate
                }
            }
        }

        identity.disk = diskIdentity()
        return identity
    }

    private static func cpuTicks() -> [SystemCPUTicks] {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return [] }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        return (0..<Int(processorCount)).map { index in
            let offset = index * Int(CPU_STATE_MAX)
            return SystemCPUTicks(
                user: UInt64(
                    processorInfo[offset + Int(CPU_STATE_USER)]
                        + processorInfo[offset + Int(CPU_STATE_NICE)]
                ),
                system: UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)])
            )
        }
    }

    private static func cpuMetrics(
        current: [SystemCPUTicks],
        previous: [SystemCPUTicks]
    ) -> SystemCPUMetrics {
        let deltas = current.enumerated().map { index, value in
            guard previous.indices.contains(index) else { return value }
            let prior = previous[index]
            return SystemCPUTicks(
                user: value.user >= prior.user ? value.user - prior.user : 0,
                system: value.system >= prior.system ? value.system - prior.system : 0,
                idle: value.idle >= prior.idle ? value.idle - prior.idle : 0
            )
        }

        let aggregate = deltas.reduce(SystemCPUTicks(user: 0, system: 0, idle: 0)) {
            SystemCPUTicks(
                user: $0.user + $1.user,
                system: $0.system + $1.system,
                idle: $0.idle + $1.idle
            )
        }
        let total = max(Double(aggregate.total), 1)
        let loads = loadAverages()

        return SystemCPUMetrics(
            totalUsage: min(max(1 - (Double(aggregate.idle) / total), 0), 1),
            userUsage: min(max(Double(aggregate.user) / total, 0), 1),
            systemUsage: min(max(Double(aggregate.system) / total, 0), 1),
            idleUsage: min(max(Double(aggregate.idle) / total, 0), 1),
            coreUsage: deltas.map {
                guard $0.total > 0 else { return 0 }
                return min(max(1 - (Double($0.idle) / Double($0.total)), 0), 1)
            },
            loadAverages: loads
        )
    }

    private static func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, Int32(values.count))
        guard count > 0 else { return [0, 0, 0] }
        return values
    }

    private static func memoryMetrics() -> SystemMemoryMetrics {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return SystemMemoryMetrics(totalBytes: ProcessInfo.processInfo.physicalMemory)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let active = UInt64(statistics.active_count) * pageSize
        let wired = UInt64(statistics.wire_count) * pageSize
        let compressed = UInt64(statistics.compressor_page_count) * pageSize
        let cached = UInt64(statistics.inactive_count) * pageSize
        let used = min(active + wired + compressed, total)
        let swap = swapUsage()

        return SystemMemoryMetrics(
            totalBytes: total,
            usedBytes: used,
            activeBytes: active,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            freeBytes: total > used ? total - used : 0,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total
        )
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static func gpuMetrics() -> SystemGPUMetrics {
        guard let statistics = gpuProperty("PerformanceStatistics") as? NSDictionary else {
            return SystemGPUMetrics()
        }
        return SystemGPUMetrics(
            deviceUsage: percentage(statistics["Device Utilization %"]),
            allocatedMemoryBytes: number(statistics["Alloc system memory"])
        )
    }

    private static func gpuProperty(_ key: String) -> Any? {
        registryProperty(serviceClass: "AGXAccelerator", key: key)
    }

    private static func registryProperty(
        serviceClass: String,
        key: String
    ) -> Any? {
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func diskMetrics(
        current: SystemDiskCounters,
        previous: SystemDiskCounters?,
        elapsed: TimeInterval?
    ) -> SystemDiskMetrics {
        let rootURL = URL(fileURLWithPath: "/")
        let values = try? rootURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
        ])
        let total = UInt64(max(values?.volumeTotalCapacity ?? 0, 0))
        let available = UInt64(max(values?.volumeAvailableCapacity ?? 0, 0))

        let interval = max(elapsed ?? 0, 0)
        let readRate: Double
        let writeRate: Double
        if let previous, interval > 0 {
            readRate = Double(
                current.readBytes >= previous.readBytes
                    ? current.readBytes - previous.readBytes
                    : 0
            ) / interval
            writeRate = Double(
                current.writeBytes >= previous.writeBytes
                    ? current.writeBytes - previous.writeBytes
                    : 0
            ) / interval
        } else {
            readRate = 0
            writeRate = 0
        }

        return SystemDiskMetrics(
            totalBytes: total,
            availableBytes: available,
            readBytesPerSecond: readRate,
            writeBytesPerSecond: writeRate,
            cumulativeReadBytes: current.readBytes,
            cumulativeWriteBytes: current.writeBytes
        )
    }

    private static func diskCounters() -> SystemDiskCounters {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            return SystemDiskCounters(readBytes: 0, writeBytes: 0)
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return SystemDiskCounters(readBytes: 0, writeBytes: 0)
        }
        defer { IOObjectRelease(iterator) }

        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as NSDictionary?,
                  let statistics = dictionary["Statistics"] as? NSDictionary
            else {
                continue
            }
            readBytes += number(statistics["Bytes (Read)"]) ?? 0
            writeBytes += number(statistics["Bytes (Write)"]) ?? 0
        }
        return SystemDiskCounters(readBytes: readBytes, writeBytes: writeBytes)
    }

    private static func diskIdentity() -> SystemDiskIdentity {
        guard let volume = diskutilInfo("/") else {
            return SystemDiskIdentity()
        }

        let physicalStore = (volume["APFSPhysicalStores"] as? [[String: Any]])?
            .first?["APFSPhysicalStore"] as? String
        let physicalDisk = physicalStore.map(wholeDiskIdentifier)
        let device = physicalDisk.flatMap(diskutilInfo)
        let smart = (device?["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"]
            ?? volume["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"]) as? [String: Any]
        let usedPercent = intValue(smart?["PERCENTAGE_USED"])
        let temperatureKelvin = intValue(smart?["TEMPERATURE"])
        let dataUnitBytes: UInt64 = 512_000

        return SystemDiskIdentity(
            volumeName: volume["VolumeName"] as? String ?? "Macintosh HD",
            fileSystem: volume["FilesystemUserVisibleName"] as? String
                ?? volume["FilesystemType"] as? String
                ?? "APFS",
            mountPoint: volume["MountPoint"] as? String ?? "/",
            deviceIdentifier: volume["DeviceIdentifier"] as? String ?? "--",
            model: device?["MediaName"] as? String ?? "Internal storage",
            connection: device?["BusProtocol"] as? String
                ?? volume["BusProtocol"] as? String
                ?? "Internal",
            isEncrypted: volume["Encryption"] as? Bool,
            isWritable: volume["WritableVolume"] as? Bool,
            smartStatus: device?["SMARTStatus"] as? String
                ?? volume["SMARTStatus"] as? String,
            healthPercent: usedPercent.map { max(0, 100 - $0) },
            temperatureCelsius: temperatureKelvin.map { max(0, $0 - 273) },
            powerCycles: uintValue(smart?["POWER_CYCLES_0"]),
            powerOnHours: uintValue(smart?["POWER_ON_HOURS_0"]),
            unsafeShutdowns: uintValue(smart?["UNSAFE_SHUTDOWNS_0"]),
            mediaErrors: uintValue(smart?["MEDIA_ERRORS_0"]),
            availableSparePercent: intValue(smart?["AVAILABLE_SPARE"]),
            lifetimeReadBytes: uintValue(smart?["DATA_UNITS_READ_0"]).map {
                $0.multipliedReportingOverflow(by: dataUnitBytes).partialValue
            },
            lifetimeWrittenBytes: uintValue(smart?["DATA_UNITS_WRITTEN_0"]).map {
                $0.multipliedReportingOverflow(by: dataUnitBytes).partialValue
            }
        )
    }

    private static func diskutilInfo(_ target: String) -> [String: Any]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", target]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )) as? [String: Any]
    }

    private static func hardwareProfile() -> [String: Any]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let entries = root["SPHardwareDataType"] as? [[String: Any]]
        else {
            return nil
        }
        return entries.first
    }

    private static func productionYear(modelIdentifier: String) -> Int? {
        let exactModelYears: [String: Int] = [
            "Mac15,3": 2023,
            "Mac15,4": 2023,
            "Mac15,5": 2023,
            "Mac15,6": 2023,
            "Mac15,7": 2023,
            "Mac15,8": 2023,
            "Mac15,9": 2023,
            "Mac15,10": 2023,
            "Mac15,11": 2023,
            "Mac15,12": 2024,
            "Mac15,13": 2024,
        ]
        if let year = exactModelYears[modelIdentifier] {
            return year
        }

        return nil
    }

    private static func wholeDiskIdentifier(_ identifier: String) -> String {
        let partitionSuffix = identifier.dropFirst(identifier.hasPrefix("disk") ? 4 : 0)
        guard let separator = partitionSuffix.firstIndex(of: "s") else {
            return identifier
        }
        return String(identifier[..<separator])
    }

    private static func platformSerialNumber() -> String? {
        guard let matching = IOServiceMatching("IOPlatformExpertDevice") else {
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformSerialNumber" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: value)
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }

    private static func percentage(_ value: Any?) -> Double? {
        number(value).map { min(max(Double($0) / 100, 0), 1) }
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return value as? UInt64
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private static func uintValue(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return value as? UInt64
    }
}

private extension String {
    func withPrefix(_ prefix: String) -> String {
        prefix + self
    }
}
