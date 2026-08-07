import Darwin
import Foundation
import IOKit

/// Temperature, power, and fan telemetry for Apple silicon.
///
/// macOS exposes none of this through a supported API. `powermetrics` covers some of it
/// but needs root, and its `smc` sampler was removed in macOS 26, so it can no longer
/// report die temperature at all. The three sources used here are the ones the rest of
/// the ecosystem settled on, and none of them require elevated privileges:
///
/// - **Temperature** — `IOHIDEventSystem` sensor services on usage page `0xff00`.
/// - **Power** — the IOReport `Energy Model` group, sampled as an energy delta.
/// - **Fans** — the `AppleSMC` user client, reading the `F<n>Ac` keys.
///
/// Every reader degrades to `nil` rather than failing: the private symbols are resolved
/// with `dlsym` at run time, so a future OS that moves or drops them produces missing
/// readings instead of a crash or a link error.

// MARK: - Metrics

struct SystemTemperatureSensor: Equatable, Sendable, Identifiable {
    var name: String
    var celsius: Double

    var id: String { name }

    /// PMU die sensors track the SoC itself. The other sensors on the same usage page
    /// (battery gauge, NAND, calibration probes) run much cooler and make a misleading
    /// headline number.
    var isDieSensor: Bool {
        name.localizedCaseInsensitiveContains("tdie")
    }
}

struct SystemThermalMetrics: Equatable, Sendable {
    /// Hottest SoC die sensor, or the hottest sensor of any kind when no die sensor exists.
    var dieTemperatureCelsius: Double?
    var hottestSensorName: String?
    var sensors: [SystemTemperatureSensor] = []
    var fanSpeedsRPM: [Int] = []
    /// Apple's own throttling signal. Unlike everything else here it is public API.
    var thermalPressure: ProcessInfo.ThermalState = .nominal

    var maximumFanRPM: Int? { fanSpeedsRPM.max() }

    var hasFans: Bool { !fanSpeedsRPM.isEmpty }

    var thermalPressureLabel: String {
        switch thermalPressure {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

struct SystemPowerMetrics: Equatable, Sendable {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var dramWatts: Double?
    /// Sum of the SoC rails above plus the fabric/display/PCIe domains, when the
    /// counters are populated. Absent on chips that no longer publish CPU energy.
    var socWatts: Double?
    /// Whole-machine input power from the battery controller. Portables only, but it
    /// survives on hardware where the SoC energy counters have gone away.
    ///
    /// The controller refreshes this on its own schedule — tens of seconds, not once a
    /// second — so a history chart of it holds a value and then steps. That is the source
    /// cadence rather than a sampling artefact, and it is why the SoC rails are preferred
    /// as the headline figure wherever they exist.
    var systemInputWatts: Double?

    var hasAnyReading: Bool {
        socWatts != nil || systemInputWatts != nil || gpuWatts != nil
    }

    /// Best single number to show, preferring the SoC total over whole-system input.
    var headlineWatts: Double? {
        socWatts ?? systemInputWatts ?? gpuWatts
    }

    var headlineLabel: String {
        if socWatts != nil { return "SoC package" }
        if systemInputWatts != nil { return "System input" }
        return "GPU"
    }
}

// MARK: - Sampler

/// Owns the long-lived handles the three readers need. Not thread-safe by itself; the
/// system monitor keeps one instance inside its collector actor and samples at 1 Hz.
final class SystemSensorSampler {
    private let temperatureReader = HIDTemperatureReader()
    private let powerReader = IOReportEnergyReader()
    private let fanReader = SMCFanReader()

    func thermalMetrics() -> SystemThermalMetrics {
        // Several services publish the same `Product` name (a die sensor per cluster, for
        // instance). Collapse them to the hottest reading per name so the list is stable
        // and each entry has a unique identity.
        let sensors = Dictionary(
            grouping: temperatureReader?.read() ?? [],
            by: \.name
        ).compactMap { name, readings -> SystemTemperatureSensor? in
            guard let hottest = readings.map(\.celsius).max() else { return nil }
            return SystemTemperatureSensor(name: name, celsius: hottest)
        }
        let dieSensors = sensors.filter(\.isDieSensor)
        let hottest = (dieSensors.isEmpty ? sensors : dieSensors)
            .max { $0.celsius < $1.celsius }

        return SystemThermalMetrics(
            dieTemperatureCelsius: hottest?.celsius,
            hottestSensorName: hottest?.name,
            sensors: sensors.sorted { $0.celsius > $1.celsius },
            fanSpeedsRPM: fanReader?.read() ?? [],
            thermalPressure: ProcessInfo.processInfo.thermalState
        )
    }

    func powerMetrics() -> SystemPowerMetrics {
        var metrics = powerReader?.sample() ?? SystemPowerMetrics()
        metrics.systemInputWatts = Self.systemInputWatts()
        return metrics
    }

    /// `SystemPowerIn` is published in milliwatts by the battery controller, nested in
    /// its `PowerTelemetryData` dictionary.
    private static func systemInputWatts() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
            let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        let telemetry = properties["PowerTelemetryData"] as? [String: Any]
        guard let milliwatts = (telemetry?["SystemPowerIn"]
            ?? properties["SystemPowerIn"]) as? NSNumber
        else { return nil }

        let watts = milliwatts.doubleValue / 1000
        return watts > 0 ? watts : nil
    }
}

// MARK: - Temperature (IOHIDEventSystem)

private final class HIDTemperatureReader {
    /// `kIOHIDEventTypeTemperature`, and the field selector derived from it.
    private static let temperatureEventType = 15
    private static let temperatureField: Int32 = 15 << 16
    /// Apple's sensor usage page, and the temperature usage within it.
    private static let sensorUsagePage = 0xff00
    private static let sensorUsage = 5
    /// Readings outside this band are a sensor that is asleep or reporting a sentinel.
    private static let plausibleRange = 5.0..<130.0

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias ClientSetMatching =
        @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Void
    private typealias ClientCopyServices =
        @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty =
        @convention(c) (UnsafeMutableRawPointer?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEvent =
        @convention(c) (UnsafeMutableRawPointer?, Int, Int32, Int) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloatValue =
        @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

    private let copyEvent: ServiceCopyEvent
    private let eventFloatValue: EventGetFloatValue
    /// Held to keep the service clients alive for the lifetime of the reader.
    private let services: CFArray
    private let sensorNames: [Int: String]

    init?() {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY
        ) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
            let setMatching = symbol(
                "IOHIDEventSystemClientSetMatching",
                as: ClientSetMatching.self
            ),
            let copyServices = symbol(
                "IOHIDEventSystemClientCopyServices",
                as: ClientCopyServices.self
            ),
            let copyProperty = symbol(
                "IOHIDServiceClientCopyProperty",
                as: ServiceCopyProperty.self
            ),
            let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
            let eventFloatValue = symbol("IOHIDEventGetFloatValue", as: EventGetFloatValue.self),
            let client = create(kCFAllocatorDefault)
        else { return nil }

        let matching: [String: Any] = [
            "PrimaryUsagePage": Self.sensorUsagePage,
            "PrimaryUsage": Self.sensorUsage,
        ]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client)?.takeRetainedValue(),
              CFArrayGetCount(services) > 0
        else { return nil }

        self.copyEvent = copyEvent
        self.eventFloatValue = eventFloatValue
        self.services = services

        // Sensor names never change, so resolve them once rather than every sample.
        var names: [Int: String] = [:]
        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index) else { continue }
            let mutableService = UnsafeMutableRawPointer(mutating: service)
            guard let property = copyProperty(mutableService, "Product" as CFString)?
                .takeRetainedValue(),
                let name = property as? String,
                !name.isEmpty
            else { continue }
            names[index] = name
        }
        sensorNames = names
    }

    func read() -> [SystemTemperatureSensor] {
        var readings: [SystemTemperatureSensor] = []
        readings.reserveCapacity(sensorNames.count)

        for (index, name) in sensorNames {
            guard let service = CFArrayGetValueAtIndex(services, index) else { continue }
            let mutableService = UnsafeMutableRawPointer(mutating: service)
            guard let event = copyEvent(
                mutableService,
                Self.temperatureEventType,
                0,
                0
            )?.takeRetainedValue() else { continue }

            let celsius = eventFloatValue(
                Unmanaged.passUnretained(event).toOpaque(),
                Self.temperatureField
            )
            guard Self.plausibleRange.contains(celsius) else { continue }
            readings.append(SystemTemperatureSensor(name: name, celsius: celsius))
        }
        return readings
    }
}

// MARK: - Power (IOReport Energy Model)

private final class IOReportEnergyReader {
    private typealias CopyChannelsInGroup = @convention(c) (
        CFString?, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary?,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        UnsafeMutableRawPointer?
    ) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary?, UnsafeMutableRawPointer?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (
        CFDictionary?, CFDictionary?, UnsafeMutableRawPointer?
    ) -> Unmanaged<CFDictionary>?
    private typealias IterateSamples =
        @convention(c) (CFDictionary?, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelString = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias ChannelInteger = @convention(c) (CFDictionary?, Int32) -> Int64

    /// Fabric, memory-controller, display, and media domains. Each is a separate rail
    /// that contributes to package power but is not part of CPU/GPU/ANE/DRAM.
    private static let fabricChannels: Set<String> = [
        "AMCC", "DCS", "ISP", "AVE", "MSR", "AFR", "DISP", "DISPEXT",
    ]
    /// Below this the counters exist but are not being updated, and the sum is noise.
    private static let liveThresholdMilliwatts = 500.0

    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let iterate: IterateSamples
    private let channelName: ChannelString
    private let unitLabel: ChannelString
    private let integerValue: ChannelInteger

    private let subscription: AnyObject
    private let subscribedChannels: CFMutableDictionary

    private var previousSample: CFDictionary?
    private var previousSampleTime: DispatchTime?

    init?() {
        // macOS 26 moved IOReport out of the private framework and into a top-level dylib.
        let candidates = [
            "/usr/lib/libIOReport.dylib",
            "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
            "/System/Library/PrivateFrameworks/PowerlogCore.framework/PowerlogCore",
        ]
        guard let handle = candidates.lazy.compactMap({ dlopen($0, RTLD_LAZY) }).first
        else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let copyChannels = symbol(
                "IOReportCopyChannelsInGroup",
                as: CopyChannelsInGroup.self
            ),
            let createSubscription = symbol(
                "IOReportCreateSubscription",
                as: CreateSubscription.self
            ),
            let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
            let createSamplesDelta = symbol(
                "IOReportCreateSamplesDelta",
                as: CreateSamplesDelta.self
            ),
            let iterate = symbol("IOReportIterate", as: IterateSamples.self),
            let channelName = symbol(
                "IOReportChannelGetChannelName",
                as: ChannelString.self
            ),
            let unitLabel = symbol("IOReportChannelGetUnitLabel", as: ChannelString.self),
            let integerValue = symbol(
                "IOReportSimpleGetIntegerValue",
                as: ChannelInteger.self
            ),
            let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?
                .takeRetainedValue()
        else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil)?
            .takeRetainedValue(),
            let subscribedChannels = subscribed?.takeRetainedValue()
        else { return nil }

        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.iterate = iterate
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels
    }

    /// Energy counters are cumulative, so power is the delta between two samples divided
    /// by the interval. The caller already ticks once a second, which is the interval —
    /// no sleep, unlike a one-shot command line reader.
    func sample() -> SystemPowerMetrics {
        guard let currentUnmanaged = createSamples(
            Unmanaged.passUnretained(subscription).toOpaque(),
            subscribedChannels,
            nil
        ) else { return SystemPowerMetrics() }

        let current = currentUnmanaged.takeRetainedValue()
        let now = DispatchTime.now()
        defer {
            previousSample = current
            previousSampleTime = now
        }

        guard let previous = previousSample, let previousTime = previousSampleTime else {
            return SystemPowerMetrics()
        }
        let elapsed = Double(now.uptimeNanoseconds - previousTime.uptimeNanoseconds) / 1e9
        guard elapsed > 0.05,
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue()
        else { return SystemPowerMetrics() }

        var milliwattsByChannel: [String: Double] = [:]
        iterate(delta) { [channelName, unitLabel, integerValue] sample in
            guard let name = channelName(sample)?.takeUnretainedValue() as String?
            else { return 0 }
            let raw = Double(integerValue(sample, 0))
            guard raw > 0 else { return 0 }

            // Channels report accumulated energy; the unit varies by rail.
            let unit = unitLabel(sample)?.takeUnretainedValue() as String? ?? ""
            let millijoules: Double = switch unit {
            case "nJ": raw / 1e6
            case "uJ": raw / 1e3
            default: raw
            }
            milliwattsByChannel[name] = millijoules / elapsed
            return 0
        }

        return Self.metrics(from: milliwattsByChannel)
    }

    private static func metrics(from milliwatts: [String: Double]) -> SystemPowerMetrics {
        // The same rail is published at several granularities (core, then cluster, then
        // an aggregate) and occasionally under two names in different units. Taking the
        // maximum across the aliases avoids double counting.
        func rail(_ names: String...) -> Double? {
            let values = names.compactMap { milliwatts[$0] }
            return values.isEmpty ? nil : values.max()
        }

        let cpu = rail("CPU Energy", "ECPU", "PCPU")
        let gpu = rail("GPU", "GPU Energy")
        let ane = rail("ANE", "ANE0", "ANE Energy")
        let dram = rail("DRAM", "DRAM0", "DRAM Energy")

        let fabric = milliwatts
            .filter { fabricChannels.contains($0.key) }
            .values
            .reduce(0, +)
        let peripheral = milliwatts
            .filter { $0.key.hasPrefix("PCIe") || $0.key.hasPrefix("apciec") }
            .values
            .reduce(0, +)

        let total = (cpu ?? 0) + (gpu ?? 0) + (ane ?? 0) + (dram ?? 0) + fabric + peripheral

        // A GPU rail on its own is not a package total. Newer silicon publishes only
        // `GPU Energy` here, and reporting that as SoC power would badly understate it.
        let hasPackageCoverage = cpu != nil && total >= liveThresholdMilliwatts

        return SystemPowerMetrics(
            cpuWatts: cpu.map { $0 / 1000 },
            gpuWatts: gpu.map { $0 / 1000 },
            aneWatts: ane.map { $0 / 1000 },
            dramWatts: dram.map { $0 / 1000 },
            socWatts: hasPackageCoverage ? total / 1000 : nil,
            systemInputWatts: nil
        )
    }
}

// MARK: - Fans (AppleSMC)

private final class SMCFanReader {
    private enum Selector {
        static let kernelIndex: UInt32 = 2
        static let readBytes: UInt8 = 5
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    private let connection: io_connect_t
    private let fanKeys: [UInt32]

    /// The user client validates the struct size and rejects anything else, so confirm
    /// Swift laid `SMCKeyData` out exactly as the driver expects before opening it.
    private static let wireStructSize = 80

    init?() {
        guard MemoryLayout<SMCKeyData>.stride == Self.wireStructSize else { return nil }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
        else { return nil }
        self.connection = connection

        // `FNum` is missing on some Apple silicon Macs, so enumerate the key table and
        // match `F<n>Ac` (actual speed) directly rather than trusting a fan count.
        guard let countData = Self.readKey(Self.fourCharCode("#KEY"), connection: connection)
        else {
            IOServiceClose(connection)
            return nil
        }
        let total = countData.withUnsafeBytes { buffer -> UInt32 in
            guard buffer.count >= 4 else { return 0 }
            return (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16)
                | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
        }

        var keys: [UInt32] = []
        for index in 0..<total {
            var input = SMCKeyData()
            input.data8 = Selector.readIndex
            input.data32 = index
            guard let output = Self.call(input, connection: connection) else { continue }

            let key = output.key
            let characters = [
                UInt8((key >> 24) & 0xff), UInt8((key >> 16) & 0xff),
                UInt8((key >> 8) & 0xff), UInt8(key & 0xff),
            ]
            guard characters[0] == UInt8(ascii: "F"),
                  characters[1] >= UInt8(ascii: "0"), characters[1] <= UInt8(ascii: "9"),
                  characters[2] == UInt8(ascii: "A"),
                  characters[3] == UInt8(ascii: "c")
            else { continue }
            keys.append(key)
        }
        fanKeys = keys
    }

    deinit {
        IOServiceClose(connection)
    }

    func read() -> [Int] {
        fanKeys.compactMap { key in
            guard let data = Self.readKey(key, connection: connection), data.count >= 4
            else { return nil }
            // Apple silicon publishes fan speeds as `flt ` — a little-endian IEEE float.
            let rpm = data.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
            guard rpm.isFinite, rpm >= 0, rpm < 20_000 else { return nil }
            return Int(rpm.rounded())
        }
    }

    /// Reading a key is two calls: fetch its size, then fetch its bytes.
    ///
    /// The input and output structs must be separate allocations. The driver writes back
    /// into fields of the reply that it then validates on the following call, so reusing
    /// one buffer for both fails with result 132/137.
    private static func readKey(_ key: UInt32, connection: io_connect_t) -> Data? {
        var info = SMCKeyData()
        info.key = key
        info.data8 = Selector.readKeyInfo
        guard let infoResult = call(info, connection: connection) else { return nil }

        var request = SMCKeyData()
        request.key = key
        request.keyInfo.dataSize = infoResult.keyInfo.dataSize
        request.data8 = Selector.readBytes
        guard let result = call(request, connection: connection) else { return nil }

        var bytes = result.bytes
        let size = Int(infoResult.keyInfo.dataSize)
        return withUnsafeBytes(of: &bytes) { buffer in
            Data(buffer.prefix(min(size, MemoryLayout<SMCBytes>.size)))
        }
    }

    private static func call(_ input: SMCKeyData, connection: io_connect_t) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let status = IOConnectCallStructMethod(
            connection,
            Selector.kernelIndex,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - AppleSMC wire format

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPowerLimit: UInt32 = 0
    var gpuPowerLimit: UInt32 = 0
    var memoryPowerLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    /// C gives this struct three bytes of tail padding to reach its four-byte alignment,
    /// and that padding counts towards the enclosing struct's layout. Swift does not add
    /// it implicitly when nesting, so it is spelled out to keep the wire format at the
    /// 80 bytes the driver expects.
    private var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// Mirrors the `SMCKeyData_t` layout the AppleSMC user client expects (80 bytes).
private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPowerLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}
