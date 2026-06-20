#if os(macOS)
import AppKit
import Combine
import SwiftUI
import RubienCore
import RubienSync

@main
struct RubienApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var syncCoordinator = SyncCoordinator(appDatabase: AppDatabase.shared)
    #if canImport(Sparkle)
    @State private var updateController = UpdateController()
    #endif
    @State private var addinToast: AddinToastPayload?
    private static let defaultWindowSize = preferredDefaultWindowSize()

    var body: some Scene {
        WindowGroup {
            // `.environmentObject(…)` is outermost so it's visible to the
            // `.syncStatusBannerFromCoordinator()` modifier wrapping
            // ContentView — not just to ContentView's children. Reordering
            // crashes with "No ObservableObject of type SyncCoordinator
            // found" during state restoration.
            ContentView()
                .environment(\.syncCoordinator, syncCoordinator)
                #if canImport(Sparkle)
                .environment(updateController)
                .focusedSceneValue(\.updateController, updateController)
                #endif
                .overlay(alignment: .top) {
                    if let toast = addinToast {
                        AddinToast(message: toast.message, tone: toast.tone)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .syncStatusBannerFromCoordinator()
                .task {
                    await syncCoordinator.startIfEnabled()
                }
                #if canImport(Sparkle)
                .task {
                    // Force one silent background check at launch so the gentle
                    // update reminder (toolbar icon) can surface without waiting
                    // for Sparkle's 24h scheduler to happen to fire while the app
                    // is open — which on a frequently-relaunched build it rarely
                    // does. Idempotent + preference-gated inside the controller.
                    updateController.kickLaunchBackgroundCheck()
                }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
                    let title = (note.userInfo?[RubienClipImportedKeys.title] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = String(localized: "Saved web clip", bundle: .module)
                    let fmt = String(localized: "Saved web clip: %@", bundle: .module)
                    let message = title.flatMap { !$0.isEmpty ? String(format: fmt, $0) : nil } ?? fallback
                    showToast(message, tone: .success)
                }
                .environmentObject(syncCoordinator)
                .rubienAccent()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: Self.defaultWindowSize.width, height: Self.defaultWindowSize.height)
        #if canImport(Sparkle)
        .commands {
            UpdateMenuCommands()
        }
        #endif
        Settings {
            // Same outermost-environmentObject ordering as the WindowGroup.
            RubienSettingsView()
                .environment(\.syncCoordinator, syncCoordinator)
                #if canImport(Sparkle)
                .environment(updateController)
                #endif
                .environmentObject(syncCoordinator)
                .rubienAccent()
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
        // Apply the saved appearance before activation so the first window
        // paints in the chosen theme (no system→chosen flash on relaunch).
        RubienPreferences.applyColorScheme()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Show `.help(…)` tooltips a bit sooner than AppKit's slow default.
        // Registration domain only: volatile, not written to the user's prefs,
        // and an explicit user setting still overrides it. Value is in ms.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1500])

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
#endif
