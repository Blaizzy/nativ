import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelSurfaceReader: NSViewRepresentable {
    let isFullScreen: Bool

    func makeNSView(context: Context) -> ControlPanelSurfaceReaderView {
        let view = ControlPanelSurfaceReaderView()
        view.update(isFullScreen: isFullScreen)
        return view
    }

    func updateNSView(_ view: ControlPanelSurfaceReaderView, context: Context) {
        view.update(isFullScreen: isFullScreen)
    }
}

nonisolated(unsafe) private var controlPanelBackdropCornerRadiusObservationContext = 0

struct ControlPanelObservedObject: @unchecked Sendable {
    let value: Any?
}

@MainActor
final class ControlPanelSurfaceReaderView: NSView {
    private static let liveCornerCorrectionInterval: TimeInterval = 1 / 30

    private weak var glassSurface: NSView?
    private weak var sidebarBackdropView: NSView?
    private weak var observedSplitView: NSSplitView?
    private weak var observedBackdropCornerRadiusView: NSView?
    private weak var observedWindow: NSWindow?
    private var defaultBackdropEdgeInsets: NSEdgeInsets?
    private var glassCornerRadiusObservation: NSKeyValueObservation?
    private var glassFrameObservation: NSKeyValueObservation?
    private var layerCornerRadiusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cornerCorrectionTimer: Timer?
    private var liveResizeCornerCorrectionTimer: Timer?
    private var liveResizeStopWorkItem: DispatchWorkItem?
    private var localMouseEventMonitor: Any?
    private var isFullScreen = false

    isolated deinit {
        cornerCorrectionTimer?.invalidate()
        liveResizeCornerCorrectionTimer?.invalidate()
        liveResizeStopWorkItem?.cancel()
        glassCornerRadiusObservation?.invalidate()
        glassFrameObservation?.invalidate()
        for observation in layerCornerRadiusObservations.values {
            observation.invalidate()
        }
        observedBackdropCornerRadiusView?.removeObserver(
            self,
            forKeyPath: "punchOutCornerRadius",
            context: &controlPanelBackdropCornerRadiusObservationContext
        )
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFullScreenTransitions()

        if window?.styleMask.contains(.fullScreen) == true {
            isFullScreen = true
        }

        updateCornerCorrectionTimer()
        configureGlassSurface()
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface()
        }
    }

    override func layout() {
        super.layout()
        if liveResizeCornerCorrectionTimer == nil {
            configureGlassSurface()
        }
    }

    func update(isFullScreen: Bool) {
        self.isFullScreen = isFullScreen
        updateCornerCorrectionTimer()

        if liveResizeCornerCorrectionTimer == nil {
            configureGlassSurface()
        }
    }

    private func observeFullScreenTransitions() {
        guard observedWindow !== window else { return }
        NotificationCenter.default.removeObserver(self)
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
        observedSplitView = nil
        observedWindow = window
        guard let window else { return }
        observeSidebarDragEvents(in: window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        for notificationName in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willStartLiveResizeNotification,
            NSWindow.didEndLiveResizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowGeometryDidChange(_:)),
                name: notificationName,
                object: window
            )
        }
    }

    private func observeSidebarDragEvents(in window: NSWindow) {
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard event.window === window else { return }
                if event.type == .leftMouseDragged {
                    self?.beginLiveSidebarResizeCornerCorrection()
                } else {
                    self?.scheduleEndLiveSidebarResizeCornerCorrection()
                }
            }
            return event
        }
    }

    @objc
    private func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        updateCornerCorrectionTimer()
        configureGlassSurface()
    }

    @objc
    private func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true

        // AppKit reapplies its concentric radius while completing this event.
        // Correct the live surface after its final full-screen layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.configureGlassSurface()
        }
    }

    @objc
    private func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        updateCornerCorrectionTimer()
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface()
        }
    }

    @objc
    private func windowGeometryDidChange(_ notification: Notification) {
        configureGlassSurface(adjustsConstraints: false)
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface(adjustsConstraints: false)
        }
    }

    @objc
    private func splitViewDidResize(_ notification: Notification) {
        beginLiveSidebarResizeCornerCorrection()
    }

    private func updateCornerCorrectionTimer() {
        guard isFullScreen, window != nil else {
            cornerCorrectionTimer?.invalidate()
            cornerCorrectionTimer = nil
            return
        }
        guard cornerCorrectionTimer == nil else { return }

        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(correctSidebarCorners(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        cornerCorrectionTimer = timer
    }

    @objc
    private func correctSidebarCorners(_ timer: Timer) {
        guard isFullScreen else {
            updateCornerCorrectionTimer()
            return
        }
        configureGlassSurface()
    }

    private func configureGlassSurface(adjustsConstraints: Bool = true) {
        guard #available(macOS 26.0, *) else { return }
        var ancestor = superview
        var glassSurface: NSGlassEffectView?

        while let current = ancestor {
            if let glass = current as? NSGlassEffectView {
                glassSurface = glass
                break
            }
            ancestor = current.superview
        }

        guard let glassSurface, let container = glassSurface.superview else { return }
        observeSidebarResizing(above: container)

        if self.glassSurface !== glassSurface {
            glassCornerRadiusObservation?.invalidate()
            glassFrameObservation?.invalidate()
            for observation in layerCornerRadiusObservations.values {
                observation.invalidate()
            }
            layerCornerRadiusObservations.removeAll()
            self.glassSurface = glassSurface
            glassCornerRadiusObservation = glassSurface.observe(
                \.cornerRadius,
                options: [.new]
            ) { surface, _ in
                MainActor.assumeIsolated {
                    guard surface.cornerRadius != 0 else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        context.allowsImplicitAnimation = false
                        surface.cornerRadius = 0
                    }
                }
            }
            glassFrameObservation = glassSurface.observe(
                \.frame,
                options: [.new]
            ) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.beginLiveSidebarResizeCornerCorrection()
                }
            }
        }
        setCornerRadiusToZero(on: glassSurface)

        configureSidebarBackdrop(in: container, excluding: glassSurface)
        configureFullSizeGlassLayers(in: glassSurface)

        guard adjustsConstraints else { return }

        var changedConstraint = false
        for constraint in container.constraints {
            let firstView = constraint.firstItem as? NSView
            let secondView = constraint.secondItem as? NSView
            let directlyPositionsSurface =
                (firstView === glassSurface && secondView === container)
                || (firstView === container && secondView === glassSurface)

            guard directlyPositionsSurface else { continue }
            let extendsPastBottomEdge =
                isFullScreen
                && constraint.firstAttribute == .bottom
                && constraint.secondAttribute == .bottom
            let extendsPastLeadingEdge =
                isFullScreen
                && ((constraint.firstAttribute == .leading
                    && constraint.secondAttribute == .leading)
                    || (constraint.firstAttribute == .left
                        && constraint.secondAttribute == .left))
            let targetConstant: CGFloat
            if extendsPastBottomEdge {
                targetConstant = firstView === glassSurface ? 2 : -2
            } else if extendsPastLeadingEdge {
                targetConstant = firstView === glassSurface ? -4 : 4
            } else {
                targetConstant = 0
            }

            if constraint.constant != targetConstant {
                constraint.constant = targetConstant
                changedConstraint = true
            }
        }

        if changedConstraint {
            container.needsUpdateConstraints = true
            container.needsLayout = true
        }
    }

    private func beginLiveSidebarResizeCornerCorrection() {
        if liveResizeCornerCorrectionTimer == nil {
            configureGlassSurface(adjustsConstraints: false)
            let timer = Timer(
                timeInterval: Self.liveCornerCorrectionInterval,
                target: self,
                selector: #selector(correctLiveSidebarResizeCorners(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            liveResizeCornerCorrectionTimer = timer
        }

        scheduleEndLiveSidebarResizeCornerCorrection()
    }

    private func scheduleEndLiveSidebarResizeCornerCorrection() {
        guard liveResizeCornerCorrectionTimer != nil else { return }
        liveResizeStopWorkItem?.cancel()
        let stopWorkItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endLiveSidebarResizeCornerCorrection()
            }
        }
        liveResizeStopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.35,
            execute: stopWorkItem
        )
    }

    @objc
    private func correctLiveSidebarResizeCorners(_ timer: Timer) {
        configureGlassSurface(adjustsConstraints: false)
    }

    private func endLiveSidebarResizeCornerCorrection() {
        liveResizeCornerCorrectionTimer?.invalidate()
        liveResizeCornerCorrectionTimer = nil
        liveResizeStopWorkItem = nil
        configureGlassSurface(adjustsConstraints: false)
    }

    private func observeSidebarResizing(above view: NSView) {
        var ancestor: NSView? = view
        while let current = ancestor, !(current is NSSplitView) {
            ancestor = current.superview
        }
        guard let splitView = ancestor as? NSSplitView,
            observedSplitView !== splitView
        else {
            return
        }

        if let observedSplitView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSSplitView.didResizeSubviewsNotification,
                object: observedSplitView
            )
        }
        observedSplitView = splitView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    private func startObservingBackdropCornerRadius(_ backdropView: NSView) {
        let setter = NSSelectorFromString("setPunchOutCornerRadius:")
        guard backdropView.responds(to: setter) else { return }

        backdropView.addObserver(
            self,
            forKeyPath: "punchOutCornerRadius",
            options: [.new],
            context: &controlPanelBackdropCornerRadiusObservationContext
        )
        observedBackdropCornerRadiusView = backdropView
    }

    private func stopObservingBackdropCornerRadius() {
        guard let observedBackdropCornerRadiusView else { return }
        observedBackdropCornerRadiusView.removeObserver(
            self,
            forKeyPath: "punchOutCornerRadius",
            context: &controlPanelBackdropCornerRadiusObservationContext
        )
        self.observedBackdropCornerRadiusView = nil
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &controlPanelBackdropCornerRadiusObservationContext else {
            super.observeValue(
                forKeyPath: keyPath,
                of: object,
                change: change,
                context: context
            )
            return
        }

        let observedObject = ControlPanelObservedObject(value: object)
        MainActor.assumeIsolated {
            guard let backdropView = observedObject.value as? NSView else {
                return
            }
            let cornerRadius =
                (backdropView.value(forKey: "punchOutCornerRadius") as? NSNumber)?
                .doubleValue ?? 0
            if cornerRadius != 0 {
                setBackdropCornerRadiusToZero(
                    on: backdropView,
                    key: "punchOutCornerRadius"
                )
            }
        }
    }

    private func configureSidebarBackdrop(
        in container: NSView,
        excluding glassSurface: NSView
    ) {
        let cornerRadiusKey = "punchOutCornerRadius"
        let edgeInsetsKey = "punchOutEdgeInsets"
        let cornerRadiusSelector = NSSelectorFromString(cornerRadiusKey)
        let edgeInsetsSelector = NSSelectorFromString(edgeInsetsKey)

        var candidateViews = container.subviews
        var backdropViews = [NSView]()
        var index = 0

        while index < candidateViews.count {
            let candidate = candidateViews[index]
            index += 1
            candidateViews.append(contentsOf: candidate.subviews)

            guard candidate !== glassSurface,
                !candidate.isDescendant(of: glassSurface),
                candidate.responds(to: cornerRadiusSelector),
                candidate.responds(to: edgeInsetsSelector)
            else {
                continue
            }
            backdropViews.append(candidate)
        }

        guard let primaryBackdropView = backdropViews.first else { return }

        if sidebarBackdropView !== primaryBackdropView {
            stopObservingBackdropCornerRadius()
            sidebarBackdropView = primaryBackdropView
            defaultBackdropEdgeInsets =
                (primaryBackdropView.value(forKey: edgeInsetsKey) as? NSValue)?
                .edgeInsetsValue
            startObservingBackdropCornerRadius(primaryBackdropView)
        }

        for backdropView in backdropViews {
            setBackdropCornerRadiusToZero(
                on: backdropView,
                key: cornerRadiusKey
            )

            if let edgeInsets = isFullScreen
                ? NSEdgeInsets(top: 0, left: -4, bottom: 2, right: 0)
                : backdropView === primaryBackdropView
                    ? defaultBackdropEdgeInsets
                    : nil
            {
                backdropView.setValue(
                    NSValue(edgeInsets: edgeInsets),
                    forKey: edgeInsetsKey
                )
            }
        }
    }

    private func configureFullSizeGlassLayers(in glassSurface: NSGlassEffectView) {
        guard let rootLayer = glassSurface.layer else { return }
        let targetSize = glassSurface.bounds.size
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        var layers = [rootLayer]
        var activeLayerIdentifiers = Set<ObjectIdentifier>()
        var index = 0

        while index < layers.count {
            let layer = layers[index]
            index += 1
            layers.append(contentsOf: layer.sublayers ?? [])

            let fillsSurface =
                abs(layer.bounds.width - targetSize.width) < 1
                && abs(layer.bounds.height - targetSize.height) < 1
            guard fillsSurface else { continue }

            let identifier = ObjectIdentifier(layer)
            activeLayerIdentifiers.insert(identifier)
            if layerCornerRadiusObservations[identifier] == nil {
                layerCornerRadiusObservations[identifier] = layer.observe(
                    \.cornerRadius,
                    options: [.new]
                ) { observedLayer, _ in
                    guard observedLayer.cornerRadius != 0 else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    observedLayer.cornerRadius = 0
                    CATransaction.commit()
                }
            }

            if layer.cornerRadius != 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.cornerRadius = 0
                CATransaction.commit()
                layer.setNeedsDisplay()
            }
        }

        let staleLayerIdentifiers = layerCornerRadiusObservations.keys.filter {
            !activeLayerIdentifiers.contains($0)
        }
        for identifier in staleLayerIdentifiers {
            layerCornerRadiusObservations.removeValue(forKey: identifier)?
                .invalidate()
        }
    }

    @available(macOS 26.0, *)
    private func setCornerRadiusToZero(on glassSurface: NSGlassEffectView) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            glassSurface.cornerRadius = 0
        }
    }

    private func setBackdropCornerRadiusToZero(
        on backdropView: NSView,
        key: String
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            backdropView.setValue(
                NSNumber(value: 0),
                forKey: key
            )
        }
    }
}
