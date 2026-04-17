import SwiftUI
import RubienCore

struct ViewChromeBar: View {
    let viewName: String?
    @Binding var filters: [ViewFilter]
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]
    let isDirty: Bool
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row1
            Divider()
            FilterChromeBar(
                filters: $filters,
                tags: tags,
                propertyDefs: propertyDefs
            )
            Divider()
        }
        .background(.bar)
    }

    private var row1: some View {
        HStack(spacing: 8) {
            if let viewName {
                Text(viewName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }

            if isDirty {
                HStack(spacing: 4) {
                    Text("Unsaved")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    Button("Discard", action: onDiscard)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
