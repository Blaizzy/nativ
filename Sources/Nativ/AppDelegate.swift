import AppKit
import NativServerKit
import SwiftUI

@MainActor
private final class ModelMenuIconView: NSView {
    private let imageView = NSImageView()
    private let monogramLabel = NSTextField(labelWithString: "")
    private let provider: LocalModelProvider?
    private let isSelected: Bool

    init(provider: LocalModelProvider?, isSelected: Bool) {
        self.provider = provider
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14

        if let provider,
           let providerImage = LocalModelProviderIcon.image(for: provider) {
            imageView.image = providerImage
            imageView.setAccessibilityLabel(provider.displayName)
            toolTip = provider.displayName
        } else if let provider {
            monogramLabel.stringValue = provider.monogram
            monogramLabel.font = .systemFont(
                ofSize: provider.monogram.count > 2 ? 7 : 9,
                weight: .bold
            )
            monogramLabel.alignment = .center
            monogramLabel.setAccessibilityLabel(provider.displayName)
            toolTip = provider.displayName
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            imageView.image = NSImage(
                systemSymbolName: "cube.transparent.fill",
                accessibilityDescription: "Unknown model provider"
            )?.withSymbolConfiguration(configuration)
        }
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        monogramLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(monogramLabel)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            monogramLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            monogramLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            monogramLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 22)
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if provider?.needsLightIconBackgroundInDarkMode == true, isDarkMode {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        } else {
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.controlBackgroundColor.cgColor
        }
        let providerColor = provider?.iconTintColor ?? .secondaryLabelColor
        imageView.contentTintColor = isSelected ? .white : providerColor
        monogramLabel.textColor = isSelected ? .white : providerColor
    }
}

@MainActor
private final class ModelMenuRowView: NSView {
    private let onSelect: () -> Void
    private let isSelected: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    init(
        name: String,
        details: String,
        tooltip: String,
        provider: LocalModelProvider?,
        capabilities: Set<LocalModelCapability>,
        memoryEstimate: LocalModelMemoryEstimate?,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.isSelected = isSelected
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 44))

        let iconView = ModelMenuIconView(provider: provider, isSelected: isSelected)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.addArrangedSubview(nameLabel)

        for capability in LocalModelCapability.allCases where capabilities.contains(capability) {
            let capabilityImage = NSImageView()
            let symbolName: String
            let description: String
            switch capability {
            case .text:
                continue
            case .vision:
                symbolName = "eye.fill"
                description = capability.displayName
            case .audio:
                symbolName = "waveform"
                description = capability.displayName
            case .video:
                symbolName = "film.fill"
                description = capability.displayName
            case .imageGeneration:
                symbolName = "photo.badge.plus"
                description = capability.displayName
            case .speechToText:
                symbolName = "captions.bubble.fill"
                description = capability.displayName
            case .textToSpeech:
                symbolName = "speaker.wave.2.fill"
                description = capability.displayName
            case .embeddings:
                symbolName = "circle.grid.3x3.fill"
                description = capability.displayName
            case .reasoning:
                symbolName = "brain.fill"
                description = capability.displayName
            case .tools:
                symbolName = "hammer.fill"
                description = capability.displayName
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            capabilityImage.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: description
            )?.withSymbolConfiguration(configuration)
            capabilityImage.contentTintColor = .secondaryLabelColor
            capabilityImage.imageScaling = .scaleProportionallyDown
            capabilityImage.toolTip = description
            capabilityImage.setContentCompressionResistancePriority(.required, for: .horizontal)
            capabilityImage.widthAnchor.constraint(equalToConstant: 13).isActive = true
            capabilityImage.heightAnchor.constraint(equalToConstant: 13).isActive = true
            titleRow.addArrangedSubview(capabilityImage)
        }

        if let memoryEstimate, !memoryEstimate.isUsable {
            let compatibilityLabel = NSTextField(
                labelWithString: memoryEstimate.compatibilityLabel
            )
            compatibilityLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            compatibilityLabel.textColor = .systemOrange
            compatibilityLabel.lineBreakMode = .byClipping
            compatibilityLabel.toolTip = memoryEstimate.explanation
            compatibilityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            compatibilityLabel.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(compatibilityLabel)
        }

        let detailsLabel = NSTextField(labelWithString: details)
        detailsLabel.font = .systemFont(ofSize: 10)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleRow, detailsLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.translatesAutoresizingMaskIntoConstraints = false

        let selectedImage = NSImageView()
        selectedImage.image = isSelected
            ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Loaded")
            : nil
        selectedImage.contentTintColor = .controlAccentColor
        selectedImage.imageScaling = .scaleProportionallyDown
        selectedImage.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(selectedImage)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: selectedImage.leadingAnchor, constant: -6),

            selectedImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            selectedImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectedImage.widthAnchor.constraint(equalToConstant: 14),
            selectedImage.heightAnchor.constraint(equalToConstant: 14)
        ])

        self.toolTip = tooltip
        setAccessibilityRole(.button)
        let capabilityDescription = capabilities
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
        let accessibilitySuffix = capabilityDescription.isEmpty ? "" : ", \(capabilityDescription)"
        let providerDescription = provider.map { ", \($0.displayName)" } ?? ""
        setAccessibilityLabel("\(name)\(providerDescription), \(details)\(accessibilitySuffix)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rowRect = bounds.insetBy(dx: 5, dy: 1)
        if isSelected {
            NSColor.controlAccentColor
                .withAlphaComponent(isHovered ? 0.18 : 0.10)
                .setFill()
            NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6).fill()

            NSColor.controlAccentColor.setFill()
            let indicatorRect = NSRect(
                x: rowRect.minX,
                y: rowRect.minY + 8,
                width: 3,
                height: rowRect.height - 16
            )
            NSBezierPath(roundedRect: indicatorRect, xRadius: 1.5, yRadius: 1.5).fill()
        } else if isHovered {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onSelect()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
private final class ModelMenuSectionHeaderView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 24))

        let title = NSMutableAttributedString(
            string: "Installed ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        title.append(NSAttributedString(
            string: "models",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor
            ]
        ))

        let label = NSTextField(labelWithAttributedString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = NativModel()
    private let controlPanelNavigation = ControlPanelNavigation()
    private let runtime = SystemRuntimeMonitor()
    private var mainWindowOpener: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var serverActionMenuItem: NSMenuItem?
    private var modelMenuItem: NSMenuItem?
    private var localModels: [LocalModel] = []
    private var modelScanTask: Task<Void, Never>?
    private var modelScanInProgress = false
    private var modelScanError: String?
    private var lastScannedModelPath: String?
    private weak var highlightedMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyApplicationIcon()
        runtime.start()
        model.onMenuStateChanged = { [weak self] in
            guard let self else {
                return
            }
            if self.model.menuIsOpen {
                self.refreshVisibleMenuState()
            } else {
                self.rebuildMenu()
            }
        }

        configureStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localModelLibraryDidChange(_:)),
            name: .localModelLibraryDidChange,
            object: nil
        )
        refreshLocalModels()
        if WelcomePreferences.hasCompleted {
            model.startServer()
        }
    }

    private func applyApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelScanTask?.cancel()
        runtime.stop()
        model.applicationWillTerminate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.menuIsOpen = true
        rebuildMenu()
        if model.metricsAreStale {
            model.refreshMetricsIfRunning(force: true)
        }
        refreshLocalModelsIfNeeded()
    }

    func menuDidClose(_ menu: NSMenu) {
        (highlightedMenuItem?.view as? SessionStatsHighlighting)?.setHighlighted(false)
        highlightedMenuItem = nil
        model.menuIsOpen = false
        rebuildMenu()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard highlightedMenuItem !== item else {
            return
        }
        (highlightedMenuItem?.view as? SessionStatsHighlighting)?.setHighlighted(false)
        highlightedMenuItem = item
        (item?.view as? SessionStatsHighlighting)?.setHighlighted(true)
    }

    @objc private func toggleServerFromMenu(_ sender: Any?) {
        model.toggleServer()
    }

    @objc private func switchModelFromMenu(_ sender: NSMenuItem) {
        let rawModelID = sender.representedObject as? String
        model.switchLanguageModel(to: rawModelID?.isEmpty == false ? rawModelID : nil)
    }

    @objc private func refreshModelsFromMenu(_ sender: Any?) {
        refreshLocalModels()
    }

    @objc private func openDashboardFromMenu(_ sender: Any?) {
        controlPanelNavigation.open(.dashboard)
        showMainWindow()
    }

    @objc private func openModelsFromMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func openWelcomeFromMenu(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func localModelLibraryDidChange(_ notification: Notification) {
        refreshLocalModels()
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    var rootView: some View {
        WelcomeGateView(
            model: model,
            navigation: controlPanelNavigation,
            runtime: runtime,
            onComplete: { [weak self] modelID, serverAPIKey in
                self?.completeWelcome(modelID: modelID, serverAPIKey: serverAPIKey)
            }
        )
    }

    func registerMainWindowOpener(_ opener: @escaping () -> Void) {
        mainWindowOpener = opener
    }

    func openSettings() {
        controlPanelNavigation.open(.models)
        showMainWindow()
    }

    func createNewChat() {
        controlPanelNavigation.createChat()
        showMainWindow()
    }

    private func showMainWindow() {
        mainWindowOpener?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func completeWelcome(modelID: String?, serverAPIKey: String?) {
        var settings = model.settings
        settings.languageModelID = modelID
        settings.serverAPIKey = serverAPIKey
        model.settings = settings.normalized()
        WelcomePreferences.markCompleted()

        if !model.isRunning {
            model.startServer()
        }
        rebuildMenu()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarLogo") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.title = "Nativ"
            }
            button.toolTip = "Nativ Server"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        self.statusItem = statusItem
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else {
            return
        }

        let menu = statusItem.menu ?? NSMenu()
        menu.delegate = self
        menu.removeAllItems()

        guard WelcomePreferences.hasCompleted else {
            let setupItem = NSMenuItem(
                title: "Finish Setup…",
                action: #selector(openWelcomeFromMenu(_:)),
                keyEquivalent: ""
            )
            setupItem.target = self
            setupItem.image = menuIcon("sparkles", description: "Finish setup")
            menu.addItem(setupItem)
            menu.addItem(.separator())

            let quitMenuItem = NSMenuItem(
                title: "Quit",
                action: #selector(quit(_:)),
                keyEquivalent: "q"
            )
            quitMenuItem.target = self
            quitMenuItem.image = menuIcon("xmark.rectangle", description: "Quit")
            menu.addItem(quitMenuItem)

            statusItem.menu = menu
            serverActionMenuItem = nil
            modelMenuItem = nil
            return
        }

        let sessionStatsAreLoading = model.metricsLoading || model.modelSwitchInProgress
        if model.sessionStatsDisplayMetrics != nil || model.isRunning || sessionStatsAreLoading {
            for item in makeSessionStatsMenuItems() {
                menu.addItem(item)
            }
        } else {
            let statusMenuItem = NSMenuItem(
                title: model.isRunning ? model.unavailableMetricsText : "Nativ Server is Not Running",
                action: nil,
                keyEquivalent: ""
            )
            statusMenuItem.isEnabled = false
            menu.addItem(statusMenuItem)
        }

        menu.addItem(.separator())
        let modelMenuItem = makeModelMenuItem()
        menu.addItem(modelMenuItem)
        menu.addItem(.separator())

        let serverActionMenuItem = NSMenuItem(
            title: model.isRunning ? "Stop Server" : "Start Server",
            action: #selector(toggleServerFromMenu(_:)),
            keyEquivalent: "s"
        )
        serverActionMenuItem.target = self
        serverActionMenuItem.image = menuIcon(
            model.isRunning ? "stop.circle" : "play.circle",
            description: model.isRunning ? "Stop server" : "Start server"
        )
        menu.addItem(serverActionMenuItem)

        menu.addItem(.separator())

        let dashboardMenuItem = NSMenuItem(
            title: "Dashboard…",
            action: #selector(openDashboardFromMenu(_:)),
            keyEquivalent: ""
        )
        dashboardMenuItem.target = self
        dashboardMenuItem.image = menuIcon("chart.xyaxis.line", description: "Dashboard")
        menu.addItem(dashboardMenuItem)

        let modelsMenuItem = NSMenuItem(
            title: "Models…",
            action: #selector(openModelsFromMenu(_:)),
            keyEquivalent: ","
        )
        modelsMenuItem.target = self
        modelsMenuItem.keyEquivalentModifierMask = [.command]
        modelsMenuItem.image = menuIcon("cube.transparent", description: "Models")
        menu.addItem(modelsMenuItem)

        let quitMenuItem = NSMenuItem(
            title: "Quit", 
            action: #selector(quit(_:)), 
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        quitMenuItem.image = menuIcon("xmark.rectangle", description: "Quit")
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        self.serverActionMenuItem = serverActionMenuItem
        self.modelMenuItem = modelMenuItem
    }

    private func makeSessionStatsMenuItems() -> [NSMenuItem] {
        let headerItem = NSMenuItem(title: "Session Status", action: nil, keyEquivalent: "")
        let headerView = NSHostingView(rootView: SessionStatsContainerView(
            model: model,
            runtime: runtime,
            highlightState: SessionStatsHighlightState(),
            section: .header
        ))
        headerView.frame = NSRect(x: 0, y: 0, width: 350, height: SessionStatsSection.header.height)
        headerItem.view = headerView
        headerItem.isEnabled = false

        let bodyItem = NSMenuItem(title: "Session Stats", action: nil, keyEquivalent: "")
        let highlightState = SessionStatsHighlightState()
        let bodyView = SessionStatsHostingView(
            rootView: SessionStatsContainerView(
                model: model,
                runtime: runtime,
                highlightState: highlightState,
                section: .body
            ),
            highlightState: highlightState
        )
        bodyView.frame = NSRect(x: 0, y: 0, width: 350, height: SessionStatsSection.body.height)
        bodyItem.view = bodyView
        bodyItem.isEnabled = true
        bodyItem.submenu = makeServingStatsSubmenu()
        return [headerItem, bodyItem]
    }

    private func refreshVisibleMenuState() {
        modelMenuItem?.title = model.modelSwitchInProgress
            ? "Model: Loading…"
            : "Model: \(selectedModelMenuTitle)"
        modelMenuItem?.submenu = makeModelSubmenu()
        serverActionMenuItem?.title = model.isRunning ? "Stop Server" : "Start Server"
        serverActionMenuItem?.image = menuIcon(
            model.isRunning ? "stop.circle" : "play.circle",
            description: model.isRunning ? "Stop server" : "Start server"
        )
    }

    private func makeModelMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: model.modelSwitchInProgress ? "Model: Loading…" : "Model: \(selectedModelMenuTitle)",
            action: nil,
            keyEquivalent: ""
        )
        item.image = menuIcon("cube.transparent", description: "Model")
        item.submenu = makeModelSubmenu()
        return item
    }

    private func makeModelSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if model.modelSwitchInProgress {
            submenu.addItem(disabledMenuItem("Restarting server and loading model…"))
            return submenu
        }

        submenu.addItem(modelOptionMenuItem(title: "Load on demand", modelID: nil))

        let selectedModelID = model.settings.normalized().languageModelID
        let pickerModels = localModels.filter { localModel in
            localModel.repoID == selectedModelID
                || localModel.isEligibleForLanguageModelPicker
        }
        if let selectedModelID,
           !localModels.contains(where: { $0.repoID == selectedModelID }) {
            submenu.addItem(modelOptionMenuItem(
                title: missingModelMenuLabel(selectedModelID),
                modelID: selectedModelID
            ))
        }

        if !pickerModels.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(installedModelsHeaderMenuItem())
        }

        for localModel in pickerModels {
            submenu.addItem(modelRowMenuItem(localModel))
        }

        if pickerModels.isEmpty, selectedModelID == nil {
            let message = modelScanInProgress
                ? "Scanning for local models…"
                : modelScanError ?? (localModels.isEmpty
                    ? "No local models found"
                    : "No language models found")
            submenu.addItem(disabledMenuItem(message))
        }

        submenu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: modelScanInProgress ? "Refreshing Models…" : "Refresh Models",
            action: #selector(refreshModelsFromMenu(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.isEnabled = !modelScanInProgress
        submenu.addItem(refreshItem)

        return submenu
    }

    private func modelOptionMenuItem(
        title: String,
        modelID: String?
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(switchModelFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = modelID ?? ""
        item.state = model.settings.normalized().languageModelID == modelID ? .on : .off
        return item
    }

    private func installedModelsHeaderMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Installed models", action: nil, keyEquivalent: "")
        item.view = ModelMenuSectionHeaderView()
        return item
    }

    private func modelRowMenuItem(_ localModel: LocalModel) -> NSMenuItem {
        let item = NSMenuItem(title: localModel.repoID, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.view = ModelMenuRowView(
            name: modelDisplayName(localModel.repoID),
            details: modelDetails(localModel),
            tooltip: modelMenuTooltip(localModel),
            provider: localModel.provider,
            capabilities: localModel.capabilities,
            memoryEstimate: localModel.memoryEstimate(),
            isSelected: model.settings.normalized().languageModelID == localModel.repoID,
            onSelect: { [weak self] in
                self?.model.switchLanguageModel(to: localModel.repoID)
            }
        )
        return item
    }

    private var selectedModelMenuTitle: String {
        guard let modelID = model.settings.normalized().languageModelID else {
            return "On demand"
        }
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return NativFormatting.truncateModelName(shortName, maxLength: 28)
    }

    private func modelDisplayName(_ modelID: String) -> String {
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return NativFormatting.truncateModelName(shortName, maxLength: 34)
    }

    private func missingModelMenuLabel(_ modelID: String) -> String {
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return "\(NativFormatting.truncateModelName(shortName, maxLength: 34))  ·  Not found"
    }

    private func modelDetails(_ localModel: LocalModel) -> String {
        var details: [String] = []
        if let parameterSize = localModel.parameterSizeLabel {
            details.append(parameterSize)
        }
        if let quantization = localModel.quantizationLabel {
            details.append(quantization)
        }
        if let sizeBytes = localModel.sizeBytes {
            details.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        if let contextSize = localModel.contextSize {
            details.append("\(compactContextSize(contextSize)) ctx")
        }
        return details.isEmpty ? "Model details unavailable" : details.joined(separator: " · ")
    }

    private func modelMenuTooltip(_ localModel: LocalModel) -> String {
        var lines = [localModel.repoID]
        if let provider = localModel.provider {
            lines.append("Provider: \(provider.displayName)")
        }
        if let parameterSize = localModel.parameterSizeLabel {
            lines.append("Parameters: \(parameterSize)")
        }
        if let quantization = localModel.quantizationLabel {
            lines.append("Quantization: \(quantization)")
        }
        if let sizeBytes = localModel.sizeBytes {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))")
        }
        if let contextSize = localModel.contextSize {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: contextSize), number: .decimal)
            lines.append("Context: \(formatted) tokens")
        }
        if !localModel.capabilities.isEmpty {
            let capabilities = localModel.capabilities
                .map(\.displayName)
                .sorted()
                .joined(separator: ", ")
            lines.append("Capabilities: \(capabilities)")
        }
        if let memoryEstimate = localModel.memoryEstimate() {
            lines.append(memoryEstimate.compatibilityLabel)
            lines.append(memoryEstimate.explanation)
        }
        return lines.joined(separator: "\n")
    }

    private func compactContextSize(_ value: Int) -> String {
        let million = 1024 * 1024
        if value >= million, value.isMultiple(of: million) {
            return "\(value / million)M"
        }
        if value >= 1024, value.isMultiple(of: 1024) {
            return "\(value / 1024)K"
        }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func refreshLocalModelsIfNeeded() {
        let currentPath = model.settings.normalized().expandedModelSearchPath
        guard lastScannedModelPath != currentPath else {
            return
        }
        refreshLocalModels()
    }

    private func refreshLocalModels() {
        modelScanTask?.cancel()
        let searchPath = model.settings.normalized().expandedModelSearchPath
        modelScanInProgress = true
        modelScanError = nil
        rebuildModelSubmenu()

        modelScanTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let models = try await LocalModelDiscovery.scan(path: searchPath)
                guard !Task.isCancelled else {
                    return
                }
                self.localModels = models
                self.lastScannedModelPath = searchPath
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.localModels = []
                self.modelScanError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.lastScannedModelPath = searchPath
            }

            self.modelScanInProgress = false
            self.rebuildModelSubmenu()
        }
    }

    private func rebuildModelSubmenu() {
        guard let modelMenuItem else {
            return
        }
        modelMenuItem.title = model.modelSwitchInProgress
            ? "Model: Loading…"
            : "Model: \(selectedModelMenuTitle)"
        modelMenuItem.submenu = makeModelSubmenu()
    }

    private func makeServingStatsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard model.isRunning else {
            submenu.addItem(disabledMenuItem("Server is off"))
            return submenu
        }

        guard let metrics = model.metrics else {
            submenu.addItem(disabledMenuItem(model.unavailableMetricsText))
            return submenu
        }

        addSection("Session", entries: NativStats.sessionEntries(metrics), to: submenu)

        submenu.addItem(.separator())
        addSection("All-Time", entries: NativStats.allTimeEntries(model.allTimeStats), to: submenu)

        if let latest = metrics.latest {
            submenu.addItem(.separator())
            addSection("Latest Request", entries: NativStats.latestRequestEntries(latest), to: submenu)
        }

        submenu.addItem(.separator())
        addSection("Runtime", entries: NativStats.runtimeEntries(metrics.server), to: submenu)

        return submenu
    }

    private func addSection(_ title: String, entries: [StatsEntry], to menu: NSMenu) {
        menu.addItem(sectionHeader(title))
        for entry in entries {
            menu.addItem(makeAlignedStatsItem(label: entry.label, value: entry.value, tooltip: entry.tooltip))
        }
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return item
    }

    private func makeAlignedStatsItem(label: String, value: String, tooltip: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tooltip
        item.view = statsRowView(label: label, value: value, tooltip: tooltip)
        return item
    }

    private func statsRowView(label: String, value: String, tooltip: String?) -> NSView {
        let row = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: StatsMenuLayout.rowWidth,
            height: StatsMenuLayout.rowHeight
        ))
        row.toolTip = tooltip

        let labelField = menuLabel(label, alignment: .left, lineBreakMode: .byTruncatingTail)
        let valueField = menuLabel(value, alignment: .right, lineBreakMode: .byTruncatingMiddle)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(labelField)
        row.addSubview(valueField)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: StatsMenuLayout.horizontalPadding),
            labelField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -StatsMenuLayout.minimumColumnGap),

            valueField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -StatsMenuLayout.horizontalPadding),
            valueField.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        row.setAccessibilityLabel("\(label): \(value)")
        return row
    }

    private func menuLabel(_ text: String, alignment: NSTextAlignment, lineBreakMode: NSLineBreakMode) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = alignment
        field.font = NSFont.menuFont(ofSize: 0)
        field.textColor = NSColor.secondaryLabelColor
        field.lineBreakMode = lineBreakMode
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        return field
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func menuIcon(_ systemName: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: description
        )?.withSymbolConfiguration(configuration) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

private enum StatsMenuLayout {
    static let rowWidth: CGFloat = 440
    static let rowHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 14
    static let minimumColumnGap: CGFloat = 24
}

@MainActor
private protocol SessionStatsHighlighting: AnyObject {
    func setHighlighted(_ highlighted: Bool)
}

@MainActor
private final class SessionStatsHighlightState: ObservableObject {
    @Published var isHighlighted = false
}

@MainActor
private final class SessionStatsHostingView<Content: View>: NSHostingView<Content>, SessionStatsHighlighting {
    private let highlightState: SessionStatsHighlightState

    init(rootView: Content, highlightState: SessionStatsHighlightState) {
        self.highlightState = highlightState
        super.init(rootView: rootView)
    }

    required init(rootView: Content) {
        self.highlightState = SessionStatsHighlightState()
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setHighlighted(_ highlighted: Bool) {
        guard highlightState.isHighlighted != highlighted else {
            return
        }
        highlightState.isHighlighted = highlighted
    }
}

private enum SessionStatsMenuPalette {
    static let normalPromptAccent = Color(red: 0.31, green: 0.72, blue: 0.77)
    static let normalGeneratedAccent = Color(red: 0.45, green: 0.55, blue: 0.92)
    static let selectedText = Color(nsColor: .selectedMenuItemTextColor)
    static let selectionBackground = Color(red: 0.34, green: 0.62, blue: 0.95)

    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? selectedText : Color(nsColor: .controlTextColor)
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? selectedText : Color(nsColor: .secondaryLabelColor)
    }

    static func divider(_ highlighted: Bool) -> Color {
        highlighted ? selectedText.opacity(0.24) : Color(nsColor: .separatorColor)
    }

    static func promptAccent(_ highlighted: Bool) -> Color {
        highlighted ? selectedText.opacity(0.9) : normalPromptAccent
    }

    static func generatedAccent(_ highlighted: Bool) -> Color {
        highlighted ? selectedText.opacity(0.58) : normalGeneratedAccent
    }
}

private enum SessionStatsSection {
    case header
    case body

    var height: CGFloat {
        switch self {
        case .header:
            64
        case .body:
            296
        }
    }
}

private struct SessionStatsContainerView: View {
    @ObservedObject var model: NativModel
    @ObservedObject var runtime: SystemRuntimeMonitor
    @ObservedObject var highlightState: SessionStatsHighlightState
    let section: SessionStatsSection

    private var isLoading: Bool {
        model.metricsLoading || model.modelSwitchInProgress
    }

    var body: some View {
        Group {
            if let metrics = model.sessionStatsDisplayMetrics {
                SessionStatsMenuView(
                    metrics: metrics,
                    runtime: runtime,
                    tokenActivity: model.sessionStatsDisplayTokenActivity,
                    isLoading: isLoading,
                    isHighlighted: highlightState.isHighlighted,
                    section: section,
                    displayModel: isLoading
                        ? model.selectedModelDisplay
                        : metrics.server.displayLoadedModel
                )
            } else {
                SessionStatsLoadingMenuView(
                    modelName: model.selectedModelDisplay,
                    runtime: runtime,
                    isHighlighted: highlightState.isHighlighted,
                    section: section,
                    statusText: model.settings.normalized().languageModelID == nil
                        ? "Starting server…"
                        : "Loading model…"
                )
            }
        }
        .frame(width: 350, height: section.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlightState.isHighlighted
                    ? SessionStatsMenuPalette.selectionBackground
                    : .clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .animation(.easeOut(duration: 0.06), value: highlightState.isHighlighted)
    }
}

private struct SessionStatsMenuView: View {
    let metrics: NativMetrics
    @ObservedObject var runtime: SystemRuntimeMonitor
    let tokenActivity: [SessionTokenActivitySample]
    let isLoading: Bool
    let isHighlighted: Bool
    let section: SessionStatsSection
    let displayModel: String

    private var primaryTextColor: Color {
        SessionStatsMenuPalette.primary(isHighlighted)
    }

    private var secondaryTextColor: Color {
        SessionStatsMenuPalette.secondary(isHighlighted)
    }

    private var dividerColor: Color {
        SessionStatsMenuPalette.divider(isHighlighted)
    }

    private var accent: Color {
        SessionStatsMenuPalette.promptAccent(isHighlighted)
    }

    private var generatedAccent: Color {
        SessionStatsMenuPalette.generatedAccent(isHighlighted)
    }

    private var totalTokens: Int {
        metrics.summary.totalProcessedTokens
    }

    var body: some View {
        Group {
            switch section {
            case .header:
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                        .overlay(dividerColor)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            case .body:
                statsBody
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .opacity(isLoading ? 0.42 : 1)
            }
        }
        .frame(width: 350, height: section.height, alignment: .topLeading)
        .foregroundStyle(primaryTextColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section == .header
            ? "Nativ Server status"
            : "Nativ Server session statistics")
    }

    private var statsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionOverview

            SessionActivityPlot(
                values: tokenActivity,
                promptAccent: accent,
                generatedAccent: generatedAccent,
                secondaryTextColor: secondaryTextColor
            )
            .padding(.top, 12)

            Divider()
                .overlay(dividerColor)
                .padding(.vertical, 10)

            metricsGrid

            if let latest = metrics.latest {
                Divider()
                    .overlay(dividerColor)
                    .padding(.vertical, 10)
                latestRequest(latest)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nativ Server")
                    .font(.headline)
                SessionMemoryUsageLabel(
                    runtime: runtime,
                    textColor: secondaryTextColor
                )
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(primaryTextColor)
                    }
                    Text(isLoading ? "Loading model…" : "Running")
                        .font(.headline)
                }
                Text(NativFormatting.truncateModelName(
                    displayModel,
                    maxLength: 20
                ))
                .font(.subheadline)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
            }

        }
    }

    private var sessionOverview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Processed tokens")
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                    Text(formatted(totalTokens))
                        .font(.title2.weight(.semibold).monospacedDigit())
                }

                Spacer()

                metric(
                    "Average decode",
                    NativFormatting.rate(metrics.summary.averageDecodeTokensPerSecond),
                    alignment: .trailing
                )

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryTextColor)
            }

            HStack(spacing: 16) {
                tokenBreakdown(
                    "Prompt",
                    value: metrics.summary.promptTokensTotal,
                    color: accent
                )
                tokenBreakdown(
                    "Generated",
                    value: metrics.summary.generatedTokensTotal,
                    color: generatedAccent
                )
            }
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 12
        ) {
            metric("Completed requests", formatted(metrics.summary.requestsCompleted))
            metric("Failed requests", formatted(metrics.summary.requestsFailed))
            metric("In flight", NativFormatting.integer(metrics.summary.inFlight))
            metric("Uptime", NativFormatting.duration(metrics.summary.uptimeSeconds))
        }
    }

    private func tokenBreakdown(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(label) \(formatted(value))")
                .font(.caption)
                .foregroundStyle(secondaryTextColor)
        }
    }

    private func latestRequest(_ latest: NativLatestRequest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            metric(
                "Latest request",
                "\(formatted(latest.promptTokens + latest.generatedTokens)) tokens"
            )
            Spacer(minLength: 8)
            metric(
                "Prefill speed",
                NativFormatting.rate(latest.prefillTokensPerSecond),
                alignment: .center
            )
            Spacer(minLength: 8)
            metric(
                "Decode speed",
                NativFormatting.rate(latest.decodeTokensPerSecond),
                alignment: .trailing
            )
        }
    }

    private func metric(
        _ label: String,
        _ value: String,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(secondaryTextColor)
            Text(value)
                .font(.body.weight(.semibold))
        }
    }

    private func formatted(_ value: Int) -> String {
        NativFormatting.compactCount(value).display
    }
}

private struct SessionStatsLoadingMenuView: View {
    let modelName: String
    @ObservedObject var runtime: SystemRuntimeMonitor
    let isHighlighted: Bool
    let section: SessionStatsSection
    let statusText: String

    private var primaryTextColor: Color {
        SessionStatsMenuPalette.primary(isHighlighted)
    }

    private var secondaryTextColor: Color {
        SessionStatsMenuPalette.secondary(isHighlighted)
    }

    private var dividerColor: Color {
        SessionStatsMenuPalette.divider(isHighlighted)
    }

    var body: some View {
        Group {
            switch section {
            case .header:
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                        .overlay(dividerColor)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            case .body:
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(primaryTextColor)
                        Text("Session stats will appear when the server is ready.")
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                }
            }
        }
        .frame(width: 350, height: section.height, alignment: .topLeading)
        .foregroundStyle(primaryTextColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section == .header
            ? "Nativ Server is loading \(modelName)"
            : "Waiting for session statistics")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nativ Server")
                    .font(.headline)
                SessionMemoryUsageLabel(
                    runtime: runtime,
                    textColor: secondaryTextColor
                )
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(primaryTextColor)
                    Text(statusText)
                        .font(.headline)
                }
                Text(NativFormatting.truncateModelName(modelName, maxLength: 20))
                    .font(.subheadline)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }
        }
    }
}

private struct SessionMemoryUsageLabel: View {
    @ObservedObject var runtime: SystemRuntimeMonitor
    let textColor: Color

    private var usageFraction: Double {
        runtime.memoryUsageFraction
    }

    private var compactValue: String {
        guard runtime.usedMemoryBytes > 0, runtime.totalMemoryBytes > 0 else {
            return "--"
        }
        return String(
            format: "%.1f / %.0f GB",
            gibibytes(runtime.usedMemoryBytes),
            gibibytes(runtime.totalMemoryBytes)
        )
    }

    private var detailedValue: String {
        guard runtime.usedMemoryBytes > 0, runtime.totalMemoryBytes > 0 else {
            return "Memory usage unavailable"
        }
        return String(
            format: "Memory usage: %.1f GB of %.0f GB (%d%%)",
            gibibytes(runtime.usedMemoryBytes),
            gibibytes(runtime.totalMemoryBytes),
            Int((usageFraction * 100).rounded())
        )
    }

    private var iconColor: Color {
        switch usageFraction {
        case 0.85...:
            return .red
        case 0.70...:
            return .orange
        default:
            return .green
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "memorychip")
                .foregroundStyle(iconColor)
            ProgressView(value: usageFraction)
                .progressViewStyle(.linear)
                .tint(iconColor)
                .frame(width: 54)
            Text(compactValue)
                .monospacedDigit()
                .foregroundStyle(textColor)
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .help(detailedValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory usage")
        .accessibilityValue(detailedValue)
    }

    private func gibibytes(_ bytes: UInt64) -> Double {
        Double(bytes) / Double(1024 * 1024 * 1024)
    }
}

private struct SessionActivityPlot: View {
    let values: [SessionTokenActivitySample]
    let promptAccent: Color
    let generatedAccent: Color
    let secondaryTextColor: Color

    private struct Bucket {
        var promptTokens = 0
        var generatedTokens = 0

        var totalTokens: Int {
            promptTokens + generatedTokens
        }
    }

    private let bucketCount = 30
    private let bucketDuration: TimeInterval = 20

    private var plottedValues: [Bucket] {
        var buckets = Array(repeating: Bucket(), count: bucketCount)
        let currentBucketStart = floor(Date().timeIntervalSince1970 / bucketDuration) * bucketDuration
        let windowStart = currentBucketStart - (Double(bucketCount - 1) * bucketDuration)

        for sample in values {
            let elapsed = sample.recordedAt.timeIntervalSince1970 - windowStart
            let index = Int(floor(elapsed / bucketDuration))
            guard buckets.indices.contains(index) else {
                continue
            }
            buckets[index].promptTokens += sample.promptTokens
            buckets[index].generatedTokens += sample.generatedTokens
        }
        return buckets
    }

    private var maximumValue: CGFloat {
        CGFloat(max(plottedValues.map(\.totalTokens).max() ?? 0, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Recent token activity")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Last ~10 min")
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(plottedValues.enumerated()), id: \.offset) { _, sample in
                    activityBar(sample)
                }
            }
            .frame(height: 46, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent token activity")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private func activityBar(_ sample: Bucket) -> some View {
        let total = sample.totalTokens
        if total == 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(promptAccent.opacity(0.18))
                .frame(maxWidth: .infinity)
                .frame(height: 2)
        } else {
            let hasBothSegments = sample.promptTokens > 0 && sample.generatedTokens > 0
            let barHeight = max(
                hasBothSegments ? 6 : 4,
                44 * CGFloat(total) / maximumValue
            )
            let promptHeight = segmentHeight(
                value: sample.promptTokens,
                total: total,
                barHeight: barHeight,
                hasBothSegments: hasBothSegments
            )
            let generatedHeight = barHeight - promptHeight

            VStack(spacing: 0) {
                if generatedHeight > 0 {
                    Rectangle()
                        .fill(generatedAccent.opacity(0.95))
                        .frame(height: generatedHeight)
                }
                if promptHeight > 0 {
                    Rectangle()
                        .fill(promptAccent.opacity(0.95))
                        .frame(height: promptHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func segmentHeight(
        value: Int,
        total: Int,
        barHeight: CGFloat,
        hasBothSegments: Bool
    ) -> CGFloat {
        guard value > 0 else {
            return 0
        }
        guard hasBothSegments else {
            return barHeight
        }
        let proportionalHeight = barHeight * CGFloat(value) / CGFloat(total)
        return min(max(proportionalHeight, 2), barHeight - 2)
    }

    private var accessibilityValue: String {
        let promptTokens = plottedValues.reduce(0) { $0 + $1.promptTokens }
        let generatedTokens = plottedValues.reduce(0) { $0 + $1.generatedTokens }
        return "\(promptTokens) prompt and \(generatedTokens) generated tokens over the last 10 minutes"
    }
}
