#if os(macOS)
import AppKit
import SwiftUI
import CloudKit
import RubienSync

/// View modifier that overlays a non-blocking banner or shows a modal
/// alert depending on the coordinator's current SyncStatus.
///
/// - `.error(.quotaExceeded)` → modal alert with "Open iCloud Settings"
/// - `.signedOut` / `.unavailable` / most user-actionable errors → top
///   overlay banner, auto-dismissable
/// - `.idle` / `.syncing` / transient errors → nothing
@available(macOS 14.0, *)
struct SyncStatusBanner: ViewModifier {
    let status: SyncStatus
    let onRetry: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let banner = bannerMessage {
                    bannerView(banner)
                }
            }
            .alert(
                String(localized: "iCloud storage full", bundle: .module),
                isPresented: .constant(isQuotaExceeded),
                actions: {
                    Button(String(localized: "Open iCloud Settings", bundle: .module)) {
                        openSystemSettingsAppleID()
                    }
                    Button(String(localized: "OK", bundle: .module), role: .cancel) {}
                },
                message: {
                    Text(String(localized: "Free space in iCloud Settings to resume sync.", bundle: .module))
                }
            )
    }

    private var isQuotaExceeded: Bool {
        if case .error(let err) = status, err.code == .quotaExceeded { return true }
        return false
    }

    private struct BannerMessage {
        let text: String
        let tone: Tone
        let action: Action?

        enum Tone { case info, warning, error }
        struct Action {
            let label: String
            let handler: () -> Void
        }
    }

    private var bannerMessage: BannerMessage? {
        switch status {
        case .disabled, .idle, .syncing:
            return nil
        case .unavailable(let reason):
            return BannerMessage(
                text: String(format: String(localized: "iCloud sync unavailable: %@", bundle: .module), reason),
                tone: .warning,
                action: BannerMessage.Action(
                    label: String(localized: "Try again", bundle: .module),
                    handler: onRetry
                )
            )
        case .signedOut:
            return BannerMessage(
                text: String(localized: "Signed out of iCloud — sync paused. Your library is safe locally.", bundle: .module),
                tone: .info,
                action: nil
            )
        case .error(let err):
            return bannerForError(err)
        }
    }

    private func bannerForError(_ err: CKError) -> BannerMessage? {
        switch err.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .zoneBusy, .requestRateLimited, .limitExceeded,
             .batchRequestFailed, .accountTemporarilyUnavailable,
             .changeTokenExpired:
            return nil  // transient / engine-handled
        case .quotaExceeded:
            return nil  // handled by .alert above
        case .notAuthenticated:
            return BannerMessage(
                text: String(localized: "Sync authentication failed. Re-authenticate iCloud in System Settings.", bundle: .module),
                tone: .error,
                action: BannerMessage.Action(
                    label: String(localized: "Open System Settings", bundle: .module),
                    handler: { openSystemSettingsAppleID() }
                )
            )
        case .managedAccountRestricted:
            return BannerMessage(
                text: String(localized: "Sync not available on this account (restricted by management policy). Your library stays local.", bundle: .module),
                tone: .warning,
                action: nil
            )
        case .serverRejectedRequest:
            return BannerMessage(
                text: String(localized: "Sync paused — server rejected request. See Console for details.", bundle: .module),
                tone: .error,
                action: nil
            )
        default:
            return BannerMessage(
                text: String(format: String(localized: "Sync error: %@. Will retry.", bundle: .module), err.localizedDescription),
                tone: .warning,
                action: nil
            )
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: BannerMessage) -> some View {
        HStack(spacing: 12) {
            Text(banner.text)
                .font(.callout)
            if let action = banner.action {
                Button(action.label, action: action.handler)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor(banner.tone), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func backgroundColor(_ tone: BannerMessage.Tone) -> Color {
        switch tone {
        case .info: return Color.blue.opacity(0.15)
        case .warning: return Color.orange.opacity(0.15)
        case .error: return Color.red.opacity(0.15)
        }
    }
}

@available(macOS 14.0, *)
extension View {
    func syncStatusBanner(status: SyncStatus, onRetry: @escaping () -> Void) -> some View {
        modifier(SyncStatusBanner(status: status, onRetry: onRetry))
    }
}

/// Opens System Settings' Apple ID pane. macOS 14+ uses the
/// `com.apple.systempreferences.AppleIDSettings` bundle id; older URL
/// schemes targeting `com.apple.preferences.AppleIDPrefPane` stopped
/// working when the Settings app was rewritten in macOS 13. Apple does
/// not ship a `CKContainer.openSettingsURLString` constant on macOS —
/// that's an iOS-only UIApplication API.
@available(macOS 14.0, *)
private func openSystemSettingsAppleID() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
        NSWorkspace.shared.open(url)
    }
}
#endif
