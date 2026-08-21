import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelCollapseButtons: NSViewRepresentable {
    let showsModelConfigurationButton: Bool
    let sidebarHelp: String
    let modelConfigurationHelp: String
    let onToggleSidebar: () -> Void
    let onToggleModelConfiguration: () -> Void

    func makeNSView(context: Context) -> ControlPanelCollapseButtonsView {
        let view = ControlPanelCollapseButtonsView()
        update(view)
        return view
    }

    func updateNSView(_ view: ControlPanelCollapseButtonsView, context: Context) {
        update(view)
    }

    static func dismantleNSView(
        _ view: ControlPanelCollapseButtonsView,
        coordinator: ()
    ) {
        view.detachButtons()
    }

    private func update(_ view: ControlPanelCollapseButtonsView) {
        view.update(
            showsModelConfigurationButton: showsModelConfigurationButton,
            sidebarHelp: sidebarHelp,
            modelConfigurationHelp: modelConfigurationHelp,
            onToggleSidebar: onToggleSidebar,
            onToggleModelConfiguration: onToggleModelConfiguration
        )
    }
}

@MainActor
final class ControlPanelCollapseButtonsView: NSView {
    private let sidebarButton = ControlPanelCollapseButton(
        systemImageName: "sidebar.left"
    )
    private let modelConfigurationButton = ControlPanelCollapseButton(
        systemImageName: "sidebar.right"
    )
    private weak var attachedContentView: NSView?
    private weak var actionWindow: NSWindow?
    private var localMouseEventMonitor: Any?

    isolated deinit {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachButtons()

        DispatchQueue.main.async { [weak self] in
            self?.attachButtons()
        }
    }

    func update(
        showsModelConfigurationButton: Bool,
        sidebarHelp: String,
        modelConfigurationHelp: String,
        onToggleSidebar: @escaping () -> Void,
        onToggleModelConfiguration: @escaping () -> Void
    ) {
        sidebarButton.toolTip = sidebarHelp
        sidebarButton.setAccessibilityLabel(sidebarHelp)
        sidebarButton.onAction = onToggleSidebar

        modelConfigurationButton.toolTip = modelConfigurationHelp
        modelConfigurationButton.setAccessibilityLabel(modelConfigurationHelp)
        modelConfigurationButton.onAction = onToggleModelConfiguration
        modelConfigurationButton.isHidden = !showsModelConfigurationButton

        attachButtons()
    }

    func detachButtons() {
        stopMonitoringButtonEvents()
        sidebarButton.removeFromSuperview()
        modelConfigurationButton.removeFromSuperview()
        attachedContentView = nil
        actionWindow = nil
    }

    private func attachButtons() {
        guard let window, let contentView = window.contentView else { return }

        if actionWindow !== window {
            stopMonitoringButtonEvents()
            observeButtonEvents(in: window)
            actionWindow = window
        }

        if attachedContentView !== contentView {
            detachButtons()
            observeButtonEvents(in: window)
            actionWindow = window
            for button in [sidebarButton, modelConfigurationButton] {
                button.translatesAutoresizingMaskIntoConstraints = true
                contentView.addSubview(button, positioned: .above, relativeTo: nil)
            }
            attachedContentView = contentView
        }

        positionButtons(in: contentView)
        contentView.addSubview(sidebarButton, positioned: .above, relativeTo: nil)
        contentView.addSubview(
            modelConfigurationButton,
            positioned: .above,
            relativeTo: nil
        )
    }

    private func positionButtons(in contentView: NSView) {
        let buttonSize = ControlPanelLayout.collapseButtonSize
        let topOrigin = ControlPanelLayout.windowControlsCenterY - (buttonSize / 2)
        let originY =
            contentView.isFlipped
            ? topOrigin
            : contentView.bounds.height - topOrigin - buttonSize
        let topAutoresizingMask: NSView.AutoresizingMask =
            contentView.isFlipped
            ? .maxYMargin
            : .minYMargin

        sidebarButton.frame = NSRect(
            x: ControlPanelLayout.sidebarButtonLeadingPadding,
            y: originY,
            width: buttonSize,
            height: buttonSize
        )
        sidebarButton.autoresizingMask = [.maxXMargin, topAutoresizingMask]

        modelConfigurationButton.frame = NSRect(
            x: contentView.bounds.width
                - ControlPanelLayout.modelConfigurationButtonTrailingPadding
                - buttonSize,
            y: originY,
            width: buttonSize,
            height: buttonSize
        )
        modelConfigurationButton.autoresizingMask = [.minXMargin, topAutoresizingMask]
    }

    private func observeButtonEvents(in window: NSWindow) {
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self, weak window] event in
            var result: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let window,
                    event.window === window || window.isKeyWindow,
                    let contentView = self.attachedContentView
                else {
                    return
                }

                let location = contentView.convert(event.locationInWindow, from: nil)
                let buttons = [
                    self.sidebarButton,
                    self.modelConfigurationButton,
                ]
                guard
                    let button = buttons.first(where: {
                        !$0.isHidden
                            && $0.frame.insetBy(dx: -3, dy: -3).contains(location)
                    })
                else {
                    return
                }

                button.highlight(true)
                DispatchQueue.main.async { [weak button] in
                    button?.highlight(false)
                }
                button.performClick(nil)
                result = nil
            }
            return result
        }
    }

    private func stopMonitoringButtonEvents() {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
    }
}

@MainActor
final class ControlPanelCollapseButton: NSButton {
    var onAction: (() -> Void)?

    init(systemImageName: String) {
        super.init(frame: .zero)

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfiguration)
        image?.isTemplate = true
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .labelColor
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        target = self
        action = #selector(performButtonAction(_:))
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc
    private func performButtonAction(_ sender: Any?) {
        onAction?()
    }
}
