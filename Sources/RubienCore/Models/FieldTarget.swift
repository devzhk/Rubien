import Foundation

public enum FieldTarget: Hashable, Sendable {
    case builtin(ColumnIdentifier)
    case custom(Int64)  // propertyDefinition.id
}

extension FieldTarget: Codable {
    // Custom Codable produces {"kind":"builtin","value":"year"} rather than the
    // synthesized {"builtin":{"_0":"year"}}. The cleaner shape is part of the
    // CLI JSON contract for hand-authored filter/sort/groupBy payloads.
    private enum Kind: String, Codable {
        case builtin, custom
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let id):
            try container.encode(Kind.builtin, forKey: .kind)
            try container.encode(id.rawValue, forKey: .value)
        case .custom(let id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(id, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .builtin:
            let raw = try container.decode(String.self, forKey: .value)
            guard let id = ColumnIdentifier(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Unknown ColumnIdentifier: \(raw)"
                )
            }
            self = .builtin(id)
        case .custom:
            let id = try container.decode(Int64.self, forKey: .value)
            self = .custom(id)
        }
    }
}
