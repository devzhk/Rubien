import SwiftUI
import RubienCore
import RubienSync

@available(macOS 14.0, *)
struct RubienSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var cacheBytes: Int64 = 0
    @State private var backfillRemaining: Int = 0

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

                if backfillRemaining > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(backfillRemaining == 1
                            ? String(localized: "Uploading 1 PDF to iCloud…", bundle: .module)
                            : String(format: String(localized: "Uploading %d PDFs to iCloud…", bundle: .module), backfillRemaining))
                            .foregroundStyle(.secondary)
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
    private func refreshCacheStatsLoop() async {
        repeat {
            cacheBytes = (try? await pdfAssetCache.totalCacheSize()) ?? 0
            backfillRemaining = (try? AppDatabase.shared.pdfUploadQueueCount()) ?? 0
            if backfillRemaining == 0 { break }
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
