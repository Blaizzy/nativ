import AppKit
import Charts
import SwiftUI

private enum SystemMonitorDestination: String, CaseIterable, Identifiable {
    case overview
    case cpu
    case gpu
    case memory
    case disk
    case sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .cpu:
            "CPU"
        case .gpu:
            "GPU"
        case .memory:
            "Memory"
        case .disk:
            "Disk"
        case .sensors:
            "Sensors"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "square.grid.2x2"
        case .cpu:
            "cpu"
        case .gpu:
            "display"
        case .memory:
            "memorychip"
        case .disk:
            "internaldrive"
        case .sensors:
            "thermometer.medium"
        }
    }
}

struct SystemMonitorView: View {
    var store: SystemMonitorStore
    @ObservedObject var menuBarPreferences: SystemMenuBarPreferences
    var titleLeadingInset: CGFloat = 0
    @State private var destination: SystemMonitorDestination = .overview
    @State private var isMenuBarControlHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            destinationBar
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nativMainContentBackground)
        .onAppear {
            store.start()
        }
        .onDisappear {
            store.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System")
                    .font(.title2.weight(.semibold))
                Text("Live performance monitoring and hardware health for this Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            menuBarControl

            HStack(spacing: 7) {
                Circle()
                    .fill(store.isSampling ? SystemMonitorPalette.positive : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(store.isSampling ? "Live" : "Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Button {
                if store.isSampling {
                    store.stop()
                } else {
                    store.start()
                }
            } label: {
                Image(systemName: store.isSampling ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(store.isSampling ? "Pause monitoring" : "Resume monitoring")

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .padding(.top, ControlPanelLayout.detailHeaderTopInset)
        .padding(.bottom, 16)
    }

    private var menuBarControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "menubar.rectangle")
                .foregroundStyle(Color.accentColor)

            Text("Customize Menu Bar")
                .foregroundStyle(.primary)

            Text("\(menuBarItemCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.accentColor, in: Capsule())

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    Color.accentColor.opacity(
                        isMenuBarControlHovered ? 0.14 : 0.07
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(
                        isMenuBarControlHovered ? 0.65 : 0.32
                    ),
                    lineWidth: 1
                )
        }
        .contentShape(.rect)
        .overlay {
            MenuBarCustomizationMenuControl(preferences: menuBarPreferences)
        }
        .fixedSize()
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.12)) {
                isMenuBarControlHovered = isHovered
            }
        }
        .help("Choose which metrics appear in the macOS menu bar")
    }

    private var menuBarItemCount: Int {
        max(menuBarPreferences.orderedItems.count, 1)
    }

    private var destinationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SystemMonitorDestination.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            destination = item
                        }
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .foregroundStyle(destination == item ? Color.white : Color.primary)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        destination == item
                                            ? Color.accentColor
                                            : Color.clear
                                    )
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(destination == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch destination {
        case .overview:
            SystemOverviewPage(snapshot: store.snapshot)
        case .cpu:
            SystemCPUPage(snapshot: store.snapshot, history: store.cpuHistory)
        case .gpu:
            SystemGPUPage(
                snapshot: store.snapshot,
                gpuHistory: store.gpuHistory,
                aneHistory: store.aneHistory,
                fpsHistory: store.fpsHistory
            )
        case .memory:
            SystemMemoryPage(
                snapshot: store.snapshot,
                memoryHistory: store.memoryHistory,
                swapHistory: store.swapHistory
            )
        case .disk:
            SystemDiskPage(
                snapshot: store.snapshot,
                readHistory: store.diskReadHistory,
                writeHistory: store.diskWriteHistory
            )
        case .sensors:
            SystemSensorsPage(
                snapshot: store.snapshot,
                temperatureHistory: store.temperatureHistory,
                powerHistory: store.powerHistory
            )
        }
    }
}

private struct SystemOverviewPage: View {
    let snapshot: SystemMonitorSnapshot

    var body: some View {
        SystemMonitorPage(title: "Overview", subtitle: "Hardware at a glance") {
            SystemPanel {
                VStack(spacing: 14) {
                    SystemDeviceArtwork(identity: snapshot.identity)

                    VStack(spacing: 4) {
                        Text(snapshot.identity.computerName)
                            .font(.title2.weight(.semibold))
                        Text(snapshot.identity.chipName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(snapshot.identity.operatingSystem)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .flexible(minimum: 140),
                        spacing: 14
                    ),
                    count: 4
                ),
                spacing: 14
            ) {
                SystemOverviewMetric(
                    title: "CPU",
                    value: SystemMonitorFormat.percent(snapshot.cpu.totalUsage),
                    detail: "\(snapshot.identity.physicalCoreCount) cores",
                    icon: "cpu",
                    tint: SystemMonitorPalette.blue
                )
                SystemOverviewMetric(
                    title: "GPU",
                    value: SystemMonitorFormat.optionalPercent(snapshot.gpu.deviceUsage),
                    detail: gpuDetail,
                    icon: "display",
                    tint: SystemMonitorPalette.purple
                )
                SystemOverviewMetric(
                    title: "Memory",
                    value: SystemMonitorFormat.percent(snapshot.memory.usage),
                    detail: "\(SystemMonitorFormat.memoryBytes(snapshot.memory.usedBytes)) used",
                    icon: "memorychip",
                    tint: SystemMonitorPalette.positive
                )
                SystemOverviewMetric(
                    title: "Disk",
                    value: SystemMonitorFormat.optionalPercent(snapshot.disk.usage),
                    detail: snapshot.disk.availableBytes
                        .map { "\(SystemMonitorFormat.bytes($0)) available" }
                        ?? "Capacity unavailable",
                    icon: "internaldrive",
                    tint: SystemMonitorPalette.orange
                )
            }
            .frame(maxWidth: .infinity)

            adaptivePair {
                SystemInfoCard(title: "Hardware") {
                    SystemInfoRow(
                        "Processor",
                        value: "\(snapshot.identity.chipName) · \(coreSummary)"
                    )
                    SystemInfoRow(
                        "Memory",
                        value: SystemMonitorFormat.memoryBytes(snapshot.memory.totalBytes)
                    )
                    SystemInfoRow(
                        "Graphics",
                        value: graphicsSummary
                    )
                    SystemInfoRow(
                        "Neural Engine",
                        value: snapshot.identity.aneCoreCount
                            .map { "\($0) cores" } ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Disk",
                        value: snapshot.disk.totalBytes
                            .map {
                                "\(snapshot.identity.disk.volumeName) · \(SystemMonitorFormat.bytes($0))"
                            }
                            ?? "\(snapshot.identity.disk.volumeName) · Unavailable"
                    )
                    SystemInfoRow(
                        "Display",
                        value: displaySummary
                    )
                }
            } trailing: {
                SystemInfoCard(title: "Device") {
                    SystemInfoRow("Model identifier", value: snapshot.identity.modelIdentifier)
                    SystemInfoRow(
                        "Model number",
                        value: snapshot.identity.modelNumber ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Production year",
                        value: snapshot.identity.productionYear.map(String.init) ?? "Unavailable"
                    )
                    SystemInfoRow("Serial number", value: snapshot.identity.serialNumber)
                    SystemInfoRow("File system", value: snapshot.identity.disk.fileSystem)
                    SystemInfoRow(
                        "Storage health",
                        value: snapshot.identity.disk.smartStatus ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Uptime",
                        value: SystemMonitorFormat.uptime(snapshot.uptime)
                    )
                }
            }
        }
    }

    private var coreSummary: String {
        if snapshot.identity.efficiencyCoreCount > 0
            || snapshot.identity.performanceCoreCount > 0 {
            return "\(snapshot.identity.efficiencyCoreCount)E / \(snapshot.identity.performanceCoreCount)P"
        }
        return "\(snapshot.identity.physicalCoreCount) cores"
    }

    private var graphicsSummary: String {
        if let count = snapshot.identity.gpuCoreCount {
            return "\(snapshot.identity.gpuName) · \(count) cores"
        }
        return snapshot.identity.gpuName
    }

    private var gpuDetail: String {
        snapshot.identity.gpuCoreCount.map { "\($0) cores" } ?? snapshot.identity.gpuName
    }

    private var displaySummary: String {
        var components = [
            snapshot.identity.displayName,
            snapshot.identity.displayResolution,
        ]
        if let refreshRate = snapshot.identity.displayRefreshRate {
            components.append("\(Int(refreshRate.rounded())) Hz")
        }
        return components.joined(separator: " · ")
    }
}

private struct SystemSensorsPage: View {
    let snapshot: SystemMonitorSnapshot
    let temperatureHistory: [SystemHistorySample]
    let powerHistory: [SystemHistorySample]

    var body: some View {
        SystemMonitorPage(title: "Sensors", subtitle: subtitle) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 140), spacing: 14),
                    count: 4
                ),
                spacing: 14
            ) {
                SystemOverviewMetric(
                    title: "Die temperature",
                    value: SystemMonitorFormat.celsius(
                        snapshot.thermal.dieTemperatureCelsius
                    ),
                    detail: snapshot.thermal.hottestSensorName ?? "Unavailable",
                    icon: "thermometer.medium",
                    tint: SystemMonitorPalette.red
                )
                SystemOverviewMetric(
                    title: "Power",
                    value: SystemMonitorFormat.watts(snapshot.power.headlineWatts),
                    detail: snapshot.power.hasAnyReading
                        ? snapshot.power.headlineLabel
                        : "Unavailable",
                    icon: "bolt.fill",
                    tint: SystemMonitorPalette.orange
                )
                SystemOverviewMetric(
                    title: "Fans",
                    value: SystemMonitorFormat.rpm(snapshot.thermal.maximumFanRPM),
                    detail: fanDetail,
                    icon: "fan.fill",
                    tint: SystemMonitorPalette.teal
                )
                SystemOverviewMetric(
                    title: "Thermal pressure",
                    value: snapshot.thermal.thermalPressureLabel,
                    detail: snapshot.thermal.thermalPressure == .nominal
                        ? "Not throttling"
                        : "Throttling likely",
                    icon: "gauge.with.dots.needle.67percent",
                    tint: pressureTint
                )
            }
            .frame(maxWidth: .infinity)

            SystemValueHistoryChart(
                title: "Temperature history",
                samples: temperatureHistory,
                color: SystemMonitorPalette.red,
                seriesName: "Die temperature",
                format: { SystemMonitorFormat.celsius($0) },
                axisStep: 10,
                axisMinimum: 60,
                anchorsAtZero: false
            )

            SystemValueHistoryChart(
                title: "Power history",
                samples: powerHistory,
                color: SystemMonitorPalette.orange,
                seriesName: snapshot.power.headlineLabel,
                format: { SystemMonitorFormat.watts($0) },
                axisStep: 10,
                axisMinimum: 10
            )

            adaptivePair {
                SystemInfoCard(title: "Power breakdown") {
                    SystemInfoRow("CPU", value: SystemMonitorFormat.watts(snapshot.power.cpuWatts))
                    SystemInfoRow("GPU", value: SystemMonitorFormat.watts(snapshot.power.gpuWatts))
                    SystemInfoRow(
                        "Neural Engine",
                        value: SystemMonitorFormat.watts(snapshot.power.aneWatts)
                    )
                    SystemInfoRow(
                        "Memory",
                        value: SystemMonitorFormat.watts(snapshot.power.dramWatts)
                    )
                    SystemInfoRow(
                        "SoC package",
                        value: SystemMonitorFormat.watts(snapshot.power.socWatts)
                    )
                    SystemInfoRow(
                        "System input",
                        value: SystemMonitorFormat.watts(snapshot.power.systemInputWatts)
                    )
                }
            } trailing: {
                SystemInfoCard(title: "Cooling") {
                    if snapshot.thermal.hasFans {
                        ForEach(
                            Array(snapshot.thermal.fanSpeedsRPM.enumerated()),
                            id: \.offset
                        ) { index, rpm in
                            SystemInfoRow(
                                "Fan \(index + 1)",
                                value: SystemMonitorFormat.rpm(rpm)
                            )
                        }
                    } else {
                        SystemInfoRow("Fans", value: "Fanless design")
                    }
                    SystemInfoRow(
                        "Thermal pressure",
                        value: snapshot.thermal.thermalPressureLabel
                    )
                    SystemInfoRow("Sensors", value: "\(snapshot.thermal.sensors.count)")
                }
            }

            if !snapshot.thermal.sensors.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("All sensors")
                        .font(.headline)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                        spacing: 12
                    ) {
                        ForEach(snapshot.thermal.sensors) { sensor in
                            SystemInfoRow(
                                sensor.name,
                                value: SystemMonitorFormat.celsius(sensor.celsius)
                            )
                        }
                    }
                    .padding(14)
                    .systemMonitorPanel()
                }
            }
        }
    }

    private var subtitle: String {
        guard let temperature = snapshot.thermal.dieTemperatureCelsius else {
            return "Temperature, power, and cooling"
        }
        return "\(SystemMonitorFormat.celsius(temperature)) · \(snapshot.thermal.sensors.count) sensors"
    }

    private var fanDetail: String {
        guard snapshot.thermal.hasFans else { return "Fanless design" }
        return "\(snapshot.thermal.fanSpeedsRPM.count) fans"
    }

    private var pressureTint: Color {
        switch snapshot.thermal.thermalPressure {
        case .nominal: SystemMonitorPalette.positive
        case .fair: SystemMonitorPalette.orange
        default: SystemMonitorPalette.red
        }
    }

    @ViewBuilder
    private func adaptivePair<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                leading()
                trailing()
            }
            VStack(spacing: 14) {
                leading()
                trailing()
            }
        }
    }
}

private struct SystemDeviceArtwork: View {
    let identity: SystemMonitorIdentity

    var body: some View {
        Group {
            if let image = SystemDeviceArtworkProvider.image(for: identity) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityLabel("\(identity.computerName) device image")
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.18),
                                    SystemMonitorPalette.purple.opacity(0.10),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 50, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 112, height: 82)
                .accessibilityLabel("\(identity.computerName) device")
            }
        }
        .frame(width: 220, height: 126)
    }
}

@MainActor
private enum SystemDeviceArtworkProvider {
    private static let coreTypesResourcesURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle"
    )
    .appendingPathComponent("Contents/Resources", isDirectory: true)

    private static let imageCache = NSCache<NSString, NSImage>()
    private static let motionPurpleWallpaper = NSImage(
        contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Motion Purple Dark.heic"
    )
    private static let proBlackWallpaper = NSImage(
        contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Pro Black.heic"
    )

    static func image(for identity: SystemMonitorIdentity) -> NSImage? {
        guard let resourceName = resourceName(for: identity) else {
            return NSImage(named: NSImage.computerName)
        }
        if let cachedImage = imageCache.object(forKey: resourceName as NSString) {
            return cachedImage
        }

        let imageURL = coreTypesResourcesURL
            .appendingPathComponent(resourceName)
            .appendingPathExtension("icns")
        guard let sourceImage = NSImage(contentsOf: imageURL) else {
            return NSImage(named: NSImage.computerName)
        }

        let image: NSImage
        if resourceName.contains("macbook") {
            image = croppedLaptopImage(
                sourceImage,
                wallpaper: wallpaper(for: identity)
            )
        } else {
            image = sourceImage
        }
        imageCache.setObject(image, forKey: resourceName as NSString)
        return image
    }

    private static func wallpaper(
        for identity: SystemMonitorIdentity
    ) -> NSImage? {
        if identity.computerName
            .localizedCaseInsensitiveContains("MacBook Pro") {
            return proBlackWallpaper ?? motionPurpleWallpaper
        }
        return motionPurpleWallpaper
    }

    private static func resourceName(
        for identity: SystemMonitorIdentity
    ) -> String? {
        let machineName = identity.computerName.lowercased()

        if machineName.contains("macbook pro") {
            let sixteenInchModels: Set<String> = [
                "MacBookPro16,1", "MacBookPro16,4",
                "MacBookPro18,1", "MacBookPro18,2",
                "Mac14,6", "Mac14,10",
                "Mac15,7", "Mac15,9", "Mac15,11",
            ]
            let size = sixteenInchModels.contains(identity.modelIdentifier)
                ? "16"
                : "14"
            return "com.apple.macbookpro-\(size)-2021-space-gray"
        }
        if machineName.contains("macbook air") {
            return "com.apple.macbookair-13-2022-midnight"
        }
        if machineName.contains("mac studio") {
            return "com.apple.macstudio"
        }
        if machineName.contains("mac mini") {
            return "com.apple.macmini-2020"
        }
        if machineName.contains("imac") {
            return "com.apple.imac-2021-silver"
        }
        if machineName.contains("mac pro") {
            return "com.apple.macpro-2019"
        }
        return nil
    }

    private static func croppedLaptopImage(
        _ sourceImage: NSImage,
        wallpaper: NSImage?
    ) -> NSImage {
        let sourceSize = sourceImage.size
        let sourceRect = NSRect(
            x: sourceSize.width * 0.065,
            y: sourceSize.height * 0.15,
            width: sourceSize.width * 0.87,
            height: sourceSize.height * 0.56
        )
        let outputSize = NSSize(width: 220, height: 140)
        return NSImage(size: outputSize, flipped: false) { outputRect in
            sourceImage.draw(
                in: outputRect,
                from: sourceRect,
                operation: .sourceOver,
                fraction: 1
            )
            drawLaptopWallpaper(wallpaper, in: outputRect)
            return true
        }
    }

    private static func drawLaptopWallpaper(
        _ wallpaper: NSImage?,
        in rect: NSRect
    ) {
        guard let wallpaper else { return }

        let screenRect = NSRect(
            x: rect.minX + (rect.width * 0.164),
            y: rect.minY + (rect.height * 0.239),
            width: rect.width * 0.672,
            height: rect.height * 0.675
        )
        let wallpaperSize = wallpaper.size
        let targetAspectRatio = screenRect.width / screenRect.height
        let sourceAspectRatio = wallpaperSize.width / wallpaperSize.height
        let wallpaperSourceRect: NSRect

        if sourceAspectRatio > targetAspectRatio {
            let width = wallpaperSize.height * targetAspectRatio
            wallpaperSourceRect = NSRect(
                x: (wallpaperSize.width - width) / 2,
                y: 0,
                width: width,
                height: wallpaperSize.height
            )
        } else {
            let height = wallpaperSize.width / targetAspectRatio
            wallpaperSourceRect = NSRect(
                x: 0,
                y: (wallpaperSize.height - height) / 2,
                width: wallpaperSize.width,
                height: height
            )
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: screenRect,
            xRadius: 0.8,
            yRadius: 0.8
        ).addClip()
        wallpaper.draw(
            in: screenRect,
            from: wallpaperSourceRect,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let notchRect = NSRect(
            x: screenRect.midX - (screenRect.width * 0.062),
            y: screenRect.maxY - (screenRect.height * 0.055),
            width: screenRect.width * 0.124,
            height: screenRect.height * 0.055
        )
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: notchRect,
            xRadius: 1.8,
            yRadius: 1.8
        ).fill()
    }
}

private struct SystemCPUPage: View {
    let snapshot: SystemMonitorSnapshot
    let history: [SystemHistorySample]

    var body: some View {
        SystemMonitorPage(
            title: "CPU",
            subtitle: "\(snapshot.identity.chipName) · \(snapshot.identity.physicalCoreCount) cores"
        ) {
            SystemPanel {
                HStack(spacing: 24) {
                    SystemUsageGauge(
                        value: snapshot.cpu.totalUsage,
                        tint: SystemMonitorPalette.blue,
                        label: "CPU usage"
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        Text(snapshot.identity.chipName)
                            .font(.headline)

                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(SystemMonitorPalette.red)
                                    .frame(
                                        width: geometry.size.width * snapshot.cpu.systemUsage
                                    )
                                Rectangle()
                                    .fill(SystemMonitorPalette.blue)
                                    .frame(width: geometry.size.width * snapshot.cpu.userUsage)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.18))
                            }
                            .clipShape(.rect(cornerRadius: 4))
                        }
                        .frame(height: 13)

                        HStack(spacing: 18) {
                            SystemLegendItem(
                                title: "System",
                                value: SystemMonitorFormat.percent(snapshot.cpu.systemUsage),
                                color: SystemMonitorPalette.red
                            )
                            SystemLegendItem(
                                title: "User",
                                value: SystemMonitorFormat.percent(snapshot.cpu.userUsage),
                                color: SystemMonitorPalette.blue
                            )
                            SystemLegendItem(
                                title: "Idle",
                                value: SystemMonitorFormat.percent(snapshot.cpu.idleUsage),
                                color: Color.secondary.opacity(0.45)
                            )
                        }
                    }
                }
            }

            SystemPercentHistoryChart(
                title: "Usage history",
                samples: history,
                color: SystemMonitorPalette.blue
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Load per core")
                    .font(.headline)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                    spacing: 12
                ) {
                    ForEach(Array(snapshot.cpu.coreUsage.enumerated()), id: \.offset) {
                        index,
                        usage in
                        SystemCoreLoadRow(
                            title: coreTitle(index),
                            value: usage,
                            tint: isEfficiencyCore(index)
                                ? SystemMonitorPalette.blue
                                : SystemMonitorPalette.orange
                        )
                    }
                }
                .padding(14)
                .systemMonitorPanel()
            }

        }
    }

    private func isEfficiencyCore(_ index: Int) -> Bool {
        index < snapshot.identity.efficiencyCoreCount
    }

    private func coreTitle(_ index: Int) -> String {
        if isEfficiencyCore(index) {
            return "Efficiency core \(index + 1)"
        }
        let performanceIndex = index - snapshot.identity.efficiencyCoreCount + 1
        return "Performance core \(max(performanceIndex, 1))"
    }
}

private struct SystemGPUPage: View {
    let snapshot: SystemMonitorSnapshot
    let gpuHistory: [SystemHistorySample]
    let aneHistory: [SystemHistorySample]
    let fpsHistory: [SystemHistorySample]

    var body: some View {
        SystemMonitorPage(title: "GPU", subtitle: gpuTitle) {
            SystemPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(snapshot.identity.gpuName, systemImage: "display")
                            .font(.headline)
                        Spacer()
                        if let memory = snapshot.gpu.allocatedMemoryBytes {
                            Text("\(SystemMonitorFormat.memoryBytes(memory)) allocated")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SystemLabeledProgress(
                        title: "GPU utilization",
                        value: snapshot.gpu.deviceUsage,
                        tint: SystemMonitorPalette.blue
                    )
                    SystemLabeledProgress(
                        title: "Neural Engine utilization",
                        value: snapshot.gpu.aneUsage,
                        tint: SystemMonitorPalette.orange
                    )

                    HStack {
                        Label("Display frame rate", systemImage: "speedometer")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(SystemMonitorFormat.framesPerSecond(
                            snapshot.gpu.framesPerSecond
                        ))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    }
                }
            }

            adaptivePair {
                SystemPercentHistoryChart(
                    title: "GPU utilization history",
                    samples: gpuHistory,
                    color: SystemMonitorPalette.blue
                )
            } trailing: {
                SystemPercentHistoryChart(
                    title: "Neural Engine utilization history",
                    samples: aneHistory,
                    color: SystemMonitorPalette.orange
                )
            }

            SystemFPSHistoryChart(samples: fpsHistory)
        }
    }

    private var gpuTitle: String {
        if let count = snapshot.identity.gpuCoreCount {
            return "\(snapshot.identity.gpuName) · \(count) cores"
        }
        return snapshot.identity.gpuName
    }
}

private struct SystemMemoryPage: View {
    let snapshot: SystemMonitorSnapshot
    let memoryHistory: [SystemHistorySample]
    let swapHistory: [SystemHistorySample]

    var body: some View {
        SystemMonitorPage(
            title: "Memory",
            subtitle: "\(SystemMonitorFormat.memoryBytes(snapshot.memory.totalBytes)) unified memory"
        ) {
            SystemPanel {
                HStack(spacing: 24) {
                    SystemMemoryPressureRing(memory: snapshot.memory)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(
                                "Used: \(SystemMonitorFormat.memoryBytes(snapshot.memory.usedBytes))"
                            )
                                .font(.headline)
                            Spacer()
                            Text(
                                "Total: \(SystemMonitorFormat.memoryBytes(snapshot.memory.totalBytes))"
                            )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                memorySegment(
                                    snapshot.memory.activeBytes,
                                    color: SystemMonitorPalette.blue,
                                    width: geometry.size.width
                                )
                                memorySegment(
                                    snapshot.memory.wiredBytes,
                                    color: SystemMonitorPalette.orange,
                                    width: geometry.size.width
                                )
                                memorySegment(
                                    snapshot.memory.compressedBytes,
                                    color: SystemMonitorPalette.red,
                                    width: geometry.size.width
                                )
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.18))
                            }
                            .clipShape(.rect(cornerRadius: 4))
                        }
                        .frame(height: 13)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                memoryLegend
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                memoryLegend
                            }
                        }
                    }
                }
            }

            SystemPercentHistoryChart(
                title: "Memory usage history",
                samples: memoryHistory,
                color: SystemMonitorPalette.blue
            )

            SystemPercentHistoryChart(
                title: "Swap history",
                samples: swapHistory,
                color: SystemMonitorPalette.purple,
                footer: "\(SystemMonitorFormat.memoryBytes(snapshot.memory.swapUsedBytes)) of \(SystemMonitorFormat.memoryBytes(snapshot.memory.swapTotalBytes))"
            )
        }
    }

    @ViewBuilder
    private func memorySegment(_ bytes: UInt64, color: Color, width: CGFloat) -> some View {
        if snapshot.memory.totalBytes > 0 {
            Rectangle()
                .fill(color)
                .frame(
                    width: width * Double(bytes) / Double(snapshot.memory.totalBytes)
                )
        }
    }

    @ViewBuilder
    private var memoryLegend: some View {
        SystemLegendItem(
            title: "Active",
            value: SystemMonitorFormat.memoryBytes(snapshot.memory.activeBytes),
            color: SystemMonitorPalette.blue
        )
        SystemLegendItem(
            title: "Wired",
            value: SystemMonitorFormat.memoryBytes(snapshot.memory.wiredBytes),
            color: SystemMonitorPalette.orange
        )
        SystemLegendItem(
            title: "Compressed",
            value: SystemMonitorFormat.memoryBytes(snapshot.memory.compressedBytes),
            color: SystemMonitorPalette.red
        )
        SystemLegendItem(
            title: "Available",
            value: SystemMonitorFormat.memoryBytes(snapshot.memory.freeBytes),
            color: Color.secondary.opacity(0.45)
        )
    }

}

private struct SystemDiskPage: View {
    let snapshot: SystemMonitorSnapshot
    let readHistory: [SystemHistorySample]
    let writeHistory: [SystemHistorySample]

    var body: some View {
        SystemMonitorPage(
            title: "Disk",
            subtitle: "\(snapshot.identity.disk.volumeName) · \(snapshot.identity.disk.fileSystem)"
        ) {
            SystemPanel {
                HStack(spacing: 24) {
                    SystemUsageGauge(
                        value: snapshot.disk.usage,
                        tint: diskUsageColor,
                        label: "Disk usage"
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.identity.disk.volumeName)
                                    .font(.headline)
                                Text(snapshot.identity.disk.fileSystem)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                snapshot.disk.totalBytes
                                    .map(SystemMonitorFormat.bytes) ?? "Unavailable"
                            )
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: snapshot.disk.usage ?? 0)
                            .tint(diskUsageColor)
                            .accessibilityLabel("Disk usage")
                            .accessibilityValue(
                                SystemMonitorFormat.optionalPercent(snapshot.disk.usage)
                            )

                        HStack(spacing: 20) {
                            SystemLegendItem(
                                title: "Used",
                                value: snapshot.disk.usedBytes
                                    .map(SystemMonitorFormat.bytes) ?? "Unavailable",
                                color: diskUsageColor
                            )
                            SystemLegendItem(
                                title: "Available",
                                value: snapshot.disk.availableBytes
                                    .map(SystemMonitorFormat.bytes) ?? "Unavailable",
                                color: Color.secondary.opacity(0.45)
                            )
                        }
                    }
                }
            }

            SystemDiskHistoryChart(
                readSamples: readHistory,
                writeSamples: writeHistory,
                currentRead: snapshot.disk.readBytesPerSecond,
                currentWrite: snapshot.disk.writeBytesPerSecond
            )

            adaptivePair {
                SystemInfoCard(title: "Details") {
                    SystemInfoRow(
                        "Read",
                        value: SystemMonitorFormat.byteRate(snapshot.disk.readBytesPerSecond),
                        color: SystemMonitorPalette.blue
                    )
                    SystemInfoRow(
                        "Write",
                        value: SystemMonitorFormat.byteRate(snapshot.disk.writeBytesPerSecond),
                        color: SystemMonitorPalette.red
                    )
                    SystemInfoRow(
                        "Total read since boot",
                        value: SystemMonitorFormat.bytes(snapshot.disk.cumulativeReadBytes)
                    )
                    SystemInfoRow(
                        "Total written since boot",
                        value: SystemMonitorFormat.bytes(snapshot.disk.cumulativeWriteBytes)
                    )
                    SystemInfoRow(
                        "Model",
                        value: snapshot.identity.disk.model
                    )
                    SystemInfoRow(
                        "Connection type",
                        value: snapshot.identity.disk.connection
                    )
                    SystemInfoRow(
                        "BSD name",
                        value: snapshot.identity.disk.deviceIdentifier
                    )
                    SystemInfoRow(
                        "Encrypted",
                        value: SystemMonitorFormat.boolean(snapshot.identity.disk.isEncrypted)
                    )
                    SystemInfoRow(
                        "Writable",
                        value: SystemMonitorFormat.boolean(snapshot.identity.disk.isWritable)
                    )
                }
            } trailing: {
                SystemInfoCard(title: "SMART") {
                    SystemInfoRow(
                        "Status",
                        value: snapshot.identity.disk.smartStatus ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Total read",
                        value: snapshot.identity.disk.lifetimeReadBytes
                            .map(SystemMonitorFormat.bytes) ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Total written",
                        value: snapshot.identity.disk.lifetimeWrittenBytes
                            .map(SystemMonitorFormat.bytes) ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Temperature",
                        value: snapshot.identity.disk.temperatureCelsius
                            .map { "\($0)°C" } ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Health",
                        value: snapshot.identity.disk.healthPercent
                            .map { "\($0)%" } ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Power cycles",
                        value: snapshot.identity.disk.powerCycles
                            .map(SystemMonitorFormat.integer) ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Power on hours",
                        value: snapshot.identity.disk.powerOnHours
                            .map(SystemMonitorFormat.integer) ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Available spare",
                        value: snapshot.identity.disk.availableSparePercent
                            .map { "\($0)%" } ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Unsafe shutdowns",
                        value: snapshot.identity.disk.unsafeShutdowns
                            .map(SystemMonitorFormat.integer) ?? "Unavailable"
                    )
                    SystemInfoRow(
                        "Media errors",
                        value: snapshot.identity.disk.mediaErrors
                            .map(SystemMonitorFormat.integer) ?? "Unavailable"
                    )
                }
            }
        }
    }

    private var diskUsageColor: Color {
        guard let usage = snapshot.disk.usage else { return .secondary }
        return usage >= 0.90 ? SystemMonitorPalette.red : SystemMonitorPalette.blue
    }
}

private struct SystemMonitorPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct SystemPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .systemMonitorPanel()
    }
}

private struct SystemOverviewMetric: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SystemMonitorPalette.metricLabel)
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SystemMonitorPalette.metricDetail)
                    .lineLimit(1)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemMonitorPanel()
    }
}

private struct SystemInfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .systemMonitorPanel()
    }
}

private struct SystemInfoRow: View {
    let title: String
    let value: String
    let color: Color?

    init(_ title: String, value: String, color: Color? = nil) {
        self.title = title
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 8, height: 8)
            }

            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SystemUsageGauge: View {
    let value: Double?
    let tint: Color
    let label: String

    var body: some View {
        Gauge(value: value ?? 0) {
            Text(label)
        } currentValueLabel: {
            Text(SystemMonitorFormat.optionalPercent(value))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
        .frame(width: 86, height: 86)
    }
}

private struct SystemMemoryPressureRing: View {
    let memory: SystemMemoryMetrics

    var body: some View {
        Gauge(value: memory.usage) {
            EmptyView()
        } currentValueLabel: {
            Text(SystemMonitorFormat.percent(memory.usage))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(pressureColor)
        .frame(width: 78, height: 78)
        .frame(width: 90)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Memory pressure \(memory.pressureLabel), \(SystemMonitorFormat.percent(memory.usage)) used"
        )
    }

    private var pressureColor: Color {
        switch memory.pressureLabel {
        case "Normal":
            SystemMonitorPalette.blue
        case "Elevated":
            SystemMonitorPalette.orange
        default:
            SystemMonitorPalette.red
        }
    }
}

private struct SystemLegendItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct SystemLabeledProgress: View {
    let title: String
    let value: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(SystemMonitorFormat.optionalPercent(value))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: value ?? 0)
                .tint(tint)
        }
    }
}

private struct SystemCoreLoadRow: View {
    let title: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(SystemMonitorFormat.percent(value))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: value)
                .tint(tint)
        }
    }
}

private struct SystemPercentHistoryChart: View {
    let title: String
    let samples: [SystemHistorySample]
    let color: Color
    var footer: String?
    @State private var hoveredSample: SystemHistorySample?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let footer {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if samples.isEmpty {
                SystemChartPlaceholder()
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("Time", sample.recordedAt),
                            y: .value("Usage", sample.value * 100)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.42), color.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", sample.recordedAt),
                            y: .value("Usage", sample.value * 100)
                        )
                        .foregroundStyle(color)
                        .lineStyle(.init(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }

                    if let hoveredSample {
                        RuleMark(
                            x: .value("Hovered time", hoveredSample.recordedAt)
                        )
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        .annotation(
                            position: .top,
                            alignment: .center,
                            overflowResolution: .init(
                                x: .fit(to: .chart),
                                y: .disabled
                            )
                        ) {
                            SystemChartHoverTooltip(
                                recordedAt: hoveredSample.recordedAt,
                                rows: [
                                    SystemChartHoverRow(
                                        title: title.replacingOccurrences(
                                            of: " history",
                                            with: ""
                                        ),
                                        value: SystemMonitorFormat.percent(
                                            hoveredSample.value
                                        ),
                                        color: color
                                    ),
                                ]
                            )
                        }

                        PointMark(
                            x: .value("Hovered time", hoveredSample.recordedAt),
                            y: .value("Hovered usage", hoveredSample.value * 100)
                        )
                        .foregroundStyle(color)
                        .symbolSize(38)
                    }
                }
                .chartXScale(
                    domain: systemChartTimeDomain(for: [samples]),
                    range: .plotDimension(startPadding: 0, endPadding: 0)
                )
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let percent = value.as(Int.self) {
                                Text("\(percent)%")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartOverlay { proxy in
                    SystemChartHoverOverlay(
                        proxy: proxy,
                        dataRevision: samples.last?.recordedAt
                    ) { date in
                        let nextSample = date.flatMap(samples.nearest(to:))
                        if hoveredSample != nextSample {
                            hoveredSample = nextSample
                        }
                    }
                }
                .frame(minHeight: 170)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemMonitorPanel()
    }
}

private struct SystemDiskHistoryChart: View {
    let readSamples: [SystemHistorySample]
    let writeSamples: [SystemHistorySample]
    let currentRead: Double
    let currentWrite: Double
    @State private var hoveredDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Read / Write history")
                    .font(.headline)
                Spacer()
                SystemLegendItem(
                    title: "Read",
                    value: SystemMonitorFormat.byteRate(currentRead),
                    color: SystemMonitorPalette.blue
                )
                SystemLegendItem(
                    title: "Write",
                    value: SystemMonitorFormat.byteRate(currentWrite),
                    color: SystemMonitorPalette.red
                )
            }

            if readSamples.isEmpty && writeSamples.isEmpty {
                SystemChartPlaceholder()
            } else {
                Chart {
                    ForEach(readSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.recordedAt),
                            y: .value("Bytes per second", sample.value),
                            series: .value("Series", "Read")
                        )
                        .foregroundStyle(SystemMonitorPalette.blue)
                        .interpolationMethod(.catmullRom)
                    }
                    ForEach(writeSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.recordedAt),
                            y: .value("Bytes per second", sample.value),
                            series: .value("Series", "Write")
                        )
                        .foregroundStyle(SystemMonitorPalette.red)
                        .interpolationMethod(.catmullRom)
                    }

                    if let hoveredDate {
                        RuleMark(x: .value("Hovered time", hoveredDate))
                            .foregroundStyle(Color.secondary.opacity(0.45))
                            .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                            .annotation(
                                position: .top,
                                alignment: .center,
                                overflowResolution: .init(
                                    x: .fit(to: .chart),
                                    y: .disabled
                                )
                            ) {
                                SystemChartHoverTooltip(
                                    recordedAt: hoveredDate,
                                    rows: diskHoverRows(at: hoveredDate)
                                )
                            }

                        if let hoveredRead = readSamples.nearest(to: hoveredDate) {
                            PointMark(
                                x: .value("Read time", hoveredRead.recordedAt),
                                y: .value("Read rate", hoveredRead.value)
                            )
                            .foregroundStyle(SystemMonitorPalette.blue)
                            .symbolSize(38)
                        }

                        if let hoveredWrite = writeSamples.nearest(to: hoveredDate) {
                            PointMark(
                                x: .value("Write time", hoveredWrite.recordedAt),
                                y: .value("Write rate", hoveredWrite.value)
                            )
                            .foregroundStyle(SystemMonitorPalette.red)
                            .symbolSize(38)
                        }
                    }
                }
                .chartXScale(
                    domain: systemChartTimeDomain(
                        for: [readSamples, writeSamples]
                    ),
                    range: .plotDimension(startPadding: 0, endPadding: 0)
                )
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(SystemMonitorFormat.byteRate(bytes))
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartOverlay { proxy in
                    SystemChartHoverOverlay(
                        proxy: proxy,
                        dataRevision: latestSampleDate
                    ) { date in
                        if hoveredDate != date {
                            hoveredDate = date
                        }
                    }
                }
                .frame(minHeight: 190)
            }
        }
        .padding(16)
        .systemMonitorPanel()
    }

    private func diskHoverRows(at date: Date) -> [SystemChartHoverRow] {
        var rows: [SystemChartHoverRow] = []
        if let read = readSamples.nearest(to: date) {
            rows.append(
                SystemChartHoverRow(
                    title: "Read",
                    value: SystemMonitorFormat.byteRate(read.value),
                    color: SystemMonitorPalette.blue
                )
            )
        }
        if let write = writeSamples.nearest(to: date) {
            rows.append(
                SystemChartHoverRow(
                    title: "Write",
                    value: SystemMonitorFormat.byteRate(write.value),
                    color: SystemMonitorPalette.red
                )
            )
        }
        return rows
    }

    private var latestSampleDate: Date? {
        [
            readSamples.last?.recordedAt,
            writeSamples.last?.recordedAt,
        ]
        .compactMap { $0 }
        .max()
    }
}

private struct SystemFPSHistoryChart: View {
    let samples: [SystemHistorySample]

    var body: some View {
        SystemValueHistoryChart(
            title: "FPS history",
            samples: samples,
            color: SystemMonitorPalette.blue,
            seriesName: "Frame rate",
            format: { SystemMonitorFormat.framesPerSecond($0) },
            axisStep: 30,
            axisMinimum: 30
        )
    }
}

/// History chart for a quantity measured in its own units rather than as a percentage.
/// Shared by frame rate, temperature, and power.
private struct SystemValueHistoryChart: View {
    let title: String
    let samples: [SystemHistorySample]
    let color: Color
    /// Row label shown in the hover tooltip.
    let seriesName: String
    let format: (Double) -> String
    /// The y-axis snaps to multiples of this, so the plot does not rescale on every sample.
    let axisStep: Double
    /// Smallest upper bound, so a quiet chart does not zoom into noise.
    let axisMinimum: Double
    /// Whether zero is a meaningful floor for this quantity.
    ///
    /// Frame rate and watts genuinely start at zero, and anchoring there makes their
    /// magnitude readable. Temperature does not — a die never approaches 0 °C, so a
    /// zero-anchored axis squeezes the entire useful range into the top of the plot and
    /// renders real drift as a flat line, which is precisely the signal this chart exists
    /// to show. Those series anchor just below the observed minimum instead.
    var anchorsAtZero = true
    @State private var hoveredSample: SystemHistorySample?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let current = samples.last?.value {
                    Text(format(current))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if samples.isEmpty {
                SystemChartPlaceholder()
            } else {
                Chart {
                    ForEach(samples) { sample in
                        // Filled from the axis floor rather than the default of zero. On a
                        // series that does not anchor at zero the baseline sits outside
                        // the domain, and the area is then drawn past the bottom of the
                        // plot and bleeds over whatever follows the chart.
                        AreaMark(
                            x: .value("Time", sample.recordedAt),
                            yStart: .value("Baseline", axisRange.lowerBound),
                            yEnd: .value(seriesName, sample.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.44),
                                    color.opacity(0.06),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", sample.recordedAt),
                            y: .value(seriesName, sample.value)
                        )
                        .foregroundStyle(color)
                        .lineStyle(.init(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }

                    if let hoveredSample {
                        RuleMark(
                            x: .value("Hovered time", hoveredSample.recordedAt)
                        )
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        .annotation(
                            position: .top,
                            alignment: .center,
                            overflowResolution: .init(
                                x: .fit(to: .chart),
                                y: .disabled
                            )
                        ) {
                            SystemChartHoverTooltip(
                                recordedAt: hoveredSample.recordedAt,
                                rows: [
                                    SystemChartHoverRow(
                                        title: seriesName,
                                        value: format(hoveredSample.value),
                                        color: color
                                    ),
                                ]
                            )
                        }

                        PointMark(
                            x: .value("Hovered time", hoveredSample.recordedAt),
                            y: .value("Hovered \(seriesName)", hoveredSample.value)
                        )
                        .foregroundStyle(color)
                        .symbolSize(38)
                    }
                }
                .chartXScale(
                    domain: systemChartTimeDomain(for: [samples]),
                    range: .plotDimension(startPadding: 0, endPadding: 0)
                )
                .chartYScale(domain: axisRange)
                // Deliberately not clipping the plot area: the hover tooltip is an
                // annotation anchored above the rule mark and is chart content too, so
                // clipping truncates it. Bounding the area fill between the axis floor
                // and the value is what actually keeps the fill inside the plot.
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(format(number))
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartOverlay { proxy in
                    SystemChartHoverOverlay(
                        proxy: proxy,
                        dataRevision: samples.last?.recordedAt
                    ) { date in
                        let nextSample = date.flatMap(samples.nearest(to:))
                        if hoveredSample != nextSample {
                            hoveredSample = nextSample
                        }
                    }
                }
                .frame(minHeight: 190)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemMonitorPanel()
    }

    private var axisRange: ClosedRange<Double> {
        let values = samples.map(\.value)
        let upper = max(axisMinimum, ceil((values.max() ?? 0) / axisStep) * axisStep)
        guard !anchorsAtZero else { return 0...upper }

        let lower = max(0, floor((values.min() ?? 0) / axisStep) * axisStep)
        // A run flat enough to land inside one step would otherwise produce an empty
        // domain, so always keep at least one step of height.
        return lower < upper ? lower...upper : lower...(lower + axisStep)
    }
}

private struct SystemChartHoverOverlay: View {
    let proxy: ChartProxy
    let dataRevision: Date?
    let onDateChange: (Date?) -> Void
    @State private var pointerLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        pointerLocation = location
                        onDateChange(date(at: location, in: geometry))
                    case .ended:
                        pointerLocation = nil
                        onDateChange(nil)
                    }
                }
                .onChange(of: dataRevision) { _, _ in
                    guard let pointerLocation else { return }
                    onDateChange(date(at: pointerLocation, in: geometry))
                }
        }
    }

    private func date(at location: CGPoint, in geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else {
            return nil
        }
        let plotRect = geometry[plotFrame]
        guard plotRect.contains(location) else {
            return nil
        }
        let xPosition = location.x - plotRect.minX
        return proxy.value(atX: xPosition)
    }
}

private func systemChartTimeDomain(
    for sampleGroups: [[SystemHistorySample]]
) -> ClosedRange<Date> {
    let boundaryDates = sampleGroups.flatMap { samples in
        [
            samples.first?.recordedAt,
            samples.last?.recordedAt,
        ]
        .compactMap { $0 }
    }

    guard
        let firstDate = boundaryDates.min(),
        let lastDate = boundaryDates.max()
    else {
        let now = Date()
        return now.addingTimeInterval(-1)...now
    }

    guard firstDate < lastDate else {
        let paddedStart = firstDate.addingTimeInterval(-0.5)
        let paddedEnd = lastDate.addingTimeInterval(0.5)
        return paddedStart...paddedEnd
    }
    return firstDate...lastDate
}

private struct SystemChartHoverRow: Identifiable {
    let title: String
    let value: String
    let color: Color

    var id: String { title }
}

private struct SystemChartHoverTooltip: View {
    let recordedAt: Date
    let rows: [SystemChartHoverRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recordedAt, format: .dateTime.hour().minute().second())
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 6, height: 6)
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(row.value)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 128)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
        }
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
    }
}

private extension Array where Element == SystemHistorySample {
    func nearest(to date: Date) -> SystemHistorySample? {
        guard !isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if self[middle].recordedAt < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound == 0 {
            return self[0]
        }
        if lowerBound == count {
            return self[count - 1]
        }

        let previous = self[lowerBound - 1]
        let next = self[lowerBound]
        let previousDistance = abs(previous.recordedAt.timeIntervalSince(date))
        let nextDistance = abs(next.recordedAt.timeIntervalSince(date))
        return previousDistance <= nextDistance ? previous : next
    }
}

private struct SystemChartPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Collecting live samples…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}

@ViewBuilder
private func adaptivePair<Leading: View, Trailing: View>(
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 14) {
            leading()
                .frame(maxWidth: .infinity)
            trailing()
                .frame(maxWidth: .infinity)
        }
        VStack(alignment: .leading, spacing: 14) {
            leading()
            trailing()
        }
    }
}

private enum SystemMonitorFormat {
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func optionalPercent(_ value: Double?) -> String {
        value.map(percent) ?? "--"
    }

    static func framesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return "\(Int(value.rounded())) FPS"
    }

    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.1f°C", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return value < 10
            ? String(format: "%.2f W", value)
            : String(format: "%.1f W", value)
    }

    static func rpm(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value) RPM"
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .file
        )
    }

    static func memoryBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .memory
        )
    }

    static func byteRate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--" }
        return "\(bytes(UInt64(value.rounded()))) /s"
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let totalHours = max(Int(interval / 3_600), 0)
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 {
            return "\(days) days, \(hours) hours"
        }
        return "\(hours) hours"
    }

    static func frequency(_ hertz: UInt64) -> String {
        let gigahertz = Double(hertz) / 1_000_000_000
        return String(format: "%.2f GHz", gigahertz)
    }

    static func boolean(_ value: Bool?) -> String {
        guard let value else { return "Unavailable" }
        return value ? "Yes" : "No"
    }

    static func integer(_ value: UInt64) -> String {
        value.formatted()
    }
}

private struct MenuBarCustomizationMenuControl: NSViewRepresentable {
    @ObservedObject var preferences: SystemMenuBarPreferences

    func makeCoordinator() -> Coordinator {
        Coordinator(preferences: preferences)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = nil
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityLabel("Customize Menu Bar")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.preferences = preferences
        context.coordinator.refreshSelection()
    }

    @MainActor
    final class Coordinator: NSObject {
        var preferences: SystemMenuBarPreferences

        private static let menuFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        private var optionViews = [PersistentMenuActionView]()

        init(preferences: SystemMenuBarPreferences) {
            self.preferences = preferences
        }

        @objc func showMenu(_ sender: NSButton) {
            optionViews.removeAll()
            let menu = makeMenu()
            menu.update()
            menu.popUp(
                positioning: nil,
                at: NSPoint(
                    x: -8,
                    y: sender.isFlipped
                        ? sender.bounds.minY - menu.size.height - 4
                        : sender.bounds.maxY + menu.size.height + 4
                ),
                in: sender
            )
        }

        func refreshSelection() {
            for optionView in optionViews {
                if optionView.optionID == SystemMenuBarMetric.nativ.rawValue {
                    optionView.isSelected = preferences.items.isEmpty
                    continue
                }
                guard let item = SystemMenuBarItem(id: optionView.optionID) else {
                    continue
                }
                optionView.isSelected = preferences.contains(
                    metric: item.metric,
                    style: item.style
                )
            }
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(.sectionHeader(title: "Menu bar"))
            menu.addItem(menuItem(
                title: "Nativ icon",
                systemImage: SystemMenuBarMetric.nativ.systemImage,
                optionID: SystemMenuBarMetric.nativ.rawValue,
                isSelected: preferences.items.isEmpty
            ) { [weak self] in
                self?.preferences.useNativIcon()
                self?.refreshSelection()
            })

            for metric in SystemMenuBarMetric.allCases where metric != .nativ {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: metric.title))

                for style in metric.menuBarStyles {
                    let item = SystemMenuBarItem(metric: metric, style: style)
                    menu.addItem(menuItem(
                        title: style.title,
                        systemImage: style.systemImage,
                        optionID: item.id,
                        isSelected: preferences.contains(metric: metric, style: style)
                    ) { [weak self] in
                        guard let self else { return }
                        let isSelected = self.preferences.contains(
                            metric: metric,
                            style: style
                        )
                        self.preferences.setEnabled(
                            !isSelected,
                            metric: metric,
                            style: style
                        )
                        self.refreshSelection()
                    })
                }
            }

            return menu
        }

        private func menuItem(
            title: String,
            systemImage: String,
            optionID: String,
            isSelected: Bool,
            onSelect: @escaping () -> Void
        ) -> NSMenuItem {
            let configuration = NSImage.SymbolConfiguration(
                pointSize: NSFont.systemFontSize,
                weight: .regular
            )
            let image = NSImage(
                systemSymbolName: systemImage,
                accessibilityDescription: title
            )?.withSymbolConfiguration(configuration)
            let attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: Self.menuFont]
            )
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let itemView = PersistentMenuActionView(
                optionID: optionID,
                title: attributedTitle,
                image: image,
                isSelected: isSelected,
                onSelect: onSelect
            )
            item.view = itemView
            item.isEnabled = true
            optionViews.append(itemView)
            return item
        }
    }
}

private enum SystemMonitorPalette {
    static let blue = Color(red: 0.10, green: 0.48, blue: 0.96)
    static let purple = Color(red: 0.38, green: 0.32, blue: 0.95)
    static let teal = Color(red: 0.03, green: 0.71, blue: 0.75)
    static let orange = Color(red: 1.00, green: 0.55, blue: 0.17)
    static let red = Color(red: 1.00, green: 0.23, blue: 0.28)
    static let positive = Color(red: 0.18, green: 0.72, blue: 0.38)
    static let metricLabel = Color.primary.opacity(0.72)
    static let metricDetail = Color.primary.opacity(0.58)
}

private struct SystemMonitorPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

private extension View {
    func systemMonitorPanel() -> some View {
        modifier(SystemMonitorPanelModifier())
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
