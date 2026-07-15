#if os(macOS)
import SwiftUI
import RubienCore

/// Read-only type disclosure shown before an imported reference is saved.
struct ReferenceTypeConfirmationLabel: View {
    let referenceType: ReferenceType

    var body: some View {
        Label(
            String(
                format: String(localized: "importConfirmation.referenceType", bundle: .module),
                referenceType.rawValue
            ),
            systemImage: referenceType.icon
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
#endif
