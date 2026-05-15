import SwiftUI
import RubienSync

/// Small toolbar glyph reflecting the coordinator's current sync status.
/// Eight visual states keyed off the SyncStatus cases, using SF Symbols.
@available(macOS 14.0, *)
struct SyncStatusIcon: View {
    let status: SyncStatus

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(symbolColor)
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: status == .syncing
            )
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
