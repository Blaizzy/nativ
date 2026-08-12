import AppKit
import Carbon.HIToolbox
import Charts
import SwiftUI
import Textual

private enum AudioDestination: String, CaseIterable, Identifiable {
    case overview
    case record
    case history
    case model
    case animation
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "Record"
        case .overview: "Overview"
        case .history: "Library"
        case .model: "Model"
        case .animation: "Animation"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
        case .overview: "square.grid.2x2"
        case .history: "books.vertical"
        case .model: "cpu"
        case .animation: "sparkles"
        case .shortcuts: "keyboard"
        }
    }
}

private enum AudioAnimationPurpose {
    case dictation
    case recording
}

@MainActor
struct AudioView: View {
    @ObservedObject var model: NativModel
    @ObservedObject private var analytics: AudioAnalyticsStore
    @ObservedObject private var shortcuts: VoiceShortcutPreferences
    @ObservedObject private var animations: VoiceAnimationPreferences
    @ObservedObject private var sounds: VoiceSoundPreferences
    @ObservedObject private var captureLibrary: AudioCaptureLibrary
    @StateObject private var localLibrary = LocalModelLibrary()
    @StateObject private var inputDevices = AudioInputDevicePreferences.shared
    @StateObject private var inputLevelMonitor = AudioInputLevelMonitor()
    @StateObject private var inputVolume = AudioInputVolumeController()
    @AppStorage(AudioCapturePreferences.automaticallySummarizeKey)
    private var automaticallySummarize = true
    @AppStorage(AudioCapturePreferences.includeSystemAudioKey)
    private var includeSystemAudio = true
    @AppStorage(AudioCapturePreferences.suggestMeetingTranscriptionKey)
    private var suggestMeetingTranscription = false
    @State private var searchText = ""
    @State private var editingShortcut: AudioShortcutKind?
    @State private var shortcutConflict: String?
    @State private var destination: AudioDestination = .record
    @State private var pendingDeleteDictation: AudioTranscriptionRecord?
    @State private var pendingDeleteRecording: AudioTranscriptionRecord?
    @State private var hoveredActivity: AudioDailyUsage?
    @State private var isConfirmingClearAllDictations = false

    let titleLeadingInset: CGFloat
    let onOpenSpeechModels: () -> Void

    init(
        model: NativModel,
        captureLibrary: AudioCaptureLibrary,
        analytics: AudioAnalyticsStore? = nil,
        shortcuts: VoiceShortcutPreferences? = nil,
        animations: VoiceAnimationPreferences? = nil,
        sounds: VoiceSoundPreferences? = nil,
        titleLeadingInset: CGFloat = 0,
        onOpenSpeechModels: @escaping () -> Void
    ) {
        self.model = model
        _captureLibrary = ObservedObject(wrappedValue: captureLibrary)
        self.titleLeadingInset = titleLeadingInset
        self.onOpenSpeechModels = onOpenSpeechModels
        _analytics = ObservedObject(wrappedValue: analytics ?? .shared)
        _shortcuts = ObservedObject(wrappedValue: shortcuts ?? .shared)
        _animations = ObservedObject(wrappedValue: animations ?? .shared)
        _sounds = ObservedObject(wrappedValue: sounds ?? .shared)
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
            handleViewAppear()
        }
        .onChange(of: model.settings.localModelSearchPaths) { _, _ in
            refreshLocalModels()
        }
        .onChange(of: inputDevices.selectedDeviceID) { _, _ in
            inputVolume.refresh(deviceUniqueID: inputDevices.effectiveDeviceID)
            Task {
                await inputLevelMonitor.start(
                    deviceUniqueID: inputDevices.effectiveDeviceID
                )
            }
        }
        .onChange(of: captureLibrary.phase) { _, phase in
            if phase == .idle {
                startInputMonitoringIfNeeded()
            } else {
                inputLevelMonitor.stop()
            }
        }
        .onChange(of: destination) { _, destination in
            handleDestinationChange(destination)
        }
        .onDisappear {
            inputLevelMonitor.stop()
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
        .alert(
            "Audio Capture",
            isPresented: Binding(
                get: { captureLibrary.lastErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        captureLibrary.clearLastError()
                    }
                }
            )
        ) {
            if captureLibrary.shouldOfferScreenCaptureSettings {
                Button("Open System Settings") {
                    captureLibrary.clearLastError()
                    NativSystemPermissionController.openScreenCaptureSettings()
                }
                Button("Not Now", role: .cancel) {
                    captureLibrary.clearLastError()
                }
            } else {
                Button("OK", role: .cancel) {
                    captureLibrary.clearLastError()
                }
            }
        } message: {
            Text(captureLibrary.lastErrorMessage ?? "Audio capture failed.")
        }
        .alert(
            "Delete dictation?",
            isPresented: Binding(
                get: { pendingDeleteDictation != nil },
                set: { if !$0 { pendingDeleteDictation = nil } }
            ),
            presenting: pendingDeleteDictation
        ) { record in
            Button("Delete", role: .destructive) {
                deleteDictation(record)
                pendingDeleteDictation = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteDictation = nil
            }
        } message: { _ in
            Text("The transcript and any retained audio will be permanently deleted.")
        }
        .alert(
            "Clear all recent dictations?",
            isPresented: $isConfirmingClearAllDictations
        ) {
            Button("Clear All", role: .destructive) {
                clearAllDictations()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All locally stored dictation transcripts and retained dictation audio will be permanently deleted.")
        }
        .alert(
            "Delete recording?",
            isPresented: Binding(
                get: { pendingDeleteRecording != nil },
                set: { if !$0 { pendingDeleteRecording = nil } }
            ),
            presenting: pendingDeleteRecording
        ) { record in
            Button("Delete", role: .destructive) {
                captureLibrary.delete(record)
                pendingDeleteRecording = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteRecording = nil
            }
        } message: { record in
            Text("“\(record.displayTitle)” and its saved audio, transcript, and summary will be permanently deleted.")
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio")
                    .font(.title2.weight(.semibold))
                Text("Record audio and use local speech models across your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                captureLibrary.revealLibrary()
            } label: {
                Label("Audio Library", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 20)
        .padding(.bottom, 16)
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
        case .record:
            AudioPage(
                title: "Record audio",
                subtitle: "Capture audio from your Mac and turn it into searchable text",
                maxContentWidth: 1_120
            ) {
                audioInputPanel
                captureControls
                capturePrivacyPanel
            }
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
                title: "Audio library",
                subtitle: "Review persistent recordings alongside dictation history"
            ) {
                savedCapturesPanel
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
            columns: Array(
                repeating: GridItem(
                    .flexible(minimum: 170),
                    spacing: 14,
                    alignment: .top
                ),
                count: 4
            ),
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
                Chart {
                    ForEach(dailyUsage) { item in
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
                        .opacity(
                            hoveredActivity == nil || hoveredActivity?.id == item.id
                                ? 1
                                : 0.42
                        )
                    }

                    if let hoveredActivity {
                        RuleMark(
                            x: .value("Hovered day", hoveredActivity.date, unit: .day)
                        )
                        .foregroundStyle(Color.secondary.opacity(0.28))
                        .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        .annotation(
                            position: .top,
                            spacing: 8,
                            overflowResolution: .init(
                                x: .fit(to: .chart),
                                y: .disabled
                            )
                        ) {
                            AudioActivityTooltip(item: hoveredActivity)
                        }
                    }
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
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    updateHoveredActivity(
                                        at: location,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                case .ended:
                                    hoveredActivity = nil
                                }
                            }
                    }
                }
                .frame(height: 230)
            }
        }
        .padding(18)
        .audioPanelStyle()
    }

    private var audioInputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "mic.and.signal.meter.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio source")
                        .font(.headline)
                    Text("Choose your microphone and verify its level before recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(audioInputStatusColor)
                        .frame(width: 7, height: 7)
                    Text(audioInputStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .padding(18)

            Divider()

            HStack(spacing: 16) {
                Text("Microphone")
                    .font(.callout.weight(.medium))
                    .frame(width: 112, alignment: .leading)

                Menu {
                    Button {
                        inputDevices.selectedDeviceID = AudioInputDevicePreferences.systemDefaultID
                    } label: {
                        if inputDevices.selectedDeviceID.isEmpty {
                            Label("System Default", systemImage: "checkmark")
                        } else {
                            Text("System Default")
                        }
                    }

                    if !inputDevices.devices.isEmpty {
                        Divider()
                    }

                    ForEach(inputDevices.devices) { device in
                        Button {
                            inputDevices.selectedDeviceID = device.id
                        } label: {
                            if inputDevices.selectedDeviceID == device.id {
                                Label(device.name, systemImage: "checkmark")
                            } else if device.isSystemDefault {
                                Text("\(device.name) (Default)")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(inputDevices.selectionTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: 280, maxWidth: 420, minHeight: 28, alignment: .leading)
                }
                .menuStyle(.button)
                .controlSize(.large)
                .disabled(captureLibrary.isBusy)

                Button {
                    inputDevices.refresh()
                    inputVolume.refresh(
                        deviceUniqueID: inputDevices.effectiveDeviceID
                    )
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh audio devices")
                .disabled(captureLibrary.isBusy)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider()

            HStack(spacing: 16) {
                Text("Input volume")
                    .font(.callout.weight(.medium))
                    .frame(width: 112, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(inputVolume.volume) },
                        set: { inputVolume.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .frame(width: 312)
                .disabled(!inputVolume.isSupported || captureLibrary.isBusy)
                .help(
                    inputVolume.isSupported
                        ? "Adjust the selected microphone's input volume"
                        : "This microphone controls input volume in hardware"
                )

                Text("\(Int((inputVolume.volume * 100).rounded()))%")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityLabel("Input volume")
                    .accessibilityValue("\(Int((inputVolume.volume * 100).rounded())) percent")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text("Input level")
                        .font(.callout.weight(.medium))
                        .frame(width: 112, alignment: .leading)
                    inputLevelMeter
                    Spacer(minLength: 0)
                }

                if let errorMessage = inputLevelMonitor.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 128)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                Text("System audio")
                    .font(.callout.weight(.medium))
                    .frame(width: 112, alignment: .leading)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(Color.blue)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(includeSystemAudio ? "Included in recordings" : "Microphone only")
                        .font(.callout.weight(.medium))
                    Text(
                        includeSystemAudio
                            ? "Recordings include audio playing in other apps."
                            : "Recordings use only your selected microphone."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("Include system audio", isOn: $includeSystemAudio)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(captureLibrary.isBusy)
                    .accessibilityLabel("Include system audio in recordings")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .audioPanelStyle(cornerRadius: 16)
    }

    private var captureControls: some View {
        Group {
            if captureLibrary.phase == .idle {
                unifiedCaptureCard
            } else {
                activeCapturePanel
            }
        }
    }

    private var unifiedCaptureCard: some View {
        let tint = Color.blue

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(
                        tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("New recording")
                        .font(.headline)
                    Text("Capture audio, then transcribe it locally when you finish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button {
                    inputLevelMonitor.stop()
                    Task {
                        await captureLibrary.start(
                            .meeting,
                            automaticallySummarize: automaticallySummarize,
                            includeSystemAudio: includeSystemAudio
                        )
                    }
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 164)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.large)
            }

            Divider()
                .padding(.vertical, 16)

            HStack(alignment: .center, spacing: 20) {
                capturePreferenceRow(
                    title: "Auto-summary",
                    detail: "Create summarized notes automatically after each recording.",
                    systemImage: "sparkles",
                    tint: .purple,
                    isOn: $automaticallySummarize,
                    accessibilityLabel: "Create summarized notes automatically"
                )

                Divider()
                    .frame(height: 52)

                capturePreferenceRow(
                    title: "Transcription suggestions",
                    detail: "Prompt me when a supported meeting app begins using the microphone.",
                    systemImage: "person.2.wave.2.fill",
                    tint: tint,
                    isOn: $suggestMeetingTranscription,
                    accessibilityLabel: "Suggest transcription when a meeting starts"
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.065), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        }
    }

    private var activeCapturePanel: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 64, height: 64)
                if captureLibrary.phase == .recording {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let pulse = (sin(
                            timeline.date.timeIntervalSinceReferenceDate * 3.2
                        ) + 1) / 2
                        Circle()
                            .fill(Color.red)
                            .frame(
                                width: 18 + (pulse * 5),
                                height: 18 + (pulse * 5)
                            )
                            .shadow(color: .red.opacity(0.5), radius: 8 + (pulse * 4))
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(activeCaptureTitle)
                    .font(.headline)
                Text(activeCaptureDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if captureLibrary.phase == .recording {
                    Text(formatDuration(captureLibrary.elapsed))
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
            }

            Spacer()

            if captureLibrary.phase == .recording {
                Button {
                    Task {
                        await captureLibrary.deleteCurrentRecording()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task {
                        await captureLibrary.restart()
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task {
                        await captureLibrary.stop()
                    }
                } label: {
                    Label("Complete", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            Color.red.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        }
    }

    private var inputLevelMeter: some View {
        AudioInputLevelMeterView(
            captureMeter: captureLibrary.meterState,
            monitorMeter: inputLevelMonitor.meterState,
            isRecording: captureLibrary.phase == .recording
        )
    }

    private var audioInputStatus: String {
        switch captureLibrary.phase {
        case .recording:
            "Recording"
        case .preparing:
            "Preparing"
        case .processing:
            "Processing"
        case .idle:
            if inputLevelMonitor.errorMessage != nil {
                "Unavailable"
            } else if inputLevelMonitor.isMonitoring {
                "Input active"
            } else {
                "Connecting"
            }
        }
    }

    private var audioInputStatusColor: Color {
        if captureLibrary.phase == .recording {
            return .red
        }
        if inputLevelMonitor.errorMessage != nil {
            return .orange
        }
        return inputLevelMonitor.isMonitoring ? .green : .secondary
    }

    private var activeCaptureTitle: String {
        switch captureLibrary.phase {
        case .idle:
            "Ready"
        case .preparing:
            "Preparing \(captureLibrary.activeKind?.title.lowercased() ?? "recording")…"
        case .recording:
            "Recording \(captureLibrary.activeKind?.title.lowercased() ?? "audio")"
        case .processing:
            "Saving and transcribing…"
        }
    }

    private var activeCaptureDetail: String {
        switch captureLibrary.phase {
        case .idle:
            ""
        case .preparing:
            "Waiting for the required macOS permissions and audio devices."
        case .recording:
            if captureLibrary.activeKind == .meeting,
               captureLibrary.activeIncludesSystemAudio
            {
                "System audio and \(inputDevices.selectionTitle) are being captured."
            } else {
                "Recording from \(inputDevices.selectionTitle)."
            }
        case .processing:
            "The recording is safely stored locally while your speech model creates text."
        }
    }

    private var capturePrivacyPanel: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("Recordings stay on your Mac until you delete them. Dictation audio expires automatically after five minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Private by default")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 4)
    }

    private func capturePreferenceRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        isOn: Binding<Bool>,
        accessibilityLabel: String
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(
                    tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            Toggle(accessibilityLabel, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(captureLibrary.isBusy)
                .accessibilityLabel(accessibilityLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcription model")
                        .font(.headline)
                    Text("This model handles voice dictation everywhere you use Nativ.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 8) {
                Text("Model selection")
                    .font(.subheadline.weight(.semibold))
                Text("Choose a specific installed model, or let Nativ pick the first compatible one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if localLibrary.isScanning && speechModels.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Scanning installed models…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                } else {
                    speechModelMenu
                }
            }

            Divider()
                .padding(.vertical, 18)

            speechModelStatus
        }
        .padding(20)
        .audioPanelStyle()
    }

    private var speechModelMenu: some View {
        Menu {
            speechModelMenuButton(title: "Automatic", modelID: "")

            if let selectedModelID,
               !speechModels.contains(where: { $0.repoID == selectedModelID })
            {
                speechModelMenuButton(title: selectedModelID, modelID: selectedModelID)
            }

            if !speechModels.isEmpty {
                Divider()
            }

            ForEach(speechModels) { localModel in
                speechModelMenuButton(
                    title: localModel.displayName,
                    modelID: localModel.repoID
                )
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedModelID == nil ? "wand.and.stars" : "cpu")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(speechModelSelectionTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if model.modelSwitchInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .menuStyle(.button)
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.modelSwitchInProgress)
    }

    @ViewBuilder
    private var speechModelStatus: some View {
        if speechModels.isEmpty && !localLibrary.isScanning {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("No speech model found")
                        .font(.subheadline.weight(.semibold))
                    Text("Download or add a compatible model to a configured local model path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Find models", action: onOpenSpeechModels)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.orange.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        } else if let effectiveSpeechModel {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.green.opacity(0.35), radius: 4)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.modelSwitchInProgress ? "Switching model…" : "Active model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(effectiveSpeechModel.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(
                        selectedModelID == nil
                            ? "Selected automatically from your local model library."
                            : "Selected manually for all voice dictation."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
    }

    private func speechModelMenuButton(
        title: String,
        modelID: String
    ) -> some View {
        Button {
            speechModelSelection.wrappedValue = modelID
        } label: {
            HStack {
                Text(title)
                if (selectedModelID ?? "") == modelID {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var animationPicker: some View {
        VStack(alignment: .leading, spacing: 28) {
            animationSection(
                title: "Voice dictation",
                subtitle: "Shown while you dictate text with a global shortcut.",
                styles: VoiceAnimationPreferences.dictationStyles,
                purpose: .dictation
            )

            Divider()

            animationSection(
                title: "Recordings",
                subtitle: "Shown while audio keeps recording across apps.",
                styles: VoiceAnimationPreferences.recordingStyles,
                purpose: .recording
            )

            Label(
                "Notch styles appear around the camera on supported MacBooks. Other displays use a centered pill at the top of the screen.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            soundPicker
        }
    }

    private var soundPicker: some View {
        let selectedStyle = sounds.selectedStyle

        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sounds")
                    .font(.headline)
                Text("Choose the start and finish cues used across all audio capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 38, height: 38)
                        .background(
                            Color.blue.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Capture sound")
                            .font(.headline)
                        Text("Used for voice dictation and recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)
                }

                HStack(spacing: 10) {
                    Menu {
                        ForEach(VoiceCaptureSoundStyle.allCases) { style in
                            Button {
                                sounds.selectedStyle = style
                            } label: {
                                HStack {
                                    Label(
                                        style.title,
                                        systemImage: style.systemImage
                                    )
                                    if selectedStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 0) {
                            Image(systemName: selectedStyle.systemImage)
                                .frame(width: 14, alignment: .center)
                            Text(selectedStyle.title)
                                .padding(.leading, 14)
                        }
                    }
                    .menuStyle(.button)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        VoiceCaptureSoundPlayer.preview.playStart(
                            style: selectedStyle
                        )
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedStyle == .none)
                }

                Text(selectedStyle.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
            }
        }
    }

    private func animationSection(
        title: String,
        subtitle: String,
        styles: [VoiceCaptureAnimationStyle],
        purpose: AudioAnimationPurpose
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(styles) { style in
                    animationCard(style, purpose: purpose)
                }
            }
        }
    }

    private func animationCard(
        _ style: VoiceCaptureAnimationStyle,
        purpose: AudioAnimationPurpose
    ) -> some View {
        let isSelected = selectedAnimationStyle(for: purpose) == style
        let previewHeight: CGFloat = purpose == .recording ? 180 : 112

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                selectAnimationStyle(style, for: purpose)
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if purpose == .recording {
                        recordingAnimationPreview(style)
                    } else {
                        animationPreview(style)
                    }
                }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: previewHeight,
                        maxHeight: previewHeight
                    )
                    .background(
                        Color.black.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(animationTitle(for: style, purpose: purpose))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(animationSubtitle(for: style, purpose: purpose))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(animationLocation(for: style, purpose: purpose))
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
                        systemName: isSelected
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        isSelected
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
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedAnimationStyle(
        for purpose: AudioAnimationPurpose
    ) -> VoiceCaptureAnimationStyle {
        purpose == .dictation
            ? animations.selectedStyle
            : animations.recordingStyle
    }

    private func selectAnimationStyle(
        _ style: VoiceCaptureAnimationStyle,
        for purpose: AudioAnimationPurpose
    ) {
        if purpose == .dictation {
            animations.selectedStyle = style
        } else {
            animations.recordingStyle = style
        }
    }

    private func animationTitle(
        for style: VoiceCaptureAnimationStyle,
        purpose: AudioAnimationPurpose
    ) -> String {
        guard purpose == .recording else {
            return style.title
        }
        return switch style {
        case .notchShelf:
            "Notch Recorder"
        case .verticalRecorder:
            "Side Recorder"
        case .cursorWaveform, .gradientIsland:
            "Floating Recorder"
        }
    }

    private func animationSubtitle(
        for style: VoiceCaptureAnimationStyle,
        purpose: AudioAnimationPurpose
    ) -> String {
        guard purpose == .recording else {
            return style.subtitle
        }
        return switch style {
        case .notchShelf:
            "Widens the MacBook notch with the Nativ mark and recording controls."
        case .verticalRecorder:
            "A vertical live meter you can drag anywhere along your screen."
        case .cursorWaveform, .gradientIsland:
            "A compact Nativ recording pill with restart, delete, and finish controls."
        }
    }

    private func animationLocation(
        for style: VoiceCaptureAnimationStyle,
        purpose: AudioAnimationPurpose
    ) -> String {
        guard purpose == .recording else {
            return style.locationLabel
        }
        return switch style {
        case .notchShelf:
            "Around camera"
        case .verticalRecorder:
            "Movable · right side"
        case .cursorWaveform, .gradientIsland:
            "Top of screen"
        }
    }

    private func recordingAnimationPreview(
        _ style: VoiceCaptureAnimationStyle
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(time * 2.2) + 1) / 2
            let level = Float(0.24 + (pulse * 0.56))

            ZStack(alignment: .top) {
                if style == .notchShelf {
                    recordingNotchPreview(level: level)
                } else if style == .verticalRecorder {
                    recordingVerticalPreview(level: level)
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    recordingPillPreview(level: level)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 180,
                maxHeight: 180
            )
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(recordingPreviewBackground(for: style))
            }
        }
    }

    private func recordingPreviewBackground(
        for style: VoiceCaptureAnimationStyle
    ) -> LinearGradient {
        switch style {
        case .verticalRecorder, .cursorWaveform:
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.025, green: 0.035, blue: 0.055),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .gradientIsland:
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.08),
                    Color(red: 0.02, green: 0.12, blue: 0.14),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .notchShelf:
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.18, blue: 0.21),
                    Color(red: 0.06, green: 0.08, blue: 0.1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func recordingPillPreview(level: Float) -> some View {
        HStack(spacing: 7) {
            recordingMarkPreview(level: level)
            Text("0:08")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .frame(width: 36, alignment: .trailing)
            recordingControlPreview("arrow.counterclockwise", tint: .white)
            recordingControlPreview("trash.fill", tint: .white.opacity(0.72))
            recordingControlPreview("stop.fill", tint: .red)
        }
        .padding(.horizontal, 10)
        .frame(width: 226, height: 46)
        .background(Color.black.opacity(0.96), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func recordingNotchPreview(level: Float) -> some View {
        ZStack {
            VoiceWideNotchShape(
                shoulderWidth: 3,
                shoulderDepth: 4,
                bottomCornerRadius: 11
            )
            .fill(Color.black.opacity(0.985))

            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    recordingMarkPreview(level: level)
                    recordingControlPreview("arrow.counterclockwise", tint: .white)
                    recordingControlPreview(
                        "trash.fill",
                        tint: .white.opacity(0.72)
                    )
                }
                .frame(width: 96)

                Color.clear.frame(width: 78)

                HStack(spacing: 6) {
                    Text("0:08")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.76))
                    recordingControlPreview("stop.fill", tint: .red)
                }
                .frame(width: 78)
            }
        }
        .frame(width: 252, height: 38)
    }

    private func recordingVerticalPreview(level: Float) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))
                .frame(height: 8)
                .padding(.bottom, 5)

            NativAudioCaptureMark(
                kind: .meeting,
                state: .recording,
                level: level
            )
            .frame(width: 24, height: 24)
            .padding(.bottom, 6)

            VoiceVerticalLiveWaveform(level: level, isRecording: true)
                .frame(width: 28, height: 52)
                .clipped()
                .padding(.bottom, 6)

            Text("0:08")
                .font(
                    .system(
                        size: 8,
                        weight: .semibold,
                        design: .monospaced
                    )
                )
                .foregroundStyle(.white.opacity(0.76))
                .frame(height: 9)
                .padding(.bottom, 5)

            VStack(spacing: 3) {
                recordingCompactControlPreview(
                    "arrow.counterclockwise",
                    tint: .white
                )
                recordingCompactControlPreview("stop.fill", tint: .red)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 58, height: 166)
        .background(
            Color.black.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.7)
        }
    }

    private func recordingCompactControlPreview(
        _ systemImage: String,
        tint: Color
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 15, height: 15)
            .background(tint.opacity(0.14), in: Circle())
    }

    private func recordingMarkPreview(level: Float) -> some View {
        NativAudioCaptureMark(
            kind: .meeting,
            state: .recording,
            level: level
        )
        .frame(width: 24, height: 24)
    }

    private func recordingControlPreview(
        _ systemImage: String,
        tint: Color
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.14), in: Circle())
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

                ZStack {
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
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
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
        case .verticalRecorder:
            recordingVerticalPreview(level: 0.62)
        }
    }

    private var handsFreeDescription: String {
        guard shortcuts.isHandsFreeEnabled else {
            return "Hold while speaking; release to transcribe."
        }
        return shortcuts.recordShortcut.keyCode == nil
            ? "Tap once to start; tap again to transcribe."
            : "Press once to start; press again to transcribe."
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
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hands-free")
                            .font(.callout.weight(.medium))
                        Text(handsFreeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Toggle("Hands-free", isOn: $shortcuts.isHandsFreeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(10)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

                shortcutRow(
                    title: "Dictation shortcut",
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
                Button("Clear All", role: .destructive) {
                    isConfirmingClearAllDictations = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .disabled(dictationRecords.isEmpty)
                .help("Delete all recent dictations")

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
                        AudioTranscriptRow(
                            record: record,
                            onDelete: { pendingDeleteDictation = record }
                        )
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

    private var savedCapturesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recordings")
                        .font(.headline)
                    Text("Persistent audio, raw transcripts, and local summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    destination = .record
                } label: {
                    Label("New recording", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if captureRecords.isEmpty {
                ContentUnavailableView {
                    Label("No saved recordings", systemImage: "waveform.badge.plus")
                } description: {
                    Text("Start a recording to create your local audio library.")
                } actions: {
                    Button("Record audio") {
                        destination = .record
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(captureRecords) { record in
                        AudioCaptureRecordRow(
                            record: record,
                            audioIsAvailable: captureLibrary.audioURL(for: record) != nil,
                            isProcessing: captureLibrary.processingRecordIDs.contains(record.id),
                            isPlaying: captureLibrary.playingRecordID == record.id
                                && !captureLibrary.isPlaybackPaused,
                            isPaused: captureLibrary.playingRecordID == record.id
                                && captureLibrary.isPlaybackPaused,
                            onPlay: { captureLibrary.togglePlayback(for: record) },
                            onStop: { captureLibrary.stopPlayback() },
                            onReveal: { captureLibrary.revealAudio(for: record) },
                            onTranscribe: { captureLibrary.retryTranscription(record) },
                            onSummarize: { captureLibrary.summarize(record) },
                            onRename: { analytics.updateTitle($0, for: record.id) },
                            onDelete: { pendingDeleteRecording = record }
                        )
                    }
                }
            }
        }
        .padding(18)
        .audioPanelStyle()
    }

    private func shortcutRow(
        title: String,
        subtitle: String? = nil,
        shortcut: VoiceShortcut,
        kind: AudioShortcutKind
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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

    private func updateHoveredActivity(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredActivity = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredActivity = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        guard let date: Date = proxy.value(atX: plotX) else {
            hoveredActivity = nil
            return
        }

        let nextActivity = dailyUsage.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        guard hoveredActivity != nextActivity else { return }
        hoveredActivity = nextActivity
    }

    private var filteredRecords: [AudioTranscriptionRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return dictationRecords
        }
        return dictationRecords.filter { record in
            record.transcript.localizedCaseInsensitiveContains(query)
                || record.applicationName?.localizedCaseInsensitiveContains(query) == true
                || record.modelID?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var dictationRecords: [AudioTranscriptionRecord] {
        analytics.records.filter { $0.resolvedKind == .dictation }
    }

    private var captureRecords: [AudioTranscriptionRecord] {
        analytics.records.filter { $0.resolvedKind != .dictation }
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

    private var speechModelSelectionTitle: String {
        guard let selectedModelID else {
            return "Automatic"
        }
        return speechModels.first { $0.repoID == selectedModelID }?.displayName
            ?? selectedModelID
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

    private func handleViewAppear() {
        switch destination {
        case .record:
            refreshLocalModels()
            inputDevices.refresh()
            inputVolume.refresh(deviceUniqueID: inputDevices.effectiveDeviceID)
            startInputMonitoringIfNeeded()
        case .model:
            refreshLocalModels()
        case .overview, .history:
            importExistingTranscripts()
        case .animation, .shortcuts:
            break
        }
    }

    private func handleDestinationChange(_ destination: AudioDestination) {
        switch destination {
        case .record:
            refreshLocalModels()
            inputVolume.refresh(deviceUniqueID: inputDevices.effectiveDeviceID)
            startInputMonitoringIfNeeded()
        case .model:
            refreshLocalModels()
            inputLevelMonitor.stop()
        case .overview, .history:
            importExistingTranscripts()
            inputLevelMonitor.stop()
        case .animation, .shortcuts:
            inputLevelMonitor.stop()
        }
    }

    private func refreshLocalModels() {
        localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
    }

    private func startInputMonitoringIfNeeded() {
        guard destination == .record, captureLibrary.phase == .idle else {
            return
        }
        Task {
            await inputLevelMonitor.start(
                deviceUniqueID: inputDevices.effectiveDeviceID
            )
        }
    }

    private func importExistingTranscripts() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        analytics.importTranscripts(in: directory)
    }

    private func deleteDictation(_ record: AudioTranscriptionRecord) {
        captureLibrary.stopPlaybackIfPlaying(record.id)
        analytics.deleteDictation(
            withID: record.id,
            recordingsDirectory: try? VoiceAudioRecorder.recordingsDirectory
        )
    }

    private func clearAllDictations() {
        analytics.deleteAllDictations(
            recordingsDirectory: try? VoiceAudioRecorder.recordingsDirectory
        )
        searchText = ""
    }

    private func apply(_ shortcut: VoiceShortcut, to kind: AudioShortcutKind) {
        let assignments: [(AudioShortcutKind, VoiceShortcut)] = [
            (.record, shortcuts.recordShortcut),
            (.retry, shortcuts.retryShortcut),
        ]
        guard !assignments.contains(where: {
            $0.0 != kind && $0.1 == shortcut
        }) else {
            NSSound.beep()
            shortcutConflict = "That shortcut is already assigned to another action."
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct AudioInputLevelMeterView: View {
    @ObservedObject var captureMeter: AudioInputLevelState
    @ObservedObject var monitorMeter: AudioInputLevelState
    let isRecording: Bool

    private var displayedLevel: Float {
        isRecording ? captureMeter.level : monitorMeter.level
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<16, id: \.self) { index in
                let threshold = Float(index + 1) / 16
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        displayedLevel >= threshold
                            ? segmentColor(at: index)
                            : Color.secondary.opacity(0.18)
                    )
                    .frame(width: 12, height: 30)
                    .animation(.linear(duration: 0.08), value: displayedLevel)
            }
        }
        .frame(maxWidth: 312, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(displayedLevel * 100)) percent")
    }

    private func segmentColor(at index: Int) -> Color {
        switch index {
        case 0..<11:
            .accentColor
        case 11..<14:
            .orange
        default:
            .red
        }
    }
}

private enum AudioShortcutKind: String, Identifiable {
    case record
    case retry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "Dictation shortcut"
        case .retry: "Retry shortcut"
        }
    }
}

private struct AudioPage<Content: View>: View {
    let title: String
    let subtitle: String
    let maxContentWidth: CGFloat
    let content: Content

    init(
        title: String,
        subtitle: String,
        maxContentWidth: CGFloat = 1_500,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

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
            .frame(maxWidth: maxContentWidth, alignment: .leading)
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

private struct AudioActivityTooltip: View {
    let item: AudioDailyUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.semibold))

            HStack(spacing: 6) {
                Text("\(item.words.formatted()) words")
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(item.sessions) \(item.sessions == 1 ? "dictation" : "dictations")")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .fixedSize()
    }
}

private struct AudioTitleDoubleClickTarget: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let recognizer = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick)
        )
        recognizer.numberOfClicksRequired = 2
        recognizer.buttonMask = 0x1
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func handleDoubleClick() {
            action()
        }
    }
}

private struct InlineEditableAudioTitle: View {
    let title: String
    let placeholder: String
    let font: Font
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var editorHasReceivedFocus = false
    @FocusState private var titleFieldIsFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(font)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 420)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                    }
                    .focused($titleFieldIsFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand(perform: cancelEditing)
            } else if title.isEmpty {
                Text("Add title")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: beginEditing)
                    .help("Add a title")
            } else {
                Text(title)
                    .font(font)
                    .padding(.vertical, 2)
                    .textSelection(.disabled)
                    .overlay {
                        AudioTitleDoubleClickTarget(action: beginEditing)
                    }
                    .help("Double-click to rename")
            }
        }
        .onChange(of: titleFieldIsFocused) { _, isFocused in
            if isFocused {
                editorHasReceivedFocus = true
            } else if isEditing, editorHasReceivedFocus {
                saveTitle()
            }
        }
    }

    private func beginEditing() {
        draftTitle = title
        editorHasReceivedFocus = false
        isEditing = true
        DispatchQueue.main.async {
            titleFieldIsFocused = true
        }
    }

    private func saveTitle() {
        guard isEditing else { return }
        let normalizedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        editorHasReceivedFocus = false
        titleFieldIsFocused = false
        if !normalizedTitle.isEmpty, normalizedTitle != title {
            onRename(normalizedTitle)
        }
    }

    private func cancelEditing() {
        isEditing = false
        editorHasReceivedFocus = false
        titleFieldIsFocused = false
    }
}

private struct AudioTranscriptRow: View {
    let record: AudioTranscriptionRecord
    let onDelete: () -> Void
    @State private var copied = false
    @State private var isDeleteHovering = false

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

            HStack(spacing: 4) {
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

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    isDeleteHovering
                                        ? Color.red.opacity(0.13)
                                        : Color.clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
                .help("Delete dictation")
                .accessibilityLabel("Delete dictation")
                .onHover { isDeleteHovering = $0 }
            }
        }
        .padding(.vertical, 12)
    }

    private var metadataSeparator: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }
}

private struct AudioCaptureRecordRow: View {
    let record: AudioTranscriptionRecord
    let audioIsAvailable: Bool
    let isProcessing: Bool
    let isPlaying: Bool
    let isPaused: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onReveal: () -> Void
    let onTranscribe: () -> Void
    let onSummarize: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var selectedDetail: DetailSection?
    @State private var copiedDetail: DetailSection?
    @State private var hoveredDetail: DetailSection?

    private enum DetailSection: Hashable {
        case summary
        case transcript

        var title: String {
            switch self {
            case .summary: "Summary"
            case .transcript: "Transcript"
            }
        }

        var systemImage: String {
            switch self {
            case .summary: "sparkles"
            case .transcript: "text.alignleft"
            }
        }

        var tint: Color {
            switch self {
            case .summary: .primary
            case .transcript: .primary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.resolvedKind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(record.resolvedKind == .dictation ? Color.secondary : Color.blue)
                    .frame(width: 36, height: 36)
                    .background(
                        (record.resolvedKind == .dictation ? Color.secondary : Color.blue)
                            .opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    InlineEditableAudioTitle(
                        title: record.displayTitle,
                        placeholder: "\(record.resolvedKind.title) title",
                        font: .callout.weight(.semibold),
                        onRename: onRename
                    )
                    HStack(spacing: 7) {
                        Text(record.resolvedKind.title)
                        Text("·")
                        Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        if let duration = record.durationSeconds {
                            Text("·")
                            Text(Self.formatDuration(duration))
                        }
                        if !record.transcript.isEmpty {
                            Text("·")
                            Text("\(record.wordCount) words")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isProcessing {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(record.transcript.isEmpty ? "Transcribing" : "Summarizing")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button(action: onPlay) {
                    Label(
                        isPlaying ? "Pause" : (isPaused ? "Resume" : "Play"),
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!audioIsAvailable)

                if isPlaying || isPaused {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .labelStyle(.iconOnly)
                    .help("Stop playback")
                }

                if record.transcript.isEmpty && !isProcessing {
                    Button("Transcribe", action: onTranscribe)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!audioIsAvailable)
                }

                Menu {
                    if !record.transcript.isEmpty {
                        Button("Copy transcript", action: copyTranscript)
                        if let summary = record.summary, !summary.isEmpty {
                            Button("Copy summary") {
                                copy(summary, detail: .summary)
                            }
                        }
                        Button(
                            record.summary?.isEmpty == false
                                ? "Regenerate summary"
                                : "Generate summary",
                            action: onSummarize
                        )
                        .disabled(isProcessing)
                    }
                    Divider()
                    Button("Reveal in Finder", action: onReveal)
                        .disabled(!audioIsAvailable)
                    Button("Delete recording", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !record.transcript.isEmpty {
                VStack(spacing: 0) {
                    detailMenu

                    if let selectedDetail {
                        Divider()
                            .padding(.horizontal, 12)

                        detailContent(selectedDetail)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 11))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }

            if record.transcript.isEmpty && !isProcessing {
                Label(
                    "Audio saved without a transcript. You can keep or delete the recording.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var detailMenu: some View {
        HStack(spacing: 5) {
            detailButton(.summary)
            detailButton(.transcript)
            Spacer(minLength: 8)

            if selectedDetail != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedDetail = nil
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Collapse details")
            }
        }
        .padding(6)
    }

    private func detailButton(_ detail: DetailSection) -> some View {
        let isSelected = selectedDetail == detail
        let isHovered = hoveredDetail == detail
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedDetail = isSelected ? nil : detail
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: detail.systemImage)
                    .font(.caption.weight(.semibold))

                Text(detail.title)
                    .font(.callout.weight(.semibold))

                if detail == .summary, record.summary?.isEmpty != false {
                    Text(isProcessing ? "Working" : "Create")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (isSelected ? Color.white : Color.purple).opacity(0.14),
                            in: Capsule()
                        )
                } else if detail == .transcript {
                    Text(record.wordCount.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            isSelected ? Color.white.opacity(0.78) : Color.primary.opacity(0.42)
                        )
                }
            }
            .foregroundStyle(isSelected ? Color.white : detail.tint)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(
                isSelected
                    ? Color.accentColor
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredDetail = hovering ? detail : nil
            }
        }
    }

    @ViewBuilder
    private func detailContent(_ detail: DetailSection) -> some View {
        switch detail {
        case .summary:
            if let summary = record.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    detailHeader(
                        title: "AI-generated notes",
                        detail: .summary,
                        text: summary
                    )

                    ScrollView {
                        StructuredText(
                            markdown: NativMarkdownFormatting.normalizedMathDelimiters(in: summary),
                            syntaxExtensions: [.math]
                        )
                        .textual.structuredTextStyle(.gitHub)
                        .textual.textSelection(.enabled)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 360)
                }
                .padding(14)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.purple)
                        .frame(width: 34, height: 34)
                        .background(Color.purple.opacity(0.1), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isProcessing ? "Creating your summary" : "Create a concise summary")
                            .font(.callout.weight(.semibold))
                        Text("Turn this transcript into structured notes, decisions, and action items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Generate", action: onSummarize)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(14)
            }

        case .transcript:
            VStack(alignment: .leading, spacing: 10) {
                detailHeader(
                    title: "Verbatim transcript · \(record.wordCount.formatted()) words",
                    detail: .transcript,
                    text: record.transcript
                )

                ScrollView {
                    Text(record.transcript)
                        .font(.body)
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            .padding(14)
        }
    }

    private func detailHeader(
        title: String,
        detail: DetailSection,
        text: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                copy(text, detail: detail)
            } label: {
                Label(
                    copiedDetail == detail ? "Copied" : "Copy",
                    systemImage: copiedDetail == detail ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func copyTranscript() {
        copy(record.transcript, detail: .transcript)
    }

    private func copy(_ text: String, detail: DetailSection) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDetail = detail
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedDetail == detail {
                copiedDetail = nil
            }
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
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
