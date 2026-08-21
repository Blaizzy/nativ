import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelWindowControls: NSViewRepresentable {
    let refreshTrigger: Int

    func makeNSView(context: Context) -> ControlPanelWindowControlsView {
        let view = ControlPanelWindowControlsView()
        view.update(refreshTrigger: refreshTrigger)
        return view
    }

    func updateNSView(_ view: ControlPanelWindowControlsView, context: Context) {
        view.update(refreshTrigger: refreshTrigger)
    }

    static func dismantleNSView(_ view: ControlPanelWindowControlsView, coordinator: ()) {
        view.detachControls()
    }
}

@MainActor
final class ControlPanelWindowControlsView: NSView {
    private let controlsOverlay = ControlPanelWindowControlsOverlayView()
    private weak var attachedContentView: NSView?
    private var controlsConstraints: [NSLayoutConstraint] = []
    private var lastRefreshTrigger: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachControls()

        DispatchQueue.main.async { [weak self] in
            self?.attachControls()
        }
    }

    func update(refreshTrigger: Int) {
        controlsOverlay.isHidden = false
        attachControls()

        guard refreshTrigger != lastRefreshTrigger else { return }
        lastRefreshTrigger = refreshTrigger

        // AppKit resets the native buttons to a disabled, transparent state at
        // the end of a full-screen transition. Reapply our custom placement
        // after that final transition pass has completed.
        DispatchQueue.main.async { [weak self] in
            self?.attachControls()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attachControls()
        }
    }

    func detachControls() {
        NSLayoutConstraint.deactivate(controlsConstraints)
        controlsConstraints.removeAll()
        controlsOverlay.detachWindow()
        controlsOverlay.removeFromSuperview()
        attachedContentView = nil
    }

    private func attachControls() {
        guard let window, let contentView = window.contentView else { return }

        if attachedContentView !== contentView {
            detachControls()
            controlsOverlay.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(controlsOverlay, positioned: .above, relativeTo: nil)
            controlsConstraints = [
                controlsOverlay.leadingAnchor.constraint(
                    equalTo: contentView.leadingAnchor,
                    constant: ControlPanelLayout.windowControlsLeadingPadding
                ),
                controlsOverlay.topAnchor.constraint(
                    equalTo: contentView.topAnchor,
                    constant: ControlPanelLayout.windowControlsTopPadding
                ),
                controlsOverlay.widthAnchor.constraint(
                    equalToConstant: ControlPanelLayout.windowControlsWidth
                ),
                controlsOverlay.heightAnchor.constraint(
                    equalToConstant: ControlPanelLayout.windowControlsHeight
                ),
            ]
            NSLayoutConstraint.activate(controlsConstraints)
            attachedContentView = contentView
        }

        contentView.addSubview(controlsOverlay, positioned: .above, relativeTo: nil)
        controlsOverlay.installWindowButtons(from: window)
    }
}

@MainActor
final class ControlPanelWindowControlsOverlayView: NSView {
    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton,
    ]
    private static let buttonStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
    ]

    private let windowButtons: [NSButton]
    private weak var actionWindow: NSWindow?
    private var shouldMiniaturizeAfterExitingFullScreen = false
    private var localMouseEventMonitor: Any?

    override init(frame frameRect: NSRect) {
        windowButtons = Self.buttonTypes.compactMap {
            NSWindow.standardWindowButton($0, for: Self.buttonStyleMask)
        }
        super.init(frame: frameRect)

        for button in windowButtons {
            button.autoresizingMask = []
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
        }
    }

    override func layout() {
        super.layout()

        let spacing: CGFloat = 6
        var originX: CGFloat = 0

        for button in windowButtons {
            button.frame.origin = NSPoint(
                x: originX,
                y: (bounds.height - button.frame.height) / 2
            )
            originX += button.frame.width + spacing
        }
    }

    func installWindowButtons(from window: NSWindow) {
        for buttonType in Self.buttonTypes {
            window.standardWindowButton(buttonType)?.isHidden = true
        }

        if actionWindow !== window {
            stopMonitoringWindowButtonEvents()
            observeWindowButtonEvents(in: window)
        }
        actionWindow = window
        for (buttonType, button) in zip(Self.buttonTypes, windowButtons) {
            button.isHidden = false
            button.isEnabled = true
            button.alphaValue = 1
            button.target = self

            switch buttonType {
            case .closeButton:
                button.action = #selector(closeWindow(_:))
            case .miniaturizeButton:
                button.action = #selector(miniaturizeWindow(_:))
            case .zoomButton:
                button.action = #selector(toggleFullScreen(_:))
            default:
                break
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func detachWindow() {
        NotificationCenter.default.removeObserver(self)
        shouldMiniaturizeAfterExitingFullScreen = false
        stopMonitoringWindowButtonEvents()

        if let actionWindow {
            for buttonType in Self.buttonTypes {
                actionWindow.standardWindowButton(buttonType)?.isHidden = false
            }
        }
        actionWindow = nil
    }

    private func observeWindowButtonEvents(in window: NSWindow) {
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self, weak window] event in
            var result: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let window,
                    event.window === window || window.isKeyWindow
                else {
                    return
                }
                result = self.handleWindowButtonEvent(event)
            }
            return result
        }
    }

    private func stopMonitoringWindowButtonEvents() {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
    }

    private func handleWindowButtonEvent(_ event: NSEvent) -> NSEvent? {
        let location = convert(event.locationInWindow, from: nil)
        guard
            let button = windowButtons.first(where: {
                $0.frame.insetBy(dx: -3, dy: -3).contains(location)
            })
        else {
            return event
        }

        button.highlight(true)
        DispatchQueue.main.async { [weak button] in
            button?.highlight(false)
        }
        performWindowAction(for: button)
        return nil
    }

    private func performWindowAction(for button: NSButton) {
        guard let index = windowButtons.firstIndex(where: { $0 === button }),
            Self.buttonTypes.indices.contains(index)
        else {
            return
        }

        switch Self.buttonTypes[index] {
        case .closeButton:
            closeWindow(button)
        case .miniaturizeButton:
            miniaturizeWindow(button)
        case .zoomButton:
            toggleFullScreen(button)
        default:
            break
        }
    }

    @objc
    private func closeWindow(_ sender: Any?) {
        actionWindow?.close()
    }

    @objc
    private func miniaturizeWindow(_ sender: Any?) {
        guard let actionWindow else { return }

        if actionWindow.styleMask.contains(.fullScreen) {
            shouldMiniaturizeAfterExitingFullScreen = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didExitFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: actionWindow
            )
            actionWindow.toggleFullScreen(sender)
        } else {
            actionWindow.miniaturize(sender)
        }
    }

    @objc
    private func toggleFullScreen(_ sender: Any?) {
        actionWindow?.toggleFullScreen(sender)
    }

    @objc
    private func didExitFullScreen(_ notification: Notification) {
        guard shouldMiniaturizeAfterExitingFullScreen,
            let window = notification.object as? NSWindow,
            window === actionWindow
        else {
            return
        }

        shouldMiniaturizeAfterExitingFullScreen = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        window.miniaturize(nil)
    }
}
