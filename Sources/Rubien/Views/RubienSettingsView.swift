import SwiftUI
import RubienCore
import RubienSync

@available(macOS 14.0, *)
struct RubienSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var cacheBytes: Int64 = 0
    @State private var backfillRemaining: Int = 0
    /// Latched at the start of an upload session so the indicator can render
    /// as "Uploading 4 of 31 PDFs to iCloud". Cleared back to nil when the
    /// queue reaches 0 so the next upload session re-latches with its own
    /// initial count rather than dividing by a stale denominator.
    @State private var initialBackfillCount: Int? = nil

    private let pdfAssetCache = PDFAssetCache(
        db: AppDatabase.shared,
        storageRoot: AppDatabase.pdfStorageURL
    )

    var body: some View {
        TabView {
            iCloudSyncPane
                .tabItem {
                    Label(
                        String(localized: "iCloud Sync", bundle: .module),
                        systemImage: "icloud"
                    )
                }
        }
        .frame(width: 480, height: 320)
    }

    @ViewBuilder
    private var iCloudSyncPane: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Sync library via iCloud", bundle: .module),
                    isOn: coordinator.toggleBinding
                )
                .confirmationDialog(
                    String(localized: "Enable iCloud Sync?", bundle: .module),
                    isPresented: Binding(
                        get: { coordinator.pendingConfirm },
                        set: { if !$0 { coordinator.cancelConfirm() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Enable Sync", bundle: .module)) {
                        coordinator.confirmEnable()
                    }
                    Button(String(localized: "Not Now", bundle: .module), role: .cancel) {
                        coordinator.cancelConfirm()
                    }
                } message: {
                    Text(String(
                        localized: "This will upload your library to iCloud and keep it in sync with other Macs on the same account. You can turn it off anytime, which stops syncing but keeps your local library intact.",
                        bundle: .module
                    ))
                }

                HStack {
                    Text(String(localized: "PDF cache", bundle: .module))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                if let initial = initialBackfillCount, initial > 0, backfillRemaining > 0 {
                    let done = max(0, initial - backfillRemaining)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(initial == 1
                            ? String(format: String(localized: "Uploading %d of %d PDF to iCloud", bundle: .module), done, initial)
                            : String(format: String(localized: "Uploading %d of %d PDFs to iCloud", bundle: .module), done, initial))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(done), total: Double(initial))
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await refreshCacheStatsLoop()
            }

            if case .unavailable = coordinator.status {
                Section {
                    Button(String(localized: "Try again", bundle: .module)) {
                        Task { await coordinator.retryStartSync() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// One-shot read of cache size + queue depth, then poll every 2s while
    /// the queue is non-empty so the indicator updates as the drainer makes
    /// progress. Stops polling once the queue is empty (or the task is
    /// cancelled, e.g. when the Settings window closes).
    ///
    /// `initialBackfillCount` is latched the first poll where the queue is
    /// non-empty, then cleared when the queue empties — so the indicator
    /// renders as "Uploading 4 of 31 PDFs" with a real progress bar, and a
    /// future upload session re-latches with its own denominator instead of
    /// reusing a stale one.
    private func refreshCacheStatsLoop() async {
        repeat {
            cacheBytes = (try? await pdfAssetCache.totalCacheSize()) ?? 0
            let count = (try? AppDatabase.shared.pdfUploadQueueCount()) ?? 0
            if initialBackfillCount == nil, count > 0 {
                initialBackfillCount = count
            }
            backfillRemaining = count
            if count == 0 {
                initialBackfillCount = nil
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        } while !Task.isCancelled
    }

    private var statusCaption: String {
        switch coordinator.status {
        case .disabled:
            return String(localized: "Off — local library only.", bundle: .module)
        case .unavailable(let reason):
            return String(format: String(localized: "Sync unavailable: %@", bundle: .module), reason)
        case .signedOut:
            return String(localized: "Not signed in to iCloud on this Mac.", bundle: .module)
        case .idle:
            return String(localized: "Syncing via iCloud.", bundle: .module)
        case .syncing:
            return String(localized: "Syncing in progress…", bundle: .module)
        case .error(let err):
            return String(format: String(localized: "Sync error: %@", bundle: .module), err.localizedDescription)
        }
    }
}
