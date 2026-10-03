import SwiftUI

struct LaunchSplashModifier: ViewModifier {
    @AppStorage(LaunchSplashPreferences.viewedKey) private var hasViewed = false

    func body(content: Content) -> some View {
        let isPresented = LaunchSplashPreferences.shouldShow(
            hasViewed: hasViewed,
            now: Date()
        )

        content
            .disabled(isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    LaunchSplashView {
                        hasViewed = true
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: hasViewed)
    }
}

struct LaunchSplashView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image("WorkspaceLaunchSplash")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Chat on one side. Work on the other.")
                .accessibilityValue(
                    "Open websites, documents, code and a terminal right next to your chat. "
                        + "Open a tab beside the chat. Tabs are saved with the chat and survive restarts. "
                        + "Click Annotate, then an element on the page to attach it to your message. "
                        + "Pick Worktree for a project chat to give it its own branch. "
                        + "Close it and the work stays; delete it and a snapshot is kept for recovery."
                )

            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("launchSplashContinue")
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .textSelection(.disabled)
        .compositingGroup()
    }
}

#Preview("Launch splash") {
    LaunchSplashView(onContinue: {})
        .frame(width: 1240, height: 720)
}

#Preview("Launch splash — minimum window") {
    LaunchSplashView(onContinue: {})
        .frame(width: 1040, height: 600)
}
