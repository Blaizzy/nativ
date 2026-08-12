import AppKit
import NativServerKit
import SwiftUI
import UserNotifications

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
            case .imageEditing:
                symbolName = "photo.on.rectangle.angled"
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
            case .drafter:
                symbolName = "hare.fill"
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let model = NativModel()
    let softwareUpdater = SoftwareUpdater()
    private let voiceDictationExtension = VoiceDictationExtension()
    private lazy var extensionManager = NativExtensionManager(
        builtInExtensions: [voiceDictationExtension]
    )
    private let controlPanelNavigation = ControlPanelNavigation()
    private let runtime = SystemRuntimeMonitor()
    private let routineStore = RoutineStore.shared
    private lazy var routineRunner = RoutineRunner(
        model: model,
        store: routineStore,
        sessionStore: ChatSessionStore()
    )
    private lazy var routineScheduler = RoutineScheduler(
        store: routineStore,
        onFire: { [weak self] routine, source in
            self?.routineRunner.run(routine, source: source)
        }
    )
    private let systemMenuBarPreferences = SystemMenuBarPreferences.shared
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
        runtime.onUpdate = { [weak self] in
            self?.updateStatusItemButton()
        }
        systemMenuBarPreferences.onChange = { [weak self] in
            self?.updateStatusItemButton()
        }
        runtime.start()
        setUpRoutines()
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

        extensionManager.onRecordsChanged = { [weak self] in
            self?.rebuildMenu()
        }
        configureStatusItem()
        extensionManager.launch(
            context: NativExtensionHostContext(
                transcriptionConfiguration: { [weak self] in
                    guard let self else {
                        return nil
                    }
                    let settings = self.model.settings.normalized()
                    return VoiceTranscriptionConfiguration(
                        modelSearchPath: settings.modelSearchPath,
                        additionalModelSearchPaths: settings.additionalModelSearchPaths,
                        selectedModelID: settings.speechToTextModelID,
                        languageModelID: settings.languageModelID,
                        maxTokens: settings.maxTokens,
                        serverBaseURL: self.model.activeServerBaseURL ?? settings.serverBaseURL,
                        serverAPIKey: settings.serverAPIKey,
                        serverIsRunning: self.model.isRunning
                    )
                },
                openSpeechModels: { [weak self] in
                    self?.controlPanelNavigation.openSpeechModelDiscovery()
                },
                showMainWindow: { [weak self] in
                    self?.showMainWindow()
                }
            )
        )
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
        extensionManager.shutdown()
        runtime.onUpdate = nil
        systemMenuBarPreferences.onChange = nil
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
        guard let modelID = rawModelID?.isEmpty == false ? rawModelID : nil else {
            model.switchLanguageModel(to: nil)
            return
        }
        guard let localModel = localModels.first(where: { $0.repoID == modelID }) else {
            model.switchLanguageModel(to: modelID)
            return
        }
        requestLanguageModelSwitch(to: localModel)
    }

    @objc private func refreshModelsFromMenu(_ sender: Any?) {
        refreshLocalModels()
    }

    @objc private func openDashboardFromMenu(_ sender: Any?) {
        controlPanelNavigation.open(.dashboard)
        showMainWindow()
    }

    @objc private func openAudioFromMenu(_ sender: Any?) {
        if extensionManager.isEnabled(
            extensionID: NativExtensionManager.voiceDictationID
        ) {
            controlPanelNavigation.openExtensionPage(
                NativExtensionManager.voiceAudioPageID
            )
        } else {
            controlPanelNavigation.open(.extensions)
        }
        showMainWindow()
    }

    @objc private func openSystemFromMenu(_ sender: Any?) {
        controlPanelNavigation.open(.system)
        showMainWindow()
    }

    @objc private func openModelsFromMenu(_ sender: Any?) {
        controlPanelNavigation.open(.models)
        showMainWindow()
    }

    @objc private func openVoiceRecordingsFromMenu(_ sender: Any?) {
        extensionManager.performCommand(
            id: VoiceDictationExtension.showRecordingsCommandID
        )
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
            extensionManager: extensionManager,
            softwareUpdater: softwareUpdater,
            onComplete: { [weak self] modelID, serverAPIKey in
                self?.completeWelcome(modelID: modelID, serverAPIKey: serverAPIKey)
            }
        )
    }

    func registerMainWindowOpener(_ opener: @escaping () -> Void) {
        mainWindowOpener = opener
    }

    func openSettings() {
        controlPanelNavigation.open(.settings)
        showMainWindow()
    }

    func createNewChat() {
        controlPanelNavigation.createChat()
        showMainWindow()
    }

    func toggleSidebar() {
        controlPanelNavigation.toggleSidebar()
        showMainWindow()
    }

    private func setUpRoutines() {
        RoutineRunCoordinator.shared.configure(runner: routineRunner)
        routineRunner.onRunCompleted = { [weak self] routine, run in
            self?.postRoutineNotification(routine: routine, run: run)
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
        routineStore.onRoutinesChanged = { [weak self] in
            self?.refreshRoutineAgents()
        }
        refreshRoutineAgents()
        routineScheduler.start()
    }

    private func refreshRoutineAgents() {
        RoutineLaunchAgent.refresh(routines: routineStore.routines)
    }

    private func postRoutineNotification(routine: Routine, run: RoutineRun) {
        guard routine.notifyOnFinish else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = routine.name.isEmpty ? "Routine" : routine.name
        content.body = run.status == .failed
            ? "Run failed. \(run.resultSummary)"
            : (run.resultSummary.isEmpty ? "Run finished." : run.resultSummary)
        if let sessionID = run.sessionID {
            content.userInfo = ["sessionID": sessionID.uuidString]
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: run.id, content: content, trigger: nil)
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.controlPanelNavigation.open(.chat)
            self?.showMainWindow()
        }
        completionHandler()
    }

    func toggleAllSidebarSections() {
        controlPanelNavigation.collapseAllSections()
        showMainWindow()
    }

    func increaseChatFontSize() {
        stepChatFontSize(by: 1)
    }

    func decreaseChatFontSize() {
        stepChatFontSize(by: -1)
    }

    func resetChatFontSize() {
        var settings = model.settings
        settings.resetChatFontScale()
        model.settings = settings.normalized()
    }

    private func stepChatFontSize(by delta: Int) {
        var settings = model.settings
        settings.stepChatFontScale(by: delta)
        model.settings = settings.normalized()
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
        updateStatusItemButton()
        rebuildMenu()
    }

    private func updateStatusItemButton() {
        guard let statusItem, let button = statusItem.button else { return }
        let items = systemMenuBarPreferences.orderedItems

        if items.isEmpty {
            statusItem.length = NSStatusItem.squareLength
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(named: "MenuBarLogo")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
            button.imagePosition = .imageOnly
            button.toolTip = "Nativ Server"
            return
        }

        let renderedItems = items.map { item in
            let usage = menuBarUsage(for: item.metric)
            let percent = Int((usage * 100).rounded())
            let description: String
            let image: NSImage

            switch item.style {
            case .percentage:
                description = "\(item.metric.title) \(percent)%"
                image = menuBarPercentageImage(
                    metricTitle: item.metric.menuBarLabel,
                    percent: percent
                )
            case .graph:
                description = "\(item.metric.title) \(percent)% usage graph"
                image = menuBarGraphImage(
                    values: menuBarHistory(for: item.metric),
                    accessibilityDescription: "\(item.metric.title) usage graph"
                )
            case .gigabytes:
                let value = menuBarMemoryUsedText()
                description = "Memory \(value)"
                image = menuBarGigabytesImage(value: value)
            }
            return (image: image, description: description)
        }

        let accessibilityDescription = renderedItems
            .map { $0.description }
            .joined(separator: ", ")
        let compositeImage = menuBarCompositeImage(
            renderedItems.map { $0.image },
            accessibilityDescription: accessibilityDescription
        )

        statusItem.length = compositeImage.size.width + 6
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = compositeImage
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = accessibilityDescription
    }

    private func menuBarCompositeImage(
        _ images: [NSImage],
        accessibilityDescription: String
    ) -> NSImage {
        let spacing: CGFloat = 4
        let height = images.map(\.size.height).max() ?? 20
        let contentWidth = images.reduce(CGFloat.zero) {
            $0 + $1.size.width
        }
        let width = contentWidth + (spacing * CGFloat(max(images.count - 1, 0)))
        let size = NSSize(width: width, height: height)
        let compositeImage = NSImage(size: size, flipped: false) { rect in
            var originX = rect.minX
            for image in images {
                let imageRect = NSRect(
                    x: originX,
                    y: rect.midY - (image.size.height / 2),
                    width: image.size.width,
                    height: image.size.height
                )
                image.draw(in: imageRect)
                originX += image.size.width + spacing
            }
            return true
        }
        compositeImage.isTemplate = true
        compositeImage.accessibilityDescription = accessibilityDescription
        return compositeImage
    }

    private func menuBarPercentageImage(
        metricTitle: String,
        percent: Int
    ) -> NSImage {
        let size = NSSize(width: 34, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle,
            ]
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 10,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle,
            ]
            let labelHeight = NSAttributedString(
                string: metricTitle,
                attributes: labelAttributes
            ).size().height
            let valueHeight = NSAttributedString(
                string: "\(percent)%",
                attributes: valueAttributes
            ).size().height
            let spacing: CGFloat = -2
            let contentHeight = labelHeight + spacing + valueHeight
            let originY = floor((rect.height - contentHeight) / 2)

            NSAttributedString(
                string: "\(percent)%",
                attributes: valueAttributes
            ).draw(
                in: NSRect(
                    x: rect.minX,
                    y: originY,
                    width: rect.width,
                    height: valueHeight
                )
            )
            NSAttributedString(
                string: metricTitle,
                attributes: labelAttributes
            ).draw(
                in: NSRect(
                    x: rect.minX,
                    y: originY + valueHeight + spacing,
                    width: rect.width,
                    height: labelHeight
                )
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(metricTitle) \(percent) percent"
        return image
    }

    private func menuBarMemoryUsedText() -> String {
        guard runtime.usedMemoryBytes > 0 else {
            return "--\u{2009}GB"
        }
        let usedGigabytes = Double(runtime.usedMemoryBytes) / 1_073_741_824
        return String(format: "%.0f\u{2009}GB", usedGigabytes)
    }

    private func menuBarGigabytesImage(value: String) -> NSImage {
        let size = NSSize(width: 48, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle,
            ]
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 9,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle,
            ]
            let label = NSAttributedString(
                string: "MEM",
                attributes: labelAttributes
            )
            let valueLabel = NSAttributedString(
                string: value,
                attributes: valueAttributes
            )
            let spacing: CGFloat = -2
            let contentHeight = label.size().height
                + spacing
                + valueLabel.size().height
            let originY = floor((rect.height - contentHeight) / 2)

            valueLabel.draw(
                in: NSRect(
                    x: rect.minX,
                    y: originY,
                    width: rect.width,
                    height: valueLabel.size().height
                )
            )
            label.draw(
                in: NSRect(
                    x: rect.minX,
                    y: originY + valueLabel.size().height + spacing,
                    width: rect.width,
                    height: label.size().height
                )
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Memory \(value)"
        return image
    }

    private func menuBarUsage(for metric: SystemMenuBarMetric) -> Double {
        switch metric {
        case .nativ:
            0
        case .cpu:
            runtime.cpuUsage
        case .gpu:
            runtime.gpuUsage ?? 0
        case .ram:
            runtime.memoryUsageFraction
        }
    }

    private func menuBarHistory(for metric: SystemMenuBarMetric) -> [Double] {
        switch metric {
        case .nativ:
            []
        case .cpu:
            runtime.cpuHistory
        case .gpu:
            runtime.gpuHistory
        case .ram:
            runtime.memoryHistory
        }
    }

    private func menuBarGraphImage(
        values: [Double],
        accessibilityDescription: String
    ) -> NSImage {
        let size = NSSize(width: 42, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()

            let frame = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                xRadius: 3.5,
                yRadius: 3.5
            )
            frame.lineWidth = 1
            frame.stroke()

            guard values.count > 1 else { return true }
            let plotRect = rect.insetBy(dx: 3, dy: 3)
            let path = NSBezierPath()
            for (index, rawValue) in values.enumerated() {
                let fraction = CGFloat(index) / CGFloat(max(values.count - 1, 1))
                let value = min(max(rawValue, 0), 1)
                let point = NSPoint(
                    x: plotRect.minX + (plotRect.width * fraction),
                    y: plotRect.minY + (plotRect.height * CGFloat(value))
                )
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.line(to: point)
                }
            }

            if let fillPath = path.copy() as? NSBezierPath {
                fillPath.line(to: NSPoint(x: plotRect.maxX, y: plotRect.minY))
                fillPath.line(to: NSPoint(x: plotRect.minX, y: plotRect.minY))
                fillPath.close()
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                fillPath.fill()
            }

            NSColor.labelColor.setStroke()
            path.lineWidth = 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
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

        let sessionStatsAreLoading = model.isModelLoading
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

        if extensionManager.isEnabled(
            extensionID: NativExtensionManager.voiceDictationID
        ) {
            let audioMenuItem = NSMenuItem(
                title: "Audio…",
                action: #selector(openAudioFromMenu(_:)),
                keyEquivalent: ""
            )
            audioMenuItem.target = self
            audioMenuItem.image = menuIcon("waveform.badge.mic", description: "Audio")
            menu.addItem(audioMenuItem)
        }

        let systemMenuItem = NSMenuItem(
            title: "System…",
            action: #selector(openSystemFromMenu(_:)),
            keyEquivalent: ""
        )
        systemMenuItem.target = self
        systemMenuItem.image = menuIcon(
            "gauge.open.with.lines.needle.33percent",
            description: "System"
        )
        menu.addItem(systemMenuItem)

        let modelsMenuItem = NSMenuItem(
            title: "Models…",
            action: #selector(openModelsFromMenu(_:)),
            keyEquivalent: ","
        )
        modelsMenuItem.target = self
        modelsMenuItem.keyEquivalentModifierMask = [.command]
        modelsMenuItem.image = menuIcon("cube.transparent", description: "Models")
        menu.addItem(modelsMenuItem)

        if extensionManager.isEnabled(
            extensionID: NativExtensionManager.voiceDictationID
        ) {
            let recordingsMenuItem = NSMenuItem(
                title: "Show Voice Recordings",
                action: #selector(openVoiceRecordingsFromMenu(_:)),
                keyEquivalent: ""
            )
            recordingsMenuItem.target = self
            recordingsMenuItem.image = menuIcon("waveform", description: "Voice recordings")
            menu.addItem(recordingsMenuItem)
        }

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
        self.serverActionMenuItem = serverActionMenuItem
        self.modelMenuItem = modelMenuItem
    }

    private func makeSessionStatsMenuItems() -> [NSMenuItem] {
        let headerItem = NSMenuItem(title: "Session Status", action: nil, keyEquivalent: "")
        let headerView = NSHostingView(rootView: SessionStatsContainerView(
            model: model,
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
        modelMenuItem?.title = modelMenuTitle
        modelMenuItem?.submenu = makeModelSubmenu()
        serverActionMenuItem?.title = model.isRunning ? "Stop Server" : "Start Server"
        serverActionMenuItem?.image = menuIcon(
            model.isRunning ? "stop.circle" : "play.circle",
            description: model.isRunning ? "Stop server" : "Start server"
        )
    }

    private func makeModelMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: modelMenuTitle,
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

        if model.isModelLoading {
            submenu.addItem(disabledMenuItem(model.modelLoadingStatusText ?? "Loading model…"))
            return submenu
        }

        if let failure = model.modelLoadFailure {
            let titleItem = disabledMenuItem(failure.title)
            titleItem.image = menuIcon(
                "exclamationmark.triangle.fill",
                description: "Model loading failed"
            )
            titleItem.toolTip = failure.message
            submenu.addItem(titleItem)

            let messageItem = disabledMenuItem(
                NativFormatting.truncateModelName(failure.message, maxLength: 64)
            )
            messageItem.toolTip = failure.message
            submenu.addItem(messageItem)
            submenu.addItem(.separator())
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
                self?.requestLanguageModelSwitch(to: localModel)
            }
        )
        return item
    }

    private func requestLanguageModelSwitch(to localModel: LocalModel) {
        let requiresConfirmation = model.requestPreloadedModelSwitch(
            to: localModel,
            for: .language,
            availableModels: localModels
        )
        if requiresConfirmation {
            showMainWindow()
        }
    }

    private var selectedModelMenuTitle: String {
        guard let modelID = model.settings.normalized().languageModelID else {
            return "On demand"
        }
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return NativFormatting.truncateModelName(shortName, maxLength: 28)
    }

    private var modelMenuTitle: String {
        if model.isModelLoading {
            if let percentage = model.modelLoadingPercentageText {
                return "Model: Loading \(percentage)"
            }
            return "Model: Loading…"
        }
        if model.modelLoadFailure != nil {
            return "Model: Load failed"
        }
        return "Model: \(selectedModelMenuTitle)"
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

    private var modelScanKey: String {
        model.settings.localModelSearchPaths.cacheKey
    }

    private func refreshLocalModelsIfNeeded() {
        guard lastScannedModelPath != modelScanKey else {
            return
        }
        refreshLocalModels()
    }

    private func refreshLocalModels() {
        modelScanTask?.cancel()
        let searchPaths = model.settings.localModelSearchPaths
        let scanKey = modelScanKey
        modelScanInProgress = true
        modelScanError = nil
        rebuildModelSubmenu()

        modelScanTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
                guard !Task.isCancelled else {
                    return
                }
                self.localModels = models
                self.lastScannedModelPath = scanKey
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.localModels = []
                self.modelScanError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.lastScannedModelPath = scanKey
            }

            self.modelScanInProgress = false
            self.rebuildModelSubmenu()
        }
    }

    private func rebuildModelSubmenu() {
        guard let modelMenuItem else {
            return
        }
        modelMenuItem.title = modelMenuTitle
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
    @ObservedObject var highlightState: SessionStatsHighlightState
    let section: SessionStatsSection

    private var isLoading: Bool {
        model.isModelLoading
    }

    var body: some View {
        Group {
            if let metrics = model.sessionStatsDisplayMetrics {
                SessionStatsMenuView(
                    metrics: metrics,
                    tokenActivity: model.sessionStatsDisplayTokenActivity,
                    isLoading: isLoading,
                    loadingStatusText: model.modelLoadingStatusText,
                    isHighlighted: highlightState.isHighlighted,
                    section: section,
                    displayModel: isLoading
                        ? model.selectedModelDisplay
                        : metrics.server.displayLoadedModel
                )
            } else {
                SessionStatsLoadingMenuView(
                    modelName: model.selectedModelDisplay,
                    isHighlighted: highlightState.isHighlighted,
                    section: section,
                    statusText: model.modelLoadFailure != nil
                        ? "Load failed"
                        : model.settings.normalized().languageModelID == nil
                        ? "Starting server…"
                        : model.modelLoadingStatusText ?? "Loading model…",
                    failure: model.modelLoadFailure
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
    let tokenActivity: [SessionTokenActivitySample]
    let isLoading: Bool
    let loadingStatusText: String?
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

    private var displayModelSubtitle: String? {
        let subtitle = displayModel == "None" ? "On demand" : displayModel
        return NativFormatting.truncateModelName(subtitle, maxLength: 24)
    }

    private var displayModelIndicatorColor: Color {
        switch displayModel {
        case "None", "On demand":
            .orange
        default:
            .green
        }
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
                if let displayModelSubtitle {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(displayModelIndicatorColor)
                            .frame(width: 6, height: 6)
                        Text(displayModelSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 16)

            if isLoading {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(primaryTextColor)
                    Text(loadingStatusText ?? "Loading model…")
                        .font(.headline)
                }
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
    let isHighlighted: Bool
    let section: SessionStatsSection
    let statusText: String
    let failure: ModelLoadFailure?

    private var primaryTextColor: Color {
        SessionStatsMenuPalette.primary(isHighlighted)
    }

    private var secondaryTextColor: Color {
        SessionStatsMenuPalette.secondary(isHighlighted)
    }

    private var dividerColor: Color {
        SessionStatsMenuPalette.divider(isHighlighted)
    }

    private var modelSubtitle: String? {
        return NativFormatting.truncateModelName(modelName, maxLength: 20)
    }

    private var modelIndicatorColor: Color {
        if failure != nil {
            return .red
        }
        switch modelName {
        case "On demand":
            return .orange
        case "None":
            return .red
        default:
            return .green
        }
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
                        if let failure {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(secondaryTextColor)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        } else {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(primaryTextColor)
                            Text("Session stats will appear when the server is ready.")
                                .font(.caption)
                                .foregroundStyle(secondaryTextColor)
                                .multilineTextAlignment(.center)
                        }
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
            ? failure == nil
                ? "Nativ Server is loading \(modelName)"
                : "Nativ Server could not load \(modelName)"
            : failure == nil
                ? "Waiting for session statistics"
                : failure?.message ?? "Model loading failed")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nativ Server")
                    .font(.headline)
                if let modelSubtitle {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(modelIndicatorColor)
                            .frame(width: 6, height: 6)
                        Text(modelSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 5) {
                if failure == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(primaryTextColor)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(statusText)
                    .font(.headline)
            }
        }
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
