import Foundation

/// Shared Codable representation for forward-compatible string-backed enums.
/// Conformers retain unknown raw values instead of failing older clients.
public protocol RawStringCodable: Codable {
    init(rawValue: String)
    var rawValue: String { get }
}

public extension RawStringCodable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
