import SwiftUI

struct LaunchSplashModifier: ViewModifier {
    @AppStorage(LaunchSplashPreferences.viewedKey) private var hasViewed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isPresented = LaunchSplashPreferences.shouldShow(hasViewed: hasViewed, now: Date())

        content
            .disabled(isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    LaunchSplashView { hasViewed = true }
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hasViewed)
    }
}

struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedIndex = 0
    @State private var elapsed: TimeInterval = 0
    @State private var isHoveringPoints = false
    @State private var hasAppeared = false
    @FocusState private var continueIsFocused: Bool

    let onContinue: () -> Void

    private static let duration: TimeInterval = 6
    private let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.7)
    private var isPlaying: Bool { !isHoveringPoints && scenePhase == .active }

    var body: some View {
        GeometryReader { geometry in
            let scale: CGFloat = geometry.size.width < 1000 || geometry.size.height < 640 ? 0.85 : 1
            ZStack {
                Color(red: 11 / 255, green: 10 / 255, blue: 8 / 255)
                    .opacity(hasAppeared ? 0.5 : 0)
                    .ignoresSafeArea()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: hasAppeared)

                sheet
                    .scaleEffect(scale * (hasAppeared || reduceMotion ? 1 : 0.98))
                    .offset(y: hasAppeared || reduceMotion ? 0 : 8)
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.32),
                        value: hasAppeared
                    )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .environment(\.colorScheme, .dark)
        .textSelection(.disabled)
        .background {
            // Register Escape independently of keyboard focus inside the card.
            Button("Dismiss update", action: onContinue)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
        .compositingGroup()
        .onAppear {
            hasAppeared = true
            continueIsFocused = true
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
                let now = ContinuousClock.now
                let delta = last.duration(to: now).components
                last = now
                elapsed += Double(delta.seconds) + Double(delta.attoseconds) / 1e18
                if elapsed >= Self.duration {
                    select((selectedIndex + 1) % LaunchSplashFeature.allCases.count)
                }
            }
        }
    }

    private var sheet: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 32)

                VStack(spacing: 4) {
                    ForEach(LaunchSplashFeature.allCases) { feature in
                        featureButton(feature)
                    }
                }
                .onHover { isHoveringPoints = $0 }

                Spacer(minLength: 0)

                Button("Continue", action: onContinue)
                    .buttonStyle(LaunchSplashContinueStyle())
                    .keyboardShortcut(.defaultAction)
                    .focused($continueIsFocused)
                    .accessibilityIdentifier("launchSplashContinue")
            }
            .frame(width: 332, height: 504, alignment: .topLeading)
            .offset(x: 32, y: 64)

            LaunchSplashMedia(feature: LaunchSplashFeature.allCases[selectedIndex])
                .frame(width: 540, height: 584)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08))
                }
                .offset(x: 412, y: 8)
                .animation(reduceMotion ? nil : easeOut, value: selectedIndex)
        }
        .frame(width: 960, height: 600, alignment: .topLeading)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What's new in Nativ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            LaunchSplashNewBadge().padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                Text("Chat on one side.").frame(height: 40)
                Text("Work on the other.").frame(height: 40)
            }
            .font(.system(size: 38, weight: .medium))
            .tracking(0.37)
            .foregroundStyle(.white)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text("Websites, documents, code and a terminal right next to your chat. You and the model work in the same pane.")
                .font(.system(size: 15))
                .tracking(-0.3)
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureButton(_ feature: LaunchSplashFeature) -> some View {
        let selected = feature.rawValue == selectedIndex
        return Button {
            select(feature.rawValue)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 15, weight: .medium))
                    .tracking(-0.3)
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.45))
                    .frame(height: 20)

                if selected {
                    Text(feature.detail)
                        .font(.system(size: 13))
                        .tracking(-0.26)
                        .lineSpacing(1)
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.12))
                        .overlay(alignment: .top) {
                            Color.white
                                .frame(height: geometry.size.height * (selected ? min(elapsed / Self.duration, 1) : 0))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                }
                .frame(width: 2)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feature.title)
        .accessibilityValue(selected ? feature.detail : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(
            reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.36),
            value: selectedIndex
        )
    }

    private func select(_ index: Int) {
        selectedIndex = index
        elapsed = 0
    }
}

private enum LaunchSplashFeature: Int, CaseIterable, Identifiable {
    case tabs, annotate, worktrees

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tabs: "Open a tab beside the chat"
        case .annotate: "Point at what you mean"
        case .worktrees: "Give each chat its own branch"
        }
    }

    var detail: String {
        switch self {
        case .tabs: "Browse a site, edit a doc or code, or run commands. Tabs are saved with the chat and survive restarts."
        case .annotate: "Click Annotate, then any element on the page. It’s attached to your message, with the details the model needs."
        case .worktrees: "Pick Worktree for a project chat. Close it and the work stays; delete it and a snapshot is kept for recovery."
        }
    }

    // Normalized screenshot regions from the prototype.
    var region: CGRect {
        switch self {
        case .tabs: CGRect(x: 0.372, y: 0.05, width: 0.628, height: 0.95)
        case .annotate: CGRect(x: 0, y: 0.47, width: 0.64, height: 0.52)
        case .worktrees: CGRect(x: 0, y: 0.055, width: 0.37, height: 0.07)
        }
    }
}

private struct LaunchSplashMedia: View {
    let feature: LaunchSplashFeature

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let imageWidth = size.width - 64
            let imageHeight = imageWidth * 1711 / 1800
            let region = feature.region
            let zoom = min(
                (size.width - 64) / (region.width * imageWidth),
                (size.height - 64) / (region.height * imageHeight),
                2.6
            )

            ZStack(alignment: .topLeading) {
                // CSS background-position: 30% 50%, with a cover fit.
                let backgroundWidth = size.height * 1344 / 896
                Image("WorkspaceLaunchBackground")
                    .resizable()
                    .frame(width: backgroundWidth, height: size.height)
                    .offset(x: (size.width - backgroundWidth) * 0.3)

                Image("WorkspaceLaunchScreenshot")
                    .resizable()
                    .frame(width: imageWidth, height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: imageWidth * 0.0172))
                    .overlay {
                        RoundedRectangle(cornerRadius: imageWidth * 0.0172)
                            .strokeBorder(.white.opacity(0.08))
                    }
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(
                        x: size.width / 2 - region.midX * imageWidth * zoom,
                        y: size.height / 2 - region.midY * imageHeight * zoom
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nativ chat with a webpage open beside it, showing \(feature.title.lowercased()).")
    }
}

private struct LaunchSplashNewBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("New")
            .font(.system(size: 13, weight: .semibold))
            .tracking(-0.26)
            .foregroundStyle(Color(red: 106 / 255, green: 174 / 255, blue: 1))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Color(red: 0.037, green: 0.113, blue: 0.167), in: Capsule())
            .background {
                border.blur(radius: 8).opacity(0.6).padding(-2)
            }
            .overlay { border }
    }

    private var border: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 300 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 6) * 60
            Capsule().strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .white.opacity(0.12), location: 0),
                        .init(color: Color(red: 0, green: 145 / 255, blue: 1), location: 50 / 360),
                        .init(color: Color(red: 106 / 255, green: 174 / 255, blue: 1), location: 80 / 360),
                        .init(color: .white.opacity(0.12), location: 140 / 360),
                        .init(color: .white.opacity(0.12), location: 1),
                    ],
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 1
            )
        }
        .accessibilityHidden(true)
    }
}

private struct LaunchSplashContinueStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .tracking(-0.3)
            .foregroundStyle(Color(red: 14 / 255, green: 14 / 255, blue: 15 / 255))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(isHovering ? Color(white: 0.855) : .white, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Product update") {
    LaunchSplashView(onContinue: {})
        .frame(width: 1240, height: 720)
}

#Preview("Product update — small window") {
    LaunchSplashView(onContinue: {})
        .frame(width: 1040, height: 600)
}
