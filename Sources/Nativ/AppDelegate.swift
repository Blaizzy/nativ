import AppKit
import NativServerKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
    private let model = NativModel()
    let softwareUpdater = SoftwareUpdater()
    private let voiceDictationExtension = VoiceDictationExtension()
    private lazy var extensionManager = NativExtensionManager(
        builtInExtensions: [voiceDictationExtension]
    )
    private let controlPanelNavigation = ControlPanelNavigation()
    private let runtime = SystemRuntimeMonitor()
    private let routineStore = RoutineStore.shared
    private let routineSessionStore = ChatSessionStore()
    private lazy var routineRunner = RoutineRunner(
        model: model,
        store: routineStore,
        sessionStore: routineSessionStore
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
    private lazy var statusMenuController = StatusMenuController(
        model: model,
        navigation: controlPanelNavigation,
        extensionManager: extensionManager,
        showMainWindow: { [weak self] in
            self?.showMainWindow()
        }
    )
    private var downloadShutdownTask: Task<Void, Never>?
    private var didFinishDownloadShutdown = false

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
            self?.statusMenuController.modelStateDidChange()
        }

        extensionManager.onRecordsChanged = { [weak self] in
            self?.statusMenuController.rebuildMenu()
        }
        configureStatusItem()
        statusMenuController.start()
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
        if WelcomePreferences.hasCompleted {
            model.startServer()
        }
        DispatchQueue.main.async { [softwareUpdater] in
            softwareUpdater.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !didFinishDownloadShutdown else { return .terminateNow }
        guard HuggingFaceDownloadManager.shared.activeCount > 0 else { return .terminateNow }

        if downloadShutdownTask == nil {
            downloadShutdownTask = Task { [weak self, weak sender] in
                await HuggingFaceDownloadManager.shared.shutdownForTermination()
                guard let self, let sender else { return }
                didFinishDownloadShutdown = true
                downloadShutdownTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController.stop()
        extensionManager.shutdown()
        runtime.onUpdate = nil
        systemMenuBarPreferences.onChange = nil
        runtime.stop()
        model.applicationWillTerminate()
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
        routineRunner.onRunCompleted = { routine, run in
            Task { @MainActor in
                guard routine.notifyOnFinish else { return }
                await NativNotificationService.shared.deliver(
                    .scheduledTaskCompletion(routine: routine, run: run)
                )
            }
        }
        UNUserNotificationCenter.current().delegate = self
        routineStore.onRoutinesChanged = { [weak self] in
            self?.refreshRoutineAgents()
        }
        refreshRoutineAgents()
        routineScheduler.start()
    }

    private func refreshRoutineAgents() {
        RoutineLaunchAgent.refresh(routines: routineStore.routines)
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
        let sessionID = (response.notification.request.content.userInfo["sessionID"] as? String)
            .flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { [weak self] in
            if let sessionID {
                self?.controlPanelNavigation.openChatSession(sessionID)
            } else {
                self?.controlPanelNavigation.open(.chat)
            }
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
        statusMenuController.rebuildMenu()
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

        statusItem.menu = statusMenuController.menu

        self.statusItem = statusItem
        updateStatusItemButton()
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
            return NativFormatting.missingValue
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
}
