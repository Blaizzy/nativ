import SwiftUI

struct ChatWorktreeRecoveryView: View {
    @ObservedObject var chat: ChatViewModel
    let onOpenChat: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [ChatWorktreeSnapshot] = []
    @State private var isLoading = true
    @State private var busyID: UUID?
    @State private var pendingDelete: ChatWorktreeSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recently deleted worktrees").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshots.isEmpty {
                ContentUnavailableView("No saved worktrees", systemImage: "archivebox",
                    description: Text("Deleting a worktree chat saves a recoverable snapshot here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshots) { snapshot in
                            snapshotRow(snapshot)
                            Divider()
                        }
                    }.padding(24)
                }
            }
            Divider()
            Text("Restore opens the saved files in a new chat. Chat messages and ignored files aren’t included. Snapshots stay here until you permanently delete them.")
                .font(.callout).foregroundStyle(.secondary).padding(24)
        }
        .frame(width: 680, height: 500)
        .disabled(busyID != nil)
        .interactiveDismissDisabled(busyID != nil)
        .task { await reload() }
        .alert("Permanently delete snapshot?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete permanently", role: .destructive) {
                guard let snapshot = pendingDelete else { return }
                pendingDelete = nil
                Task { await remove(snapshot) }
            }
        } message: {
            Text("The saved snapshot of “\(pendingDelete?.title ?? "Worktree")” will be removed. This cannot be undone. Any restored checkout will be kept.")
        }
        .alert("Couldn’t complete worktree recovery", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func snapshotRow(_ snapshot: ChatWorktreeSnapshot) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title).font(.headline).lineLimit(1)
                Text(URL(fileURLWithPath: snapshot.worktree.repositoryPath).lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary)
                Text(snapshot.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                if !snapshot.ignoredFiles.isEmpty {
                    Text("Ignored files excluded").font(.caption).foregroundStyle(.secondary)
                        .help(snapshot.ignoredFiles.joined(separator: "\n"))
                }
            }
            Spacer(minLength: 8)
            if busyID == snapshot.id { ProgressView().controlSize(.small) }
            Button("Restore") { Task { await restore(snapshot) } }.buttonStyle(.bordered)
            Menu {
                Button("Delete permanently", systemImage: "trash", role: .destructive) { pendingDelete = snapshot }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Options for \(snapshot.title)")
        }
    }

    private func reload() async {
        let store = chat.worktreeRecoveryStore
        do { snapshots = try await Task.detached { try store.snapshots() }.value }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func restore(_ snapshot: ChatWorktreeSnapshot) async {
        busyID = snapshot.id
        defer { busyID = nil }
        do {
            let id = try await chat.restoreWorktreeSnapshot(snapshot.id)
            dismiss()
            onOpenChat(id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ snapshot: ChatWorktreeSnapshot) async {
        busyID = snapshot.id
        defer { busyID = nil }
        do {
            try await chat.permanentlyDeleteWorktreeSnapshot(snapshot.id)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}
