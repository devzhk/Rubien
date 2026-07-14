#if os(macOS)
import SwiftUI
import RubienCore

enum ZoteroImportPropertyPresentation {
    static func allowedProperties(
        from allProperties: [PropertyDefinition]
    ) -> [PropertyDefinition] {
        allProperties.filter { property in
            // Built-in Tags is safe. Other built-ins are semantic projections,
            // so stamping a source name into them would corrupt real fields.
            if property.isDefault {
                return property.defaultFieldKey == PropertyDefinition.tagsFieldKey
            }
            switch property.type {
            case .string, .url, .singleSelect, .multiSelect: return true
            case .number, .date, .checkbox: return false
            }
        }
    }

    static func defaultPropertyID(in allProperties: [PropertyDefinition]) -> Int64? {
        allProperties.first {
            $0.defaultFieldKey == PropertyDefinition.tagsFieldKey
        }?.id ?? allowedProperties(from: allProperties).first?.id
    }
}

struct ZoteroImportStampFields: View {
    let properties: [PropertyDefinition]
    @Binding var selectedPropertyId: Int64?
    @Binding var stampValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stamp every imported reference with:")
                    .font(.subheadline)

                Picker("Property", selection: $selectedPropertyId) {
                    ForEach(properties) { property in
                        Text("\(property.name)  —  \(property.type.label)")
                            .tag(property.id as Int64?)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Value:")
                    .font(.subheadline)
                TextField("Value", text: $stampValue)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
#endif
