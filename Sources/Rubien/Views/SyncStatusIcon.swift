#if os(macOS)
import SwiftUI
import RubienSync

/// Small toolbar glyph reflecting the coordinator's current sync status.
/// Eight visual states keyed off the SyncStatus cases, using SF Symbols.
struct SyncStatusIcon: View {
    let status: SyncStatus

    var body: some View {
        // No `.symbolEffect(.pulse, options: .repeating, ...)`: while sync
        // was active, the icon ran a continuous CoreAnimation pulse on the
        // process-wide render-server pipeline. A `sample` of the lagging
        // process showed ~58% of main-thread time blocked in
        // `[CAContext waitForCommitId:timeout:]`, and a discriminator that
        // forced `isActive: false` eliminated the user-visible PDF reader
        // scroll lag — so the repeating pulse is at minimum the dominant
        // contributor to that back-pressure. Icon + color change still
        // convey sync state.
        Image(systemName: symbolName)
            .foregroundStyle(symbolColor)
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)
    }

    private var symbolName: String {
        switch status {
        case .disabled: return "icloud.slash"
        case .unavailable: return "exclamationmark.icloud"
        case .signedOut: return "icloud.slash"
        case .idle: return "checkmark.icloud.fill"
        case .syncing: return "icloud.and.arrow.up"
        case .error: return "xmark.icloud"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .disabled, .signedOut: return .secondary
        case .unavailable: return .orange
        case .idle: return .accentColor
        case .syncing: return .blue
        case .error: return .red
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .disabled: return String(localized: "Sync off", bundle: .module)
        case .unavailable(let reason): return String(format: String(localized: "Sync unavailable: %@", bundle: .module), reason)
        case .signedOut: return String(localized: "Not signed in to iCloud", bundle: .module)
        case .idle: return String(localized: "Sync idle", bundle: .module)
        case .syncing: return String(localized: "Syncing", bundle: .module)
        case .error(let err): return String(format: String(localized: "Sync error: %@", bundle: .module), err.localizedDescription)
        }
    }
}
#endif
