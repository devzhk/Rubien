import AppKit
import Combine
import SwiftUI
import RubienCore
import RubienSync

@main
struct RubienApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var syncCoordinator = SyncCoordinator(appDatabase: AppDatabase.shared)
    @State private var addinToast: AddinToastPayload?
    @AppStorage(RubienPreferences.appendYouTubeTranscriptOnClipKey) private var appendYouTubeTranscriptOnClip = false
    private static let defaultWindowSize = preferredDefaultWindowSize()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncCoordinator)
                .overlay(alignment: .top) {
                    if let toast = addinToast {
                        AddinToast(message: toast.message, tone: toast.tone)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .syncStatusBanner(status: syncCoordinator.status) {
                    Task { await syncCoordinator.retryStartSync() }
                }
                .task {
                    await syncCoordinator.startIfEnabled()
                }
                .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
                    let title = (note.userInfo?[RubienClipImportedKeys.title] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = String(localized: "Saved web clip", bundle: .module)
                    let fmt = String(localized: "Saved web clip: %@", bundle: .module)
                    let message = title.flatMap { !$0.isEmpty ? String(format: fmt, $0) : nil } ?? fallback
                    showToast(message, tone: .success)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SyncStatusIcon(status: syncCoordinator.status)
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: Self.defaultWindowSize.width, height: Self.defaultWindowSize.height)
        .commands {
            CommandGroup(after: .appSettings) {
                Toggle(
                    String(localized: "Append YouTube transcript to note on clip", bundle: .module),
                    isOn: $appendYouTubeTranscriptOnClip
                )
            }
        }
        Settings {
            RubienSettingsView()
                .environmentObject(syncCoordinator)
        }
    }

    private func showToast(_ message: String, tone: AddinToastTone, hideAfter delay: TimeInterval = 3) {
        let toast = AddinToastPayload(message: message, tone: tone)
        withAnimation(.easeInOut(duration: 0.3)) {
            addinToast = toast
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if addinToast?.id == toast.id { addinToast = nil }
            }
        }
    }

    private static func preferredDefaultWindowSize() -> CGSize {
        let fallback = CGSize(width: 1440, height: 920)
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return fallback }

        let width = min(visibleFrame.width - 80, max(1280, visibleFrame.width * 0.9))
        let height = min(visibleFrame.height - 80, max(820, visibleFrame.height * 0.9))
        return CGSize(width: width, height: height)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var activationCancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Configure API contact email for CrossRef/OpenAlex polite pool
        MetadataFetcher.contactEmail = RubienPreferences.apiContactEmail

        // Pre-warm the JSCore engine for the style used in the last session,
        // so the first citation render doesn't pay the cold-start cost.
        CiteprocJSCorePool.shared.warmUpLastUsed()

        // Belt-and-suspenders for the cross-process observation bridge: if a
        // CLI write happened while the app was in the background and the
        // Darwin notification didn't reach us (e.g. the broadcaster wasn't
        // alive yet), refresh on every focus-gain.
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in LibraryChangeBroadcaster.shared.triggerLocalRefresh() }
            .store(in: &activationCancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReaderWindowManager.shared.closeAll()
    }
}

// MARK: - Toast

private struct AddinToastPayload: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let tone: AddinToastTone
}

private enum AddinToastTone: Equatable {
    case success, error, info

    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .secondary
        }
    }
}

private struct AddinToast: View {
    let message: String
    let tone: AddinToastTone

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                toastContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
            } else {
                toastContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }
        }
        .padding(.horizontal, 16)
        .lineLimit(3)
        .allowsHitTesting(false)
    }

    private var toastContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.color)
                .frame(width: 10, height: 10)
            Text(message)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
        }
    }
}
