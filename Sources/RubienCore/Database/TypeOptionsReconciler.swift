import Foundation

/// Shared by migration v6 and the sync remote-apply reconciliation: append
/// any enum-backed Type option missing from an `optionsJSON` array.
/// Structural JSON edit — existing objects (order, colors, unknown fields)
/// are preserved; only missing options are appended. In practice only
/// "Markdown" can be missing (v3 guaranteed the other six), but healing all
/// enum cases keeps one code path for both callers.
public enum TypeOptionsReconciler {

    /// Default chip colors per enum-backed option, mirroring the v1 seed /
    /// v3 prune palette. Used only when appending a missing option.
    static let defaultColors: [ReferenceType: String] = [
        .journalArticle:  "#007AFF",
        .conferencePaper: "#AF52DE",
        .book:            "#34C759",
        .thesis:          "#FF9500",
        .webpage:         "#30B0C7",
        .markdown:        "#5AC8FA",
        .other:           "#8E8E93",
    ]

    /// Returns the amended JSON, the input string itself when nothing is
    /// missing, or nil when the input is not a JSON array of objects
    /// (caller must leave the stored value untouched — fail-safe).
    public static func appendingMissingTypeOptions(toOptionsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var array = parsed as? [[String: Any]] else {
            return nil
        }
        let present = Set(array.compactMap { $0["value"] as? String })
        let missing = ReferenceType.allCases.filter { !present.contains($0.rawValue) }
        guard !missing.isEmpty else { return json }
        for type in missing {
            array.append([
                "value": type.rawValue,
                "color": defaultColors[type] ?? "#8E8E93",
            ])
        }
        guard let out = try? JSONSerialization.data(withJSONObject: array),
              let str = String(data: out, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
