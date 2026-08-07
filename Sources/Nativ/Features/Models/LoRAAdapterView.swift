import SwiftUI

struct LoRAAdapterSheet: View {
    @ObservedObject var model: NativModel
    @ObservedObject var catalog: LoRAAdapterCatalog
    let baseModelID: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = HuggingFaceLoRAAdapterLibrary()
    @StateObject private var downloadManager = LoRAAdapterDownloadManager()
    @ObservedObject private var sizeStore = HuggingFaceLoRAAdapterSizeStore.shared
    @State private var query = ""
    @State private var adapterPendingDeletion: InstalledLoRAAdapter?
    @State private var deletionError: String?

    var body: some View {
        let snapshot = listSnapshot

        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search LoRA adapters on Hugging Face", text: $query)
                    .textFieldStyle(.plain)
                if library.isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let error = library.error {
                        adapterNotice(error)
                    }
                    if let error = downloadManager.error {
                        adapterNotice(error)
                    }
                    if let deletionError {
                        adapterNotice(deletionError)
                    }

                    if !snapshot.updates.isEmpty {
                        adapterSectionHeader(
                            "Updates",
                            systemImage: "arrow.triangle.2.circlepath",
                            count: snapshot.updates.count
                        )
                        ForEach(snapshot.updates) { update in
                            let item = update.available
                            hubAdapterRow(
                                item,
                                actionTitle: "Update",
                                actionDisabled: activeReference == update.installed.reference
                            )
                        }
                    }

                    adapterSectionHeader(
                        "Installed",
                        systemImage: "internaldrive.fill",
                        count: snapshot.installed.count
                    )
                    if snapshot.installed.isEmpty {
                        compactEmptyState(
                            "No installed adapters",
                            detail: "Adapters you install for this model will appear here."
                        )
                    } else {
                        ForEach(snapshot.installed) { adapter in
                            InstalledLoRAAdapterRow(
                                adapter: adapter,
                                sizeBytes: adapter.sizeBytes,
                                isActive: activeReference == adapter.reference,
                                isSwitching: model.runtimeTransitionInProgress
                                    || downloadManager.isDownloading,
                                isSwitchTarget: model.adapterSwitchInProgress
                                    && (
                                        model.adapterSwitchTargetID == adapter.reference.id
                                            || (model.adapterSwitchTargetID == nil
                                                && activeReference == adapter.reference)
                                    ),
                                operationFailure: operationFailure(for: adapter),
                                onActivate: {
                                    model.activateLanguageAdapter(
                                        adapter.reference,
                                        for: baseModelID
                                    )
                                },
                                onDisable: {
                                    model.activateLanguageAdapter(nil, for: baseModelID)
                                },
                                deleteDisabled: activeReference == adapter.reference
                                    || model.runtimeTransitionInProgress
                                    || downloadManager.isDownloading,
                                onDelete: {
                                    adapterPendingDeletion = adapter
                                }
                            )
                        }
                    }

                    adapterSectionHeader(
                        "Available on Hugging Face",
                        systemImage: "cloud.fill",
                        count: snapshot.available.count,
                        isLoading: library.isSearching && !library.adapters.isEmpty
                    )
                    if library.isSearching && library.adapters.isEmpty {
                        loadingState
                    } else if snapshot.available.isEmpty {
                        if !library.adapters.isEmpty && !snapshot.installed.isEmpty {
                            compactEmptyState(
                                "Everything shown is installed",
                                detail: "Search for another adapter or try a different model."
                            )
                        } else {
                            emptyState
                        }
                    } else {
                        ForEach(snapshot.available) { item in
                            hubAdapterRow(item, actionTitle: "Install")
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 600)
        .task(id: searchTaskID) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            library.search(
                baseModelID: baseModelID,
                query: query,
                token: model.effectiveHuggingFaceToken
            )
        }
        .onDisappear {
            library.cancel()
            downloadManager.cancel()
        }
        .confirmationDialog(
            "Delete \(adapterPendingDeletion?.displayName ?? "adapter")?",
            isPresented: deletionDialogIsPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Adapter", role: .destructive) {
                if let adapterPendingDeletion {
                    delete(adapterPendingDeletion)
                }
            }
            Button("Cancel", role: .cancel) {
                adapterPendingDeletion = nil
            }
        } message: {
            Text(
                "This removes the downloaded adapter files from this Mac. This cannot be undone."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text("LoRA Adapters")
                    .font(.title2.weight(.semibold))
                Text("Adapters declared for \(baseModelID)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private var installedCandidates: [InstalledLoRAAdapter] {
        catalog.adapters(for: baseModelID).filter {
            catalog.localURL(
                for: $0.reference,
                baseModelID: baseModelID
            ) != nil
        }
    }

    private var listSnapshot: LoRAAdapterListSnapshot {
        LoRAAdapterListSnapshot(
            installed: installedCandidates,
            remoteAdapters: library.adapters,
            activeReference: activeReference
        )
    }

    private var activeReference: HubLoRAAdapterReference? {
        model.settings.normalized().languageAdapter(for: baseModelID)
    }

    private func operationFailure(
        for adapter: InstalledLoRAAdapter
    ) -> AdapterOperationFailure? {
        guard let failure = model.modelLoadFailure,
              failure.modelID == baseModelID,
              case .languageAdapter(let reference, let operation) = failure.context,
              reference == adapter.reference
        else {
            return nil
        }
        let title: String
        switch operation {
        case .activate:
            title = "Can’t use with this model"
        case .deactivate:
            title = "Couldn’t disable this adapter"
        }
        return AdapterOperationFailure(title: title, message: failure.message)
    }

    private var searchTaskID: String {
        "\(baseModelID)|\(query)|\(credentialIdentity)"
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { adapterPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { adapterPendingDeletion = nil }
            }
        )
    }

    private var credentialIdentity: String {
        guard let info = HuggingFaceAuthentication.tokenInfo(
            model.effectiveHuggingFaceToken
        ) else { return "anonymous" }
        return "\(info.maskedValue)|\(info.characterCount)"
    }

    private func install(
        _ adapter: HuggingFaceLoRAAdapter,
        variant: LoRAAdapterArtifactVariant
    ) {
        let sizeBytes: Int64?
        switch sizeStore.state(for: variant.reference) {
        case .available(let size):
            sizeBytes = size
        case .idle, .loading, .unavailable:
            sizeBytes = nil
        }

        Task {
            _ = try? await downloadManager.install(
                adapter: adapter,
                variant: variant,
                baseModelID: baseModelID,
                token: model.effectiveHuggingFaceToken,
                sizeBytes: sizeBytes,
                catalog: catalog
            )
        }
    }

    private func hubAdapterRow(
        _ item: HuggingFaceLoRAAdapterListItem,
        actionTitle: String,
        actionDisabled: Bool = false
    ) -> some View {
        HubLoRAAdapterRow(
            adapter: item.adapter,
            variant: item.variant,
            actionTitle: actionTitle,
            isDownloading: downloadManager.activeReferenceID
                == item.variant.reference.id,
            downloadProgress: downloadManager.progress,
            downloadPhase: downloadManager.phase,
            downloadTotalBytes: downloadManager.totalBytes,
            isPaused: downloadManager.isPaused,
            sizeState: sizeStore.state(for: item.variant.reference),
            downloadDisabled: actionDisabled
                || downloadManager.isDownloading
                || ((item.adapter.isPrivate || item.adapter.isGated)
                    && model.effectiveHuggingFaceToken == nil),
            onInstall: { install(item.adapter, variant: item.variant) },
            onPause: { downloadManager.pause() },
            onResume: { downloadManager.resume() },
            onCancel: { downloadManager.cancel() }
        )
        .help(
            actionDisabled
                ? "Disable this adapter before updating it"
                : ""
        )
        .task(id: "\(item.variant.reference.id)|\(credentialIdentity)") {
            await sizeStore.load(
                adapter: item.adapter,
                variant: item.variant,
                token: model.effectiveHuggingFaceToken
            )
        }
    }

    private func delete(_ adapter: InstalledLoRAAdapter) {
        guard activeReference != adapter.reference else {
            deletionError = "Disable the active adapter before deleting it."
            adapterPendingDeletion = nil
            return
        }
        do {
            try catalog.delete(adapter.reference)
            deletionError = nil
            adapterPendingDeletion = nil
        } catch {
            deletionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            adapterPendingDeletion = nil
        }
    }

    private func adapterSectionHeader(
        _ title: String,
        systemImage: String,
        count: Int,
        isLoading: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Updating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private func compactEmptyState(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.secondary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func adapterNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
            )
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Finding declared adapters…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No declared adapters found")
                .font(.headline)
            Text(
                "Nativ shows repositories that declare this base model and contain a complete MLX or PEFT LoRA package."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
    }
}

private struct InstalledLoRAAdapterRow: View {
    let adapter: InstalledLoRAAdapter
    let sizeBytes: Int64
    let isActive: Bool
    let isSwitching: Bool
    let isSwitchTarget: Bool
    let operationFailure: AdapterOperationFailure?
    let onActivate: () -> Void
    let onDisable: () -> Void
    let deleteDisabled: Bool
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                selectionControl
                transitionStatus
                deleteButton
            }
            .padding(14)

            if let operationFailure {
                AdapterOperationErrorView(failure: operationFailure)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .modelRowBackground(isHighlighted: isActive, isHovered: isHovered)
    }

    private var selectionControl: some View {
        Button(action: toggleSelection) {
            HStack(spacing: 14) {
                adapterIcon
                adapterDetails
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(selectionHelp)
        .accessibilityLabel(selectionHelp)
    }

    private var adapterIcon: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 46, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isActive
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.secondary.opacity(0.10)
                    )
            )
    }

    private var adapterDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(adapter.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                }
            }
            Text(adapter.reference.repoID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(adapterMetadata)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transitionStatus: some View {
        if isSwitchTarget {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(isActive ? "Disabling…" : "Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deleteButton: some View {
        ModelRowActionButton(
            title: isActive
                ? "Disable this adapter before deleting it"
                : "Delete this adapter",
            systemImage: "trash",
            tint: .red,
            isDisabled: deleteDisabled,
            action: onDelete
        )
    }

    private var adapterMetadata: String {
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return "Rank \(adapter.rank) · \(adapter.tensorCount) tensors · \(size)"
    }

    private func toggleSelection() {
        guard !isSwitching else { return }
        if isActive {
            onDisable()
        } else {
            onActivate()
        }
    }

    private var selectionHelp: String {
        isActive
            ? "Disable \(adapter.displayName)"
            : "Use \(adapter.displayName)"
    }
}

private struct AdapterOperationFailure {
    let title: String
    let message: String
}

private struct AdapterOperationErrorView: View {
    let failure: AdapterOperationFailure

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.red.opacity(0.10)))

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.title)
                    .font(.caption.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.red.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.red.opacity(0.16), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(failure.title): \(failure.message)")
    }
}

private struct HubLoRAAdapterRow: View {
    let adapter: HuggingFaceLoRAAdapter
    let variant: LoRAAdapterArtifactVariant
    let actionTitle: String
    let isDownloading: Bool
    let downloadProgress: Double
    let downloadPhase: LoRAAdapterDownloadManager.InstallPhase?
    let downloadTotalBytes: Int64?
    let isPaused: Bool
    let sizeState: HuggingFaceArtifactSizeState
    let downloadDisabled: Bool
    let onInstall: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(variant.formatLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.10)))
                    if adapter.isGated {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(adapter.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 12) {
                    Label(compact(adapter.downloads), systemImage: "arrow.down.circle")
                    Label(compact(adapter.likes), systemImage: "heart")
                    sizeLabel
                    Text(String(adapter.sha.prefix(8))).monospaced()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloading {
                VStack(alignment: .trailing, spacing: 6) {
                    if downloadPhase?.showsDeterminateProgress == true,
                       downloadProgress > 0 {
                        ProgressView(value: downloadProgress)
                            .frame(width: 170)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 170, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(downloadPhase?.description ?? "Preparing download…")
                            if downloadPhase?.showsDeterminateProgress == true {
                                Text(progressDescription)
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            if isPaused {
                                onResume()
                            } else {
                                onPause()
                            }
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(isPaused ? "Resume download" : "Pause download")
                        .accessibilityLabel(isPaused ? "Resume download" : "Pause download")
                        .disabled(downloadPhase?.showsDeterminateProgress != true)

                        Button(action: onCancel) {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .help("Stop download")
                        .accessibilityLabel("Stop download")
                    }
                    .frame(width: 220)
                }
            } else {
                Button(actionTitle, action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .disabled(downloadDisabled)
                    .frame(width: 220, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(minHeight: 78)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var displayName: String {
        adapter.id.split(separator: "/").last.map(String.init) ?? adapter.id
    }

    @ViewBuilder
    private var sizeLabel: some View {
        Group {
            switch sizeState {
            case .idle, .loading:
                Label("Loading size…", systemImage: "internaldrive")
            case .available(let size):
                Label(
                    ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    systemImage: "internaldrive"
                )
            case .unavailable:
                Label("Size unavailable", systemImage: "internaldrive")
            }
        }
        .frame(minWidth: 102, alignment: .leading)
    }

    private var progressPercentage: Int {
        Int((min(max(downloadProgress, 0), 1) * 100).rounded())
    }

    private var progressPercentageText: String {
        let percentage = min(max(downloadProgress, 0), 1) * 100
        if percentage > 0, percentage < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", percentage)
    }

    private var progressDescription: String {
        guard let downloadTotalBytes, downloadTotalBytes > 0 else {
            return "\(progressPercentage)%"
        }
        let downloadedBytes = Int64(
            (Double(downloadTotalBytes) * min(max(downloadProgress, 0), 1)).rounded()
        )
        let downloaded = ByteCountFormatter.string(
            fromByteCount: downloadedBytes,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: downloadTotalBytes,
            countStyle: .file
        )
        return "\(downloaded) of \(total) · \(progressPercentageText)"
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
                .replacingOccurrences(of: ".0M", with: "M")
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
                .replacingOccurrences(of: ".0K", with: "K")
        }
        return String(value)
    }
}
