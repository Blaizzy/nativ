import AppKit
import Carbon.HIToolbox
import Charts
import SwiftUI

private enum AudioDestination: String, CaseIterable, Identifiable {
    case overview
    case history
    case model
    case animation
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .history: "History"
        case .model: "Model"
        case .animation: "Animation"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .model: "cpu"
        case .animation: "sparkles"
        case .shortcuts: "keyboard"
        }
    }
}

@MainActor
struct AudioView: View {
    @ObservedObject var model: NativModel
    @ObservedObject private var analytics: AudioAnalyticsStore
    @ObservedObject private var shortcuts: VoiceShortcutPreferences
    @ObservedObject private var animations: VoiceAnimationPreferences
    @StateObject private var localLibrary = LocalModelLibrary()
    @State private var searchText = ""
    @State private var editingShortcut: AudioShortcutKind?
    @State private var shortcutConflict: String?
    @State private var destination: AudioDestination = .overview

    let titleLeadingInset: CGFloat
    let onOpenSpeechModels: () -> Void

    init(
        model: NativModel,
        analytics: AudioAnalyticsStore? = nil,
        shortcuts: VoiceShortcutPreferences? = nil,
        animations: VoiceAnimationPreferences? = nil,
        titleLeadingInset: CGFloat = 0,
        onOpenSpeechModels: @escaping () -> Void
    ) {
        self.model = model
        self.titleLeadingInset = titleLeadingInset
        self.onOpenSpeechModels = onOpenSpeechModels
        _analytics = ObservedObject(wrappedValue: analytics ?? .shared)
        _shortcuts = ObservedObject(wrappedValue: shortcuts ?? .shared)
        _animations = ObservedObject(wrappedValue: animations ?? .shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()
            destinationBar
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nativMainContentBackground)
        .onAppear {
            refreshLocalModels()
            importExistingTranscripts()
        }
        .onChange(of: model.settings.modelSearchPath) { _, _ in
            refreshLocalModels()
        }
        .onChange(of: model.settings.additionalModelSearchPaths) { _, _ in
            refreshLocalModels()
        }
        .sheet(item: $editingShortcut) { kind in
            ShortcutCaptureSheet(
                kind: kind,
                conflictMessage: shortcutConflict,
                onCapture: { shortcut in
                    apply(shortcut, to: kind)
                },
                onCancel: {
                    editingShortcut = nil
                    shortcutConflict = nil
                }
            )
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio")
                    .font(.title2.weight(.semibold))
                Text("Track local dictation activity and tune how voice input works across your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                openRecordingsDirectory()
            } label: {
                Label("Transcripts", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 28)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var destinationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(AudioDestination.allCases) { item in
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
            AudioPage(
                title: "Overview",
                subtitle: "Your local dictation activity at a glance"
            ) {
                metricGrid
                activityPanel
            }
        case .history:
            AudioPage(
                title: "History",
                subtitle: "Search, review, and reuse transcripts stored on this Mac"
            ) {
                recentDictationsPanel
            }
        case .model:
            AudioPage(
                title: "Speech-to-text model",
                subtitle: "Choose which installed model handles voice transcription"
            ) {
                modelConfigurationPanel
                    .frame(maxWidth: 760)
            }
        case .animation:
            AudioPage(
                title: "Animation",
                subtitle: "Choose how active voice capture appears across your Mac"
            ) {
                animationPicker
            }
        case .shortcuts:
            AudioPage(
                title: "Keyboard shortcuts",
                subtitle: "Customize the global commands for recording and retranscription"
            ) {
                shortcutConfigurationPanel
                    .frame(maxWidth: 760)
            }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            AudioMetricCard(
                title: "Average speed",
                value: analytics.averageWordsPerMinute.map {
                    "\(Int($0.rounded())) WPM"
                } ?? "—",
                detail: "Across timed dictations",
                systemImage: "speedometer",
                tint: .blue
            )
            AudioMetricCard(
                title: "Words dictated",
                value: analytics.totalWords.formatted(),
                detail: "\(analytics.records.count) sessions",
                systemImage: "text.word.spacing",
                tint: .purple
            )
            AudioMetricCard(
                title: "Time saved",
                value: formattedSavedTime,
                detail: "Compared with typing at 45 WPM",
                systemImage: "clock.arrow.circlepath",
                tint: .green
            )
            AudioMetricCard(
                title: "Current streak",
                value: "\(analytics.currentStreak) \(analytics.currentStreak == 1 ? "day" : "days")",
                detail: analytics.currentStreak == 0 ? "Start with a dictation" : "Keep it going",
                systemImage: "flame.fill",
                tint: .orange
            )
        }
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation activity")
                        .font(.headline)
                    Text("Words spoken over the last 14 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(recentWordCount.formatted()) words")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if analytics.records.isEmpty {
                ContentUnavailableView {
                    Label("No voice activity yet", systemImage: "waveform")
                } description: {
                    Text("Use \(shortcuts.recordShortcut.displayName) to record your first dictation.")
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Chart(dailyUsage) { item in
                    BarMark(
                        x: .value("Day", item.date, unit: .day),
                        y: .value("Words", item.words)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 230)
            }
        }
        .padding(18)
        .audioPanelStyle()
    }

    private var modelConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Speech-to-text model", systemImage: "cpu")
                    .font(.headline)
                Text("The selected model applies to dictation in every app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                if localLibrary.isScanning && speechModels.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning installed models…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 30)
                } else {
                    Picker("Speech-to-text model", selection: speechModelSelection) {
                        Text("Automatic").tag("")
                        if let selectedModelID,
                           !speechModels.contains(where: { $0.repoID == selectedModelID })
                        {
                            Text(selectedModelID).tag(selectedModelID)
                        }
                        ForEach(speechModels) { localModel in
                            Text(localModel.displayName).tag(localModel.repoID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(model.modelSwitchInProgress)
                }

                if speechModels.isEmpty && !localLibrary.isScanning {
                    Button("Find speech models", action: onOpenSpeechModels)
                        .buttonStyle(.link)
                } else if let effectiveSpeechModel {
                    Text("Using \(effectiveSpeechModel.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if model.modelSwitchInProgress {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Switching model and restarting the server…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Automatic uses the first compatible speech-to-text model found in your configured local model paths.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .audioPanelStyle()
    }

    private var animationPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(VoiceCaptureAnimationStyle.allCases) { style in
                    animationCard(style)
                }
            }

            Label(
                "Gradient Island wraps the camera in a pill. Wide Notch extends the physical cutout sideways without increasing its height. Displays without a cutout use the centered floating fallback.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func animationCard(
        _ style: VoiceCaptureAnimationStyle
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                animations.selectedStyle = style
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                animationPreview(style)
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .background(
                        Color.black.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(style.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(style.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(style.locationLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                Color.accentColor.opacity(0.1),
                                in: Capsule()
                            )
                            .padding(.top, 3)
                    }

                    Spacer(minLength: 8)

                    Image(
                        systemName: animations.selectedStyle == style
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        animations.selectedStyle == style
                            ? Color.accentColor
                            : Color.secondary
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        animations.selectedStyle == style
                            ? Color.accentColor
                            : Color.primary.opacity(0.08),
                        lineWidth: animations.selectedStyle == style ? 1.5 : 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            animations.selectedStyle == style ? .isSelected : []
        )
    }

    @ViewBuilder
    private func animationPreview(
        _ style: VoiceCaptureAnimationStyle
    ) -> some View {
        switch style {
        case .cursorWaveform:
            HStack(spacing: 9) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .shadow(color: .red.opacity(0.5), radius: 5)

                VoiceLiveWaveform(level: 0.62, isRecording: true)
                    .frame(width: 90, height: 32)

                Text("0:08")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.horizontal, 14)
            .frame(width: 184, height: 52)
            .background(Color.black, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
            }
        case .gradientIsland:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let voicePulse = (sin(time * 1.25) + 1) / 2
                let previewLevel = Float(0.16 + (voicePulse * 0.62))

                ZStack {
                    Capsule()
                        .fill(Color.cyan.opacity(0.08))
                        .frame(width: 230, height: 50)
                        .blur(radius: 12)

                    HStack(spacing: 0) {
                        VoiceGradientOrb(
                            level: previewLevel,
                            isRecording: true
                        )
                        .frame(width: 26, height: 26)
                        .frame(width: 48, height: 42)

                        Color.clear
                            .frame(width: 112, height: 42)

                        Text("0:08")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 54, height: 42)
                    }
                    .frame(width: 214, height: 42)
                    .background(Color.black, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.7)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.03, green: 0.05, blue: 0.08),
                                Color(red: 0.02, green: 0.12, blue: 0.14),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        case .notchShelf:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let voicePulse = (sin(time * 1.25) + 1) / 2
                let previewLevel = Float(0.16 + (voicePulse * 0.62))

                ZStack(alignment: .top) {
                    ZStack {
                        VoiceWideNotchShape(
                            shoulderWidth: 3,
                            shoulderDepth: 4,
                            bottomCornerRadius: 11
                        )
                            .fill(Color.black)

                        HStack(spacing: 0) {
                            VoiceGradientOrb(
                                level: previewLevel,
                                isRecording: true
                            )
                            .frame(width: 22, height: 22)
                            .frame(width: 50, height: 36)

                            Color.clear
                                .frame(width: 130, height: 36)

                            Text("0:08")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.78))
                                .frame(width: 50, height: 36)
                        }
                    }
                    .frame(width: 230, height: 36)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .top)
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.18, blue: 0.21),
                                Color(red: 0.06, green: 0.08, blue: 0.1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }

    private var shortcutConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Global voice shortcuts", systemImage: "keyboard")
                    .font(.headline)
                Text("Changes take effect immediately, including outside Nativ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(
                    title: "Record while held",
                    shortcut: shortcuts.recordShortcut,
                    kind: .record
                )
                shortcutRow(
                    title: "Retry recent audio",
                    shortcut: shortcuts.retryShortcut,
                    kind: .retry
                )
            }

            Text("Raw audio is deleted after five minutes. Transcript history and aggregate analytics stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .audioPanelStyle()
    }

    private var recentDictationsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent dictations")
                        .font(.headline)
                    Text("Search and reuse transcripts stored locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search transcripts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            if filteredRecords.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.isEmpty ? "No transcripts yet" : "No matching transcripts",
                        systemImage: searchText.isEmpty ? "text.badge.plus" : "magnifyingglass"
                    )
                } description: {
                    Text(
                        searchText.isEmpty
                            ? "Your completed voice dictations will appear here."
                            : "Try a different search."
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredRecords.prefix(30).enumerated()), id: \.element.id) {
                        index, record in
                        AudioTranscriptRow(record: record)
                        if index < min(filteredRecords.count, 30) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(18)
        .audioPanelStyle()
    }

    private func shortcutRow(
        title: String,
        shortcut: VoiceShortcut,
        kind: AudioShortcutKind
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(shortcut.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Spacer()
            Button("Change") {
                shortcutConflict = nil
                editingShortcut = kind
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button("Restore default") {
                    switch kind {
                    case .record:
                        shortcuts.resetRecordShortcut()
                    case .retry:
                        shortcuts.resetRetryShortcut()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var dailyUsage: [AudioDailyUsage] {
        analytics.dailyUsage(days: 14)
    }

    private var recentWordCount: Int {
        dailyUsage.reduce(0) { $0 + $1.words }
    }

    private var filteredRecords: [AudioTranscriptionRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return analytics.records
        }
        return analytics.records.filter { record in
            record.transcript.localizedCaseInsensitiveContains(query)
                || record.applicationName?.localizedCaseInsensitiveContains(query) == true
                || record.modelID?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var speechModels: [LocalModel] {
        localLibrary.models
            .filter { $0.capabilities.contains(.speechToText) }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private var selectedModelID: String? {
        model.settings.normalized().speechToTextModelID
    }

    private var effectiveSpeechModel: LocalModel? {
        let resolvedID = LocalModelDiscovery.speechToTextModelID(
            in: speechModels,
            selectedModelID: selectedModelID
        )
        return speechModels.first { $0.repoID == resolvedID }
    }

    private var speechModelSelection: Binding<String> {
        Binding(
            get: { selectedModelID ?? "" },
            set: { newValue in
                guard newValue != selectedModelID ?? "" else {
                    return
                }
                if newValue.isEmpty {
                    model.switchPreloadedModel(to: nil, for: .speechToText)
                } else if let localModel = speechModels.first(where: {
                    $0.repoID == newValue
                }) {
                    model.requestPreloadedModelSwitch(
                        to: localModel,
                        for: .speechToText,
                        availableModels: localLibrary.models
                    )
                }
            }
        )
    }

    private var formattedSavedTime: String {
        let seconds = analytics.estimatedTimeSaved
        if seconds < 60 {
            return "\(Int(seconds.rounded())) sec"
        }
        if seconds < 3_600 {
            return "\(Int((seconds / 60).rounded())) min"
        }
        return String(format: "%.1f hr", seconds / 3_600)
    }

    private func refreshLocalModels() {
        let settings = model.settings.normalized()
        localLibrary.scan(
            path: settings.modelSearchPath,
            additionalPaths: settings.additionalModelSearchPaths
        )
    }

    private func importExistingTranscripts() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        analytics.importTranscripts(in: directory)
    }

    private func openRecordingsDirectory() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func apply(_ shortcut: VoiceShortcut, to kind: AudioShortcutKind) {
        let otherShortcut =
            kind == .record ? shortcuts.retryShortcut : shortcuts.recordShortcut
        guard shortcut != otherShortcut else {
            NSSound.beep()
            shortcutConflict = "That shortcut is already assigned to the other action."
            return
        }

        switch kind {
        case .record:
            shortcuts.recordShortcut = shortcut
        case .retry:
            shortcuts.retryShortcut = shortcut
        }
        editingShortcut = nil
        shortcutConflict = nil
    }
}

private enum AudioShortcutKind: String, Identifiable {
    case record
    case retry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "Record shortcut"
        case .retry: "Retry shortcut"
        }
    }
}

private struct AudioPage<Content: View>: View {
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

private struct AudioMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .audioPanelStyle()
    }
}

private struct AudioTranscriptRow: View {
    let record: AudioTranscriptionRecord
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(record.transcript)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)

                HStack(spacing: 7) {
                    Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if let applicationName = record.applicationName {
                        metadataSeparator
                        Text(applicationName)
                    }
                    metadataSeparator
                    Text("\(record.wordCount) words")
                    if let wordsPerMinute = record.wordsPerMinute {
                        metadataSeparator
                        Text("\(Int(wordsPerMinute.rounded())) WPM")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.transcript, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(
                    copied ? "Copied" : "Copy",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 12)
    }

    private var metadataSeparator: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }
}

private struct ShortcutCaptureSheet: View {
    let kind: AudioShortcutKind
    let conflictMessage: String?
    let onCapture: (VoiceShortcut) -> Void
    let onCancel: () -> Void
    @State private var preview = "Press a shortcut"

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)

            VStack(spacing: 5) {
                Text(kind.title)
                    .font(.title3.weight(.semibold))
                Text("Hold modifier keys, or combine them with another key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(preview)
                .font(.headline)
                .frame(minWidth: 220, minHeight: 48)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Press Escape to cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ShortcutRecorderView(
                preview: $preview,
                onCapture: onCapture,
                onCancel: onCancel
            )
            .frame(width: 1, height: 1)

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 390)
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var preview: String
    let onCapture: (VoiceShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        configure(view)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        configure(nsView)
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    private func configure(_ view: ShortcutRecorderNSView) {
        view.onPreview = { value in
            preview = value
        }
        view.onCapture = onCapture
        view.onCancel = onCancel
    }
}

private final class ShortcutRecorderNSView: NSView {
    var onPreview: ((String) -> Void)?
    var onCapture: ((VoiceShortcut) -> Void)?
    var onCancel: (() -> Void)?
    private var pendingModifiers: VoiceShortcutModifiers = []

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        let modifiers = VoiceShortcutModifiers(eventFlags: event.modifierFlags)
        if modifiers.isEmpty {
            if !pendingModifiers.isEmpty {
                onCapture?(
                    VoiceShortcut(
                        keyCode: nil,
                        keyDisplay: nil,
                        modifiers: pendingModifiers
                    )
                )
                pendingModifiers = []
            }
            return
        }
        pendingModifiers = modifiers
        onPreview?(modifiers.displayParts.joined(separator: " + "))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        let modifiers = VoiceShortcutModifiers(eventFlags: event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            onPreview?("Include at least one modifier")
            return
        }
        let shortcut = VoiceShortcut(
            keyCode: event.keyCode,
            keyDisplay: VoiceShortcut.keyDisplay(for: event),
            modifiers: modifiers
        )
        onPreview?(shortcut.displayName)
        onCapture?(shortcut)
    }
}

private extension View {
    func audioPanelStyle(cornerRadius: CGFloat = 13) -> some View {
        background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
    }
}
