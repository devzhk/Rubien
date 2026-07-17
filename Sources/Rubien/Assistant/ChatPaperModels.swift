import Foundation
import RubienCore

/// A presentation-only paper chosen by the agent. It contains no reason or
/// arbitrary HTML; Rubien owns the card heading, badge, and activation behavior.
struct ChatPaper: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case library, web }

    let kind: Kind
    let referenceId: Int64?
    let url: String?
    let title: String
    let authors: String?
    let year: Int?
    let badge: String

    init(
        kind: Kind,
        referenceId: Int64?,
        url: String?,
        title: String,
        authors: String? = nil,
        year: Int?,
        badge: String
    ) {
        self.kind = kind
        self.referenceId = referenceId
        self.url = url
        self.title = title
        self.authors = authors
        self.year = year
        self.badge = badge
    }

    var id: String {
        switch kind {
        case .library: return "library:\(referenceId ?? -1)"
        case .web: return "web:\(Self.webDeduplicationKey(url) ?? title)"
        }
    }

    private static func webDeduplicationKey(_ raw: String?) -> String? {
        guard let raw,
              let url = URL(string: raw),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return raw }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? raw
    }
}

struct ChatPaperGroup: Codable, Sendable, Equatable {
    let items: [ChatPaper]
}

enum ChatPaperPresentation {
    static let toolName = RubienAppPresentationContract.toolName
    static let maximumResultBytes = RubienAppPresentationContract.maximumResultBytes
    static let maximumItemCount = RubienAppPresentationContract.maximumItemCount
    static let maximumTitleLength = RubienAppPresentationContract.maximumTitleLength
    static let maximumAuthorsLength = RubienAppPresentationContract.maximumAuthorsLength
    static let maximumBadgeLength = RubienAppPresentationContract.maximumBadgeLength
    static let maximumURLBytes = RubienAppPresentationContract.maximumURLBytes

    static func isPresentationTool(_ name: String) -> Bool {
        name == toolName
            || name == "rubien/\(toolName)"
            || name == "mcp__rubien__\(toolName)"
    }

    static func encodeHistoryGroup(_ group: ChatPaperGroup) -> String? {
        guard let data = try? JSONEncoder().encode(group),
              data.count <= maximumResultBytes
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeHistoryGroup(_ body: String) -> ChatPaperGroup? {
        decodeToolResult(body)
    }

    /// Apply the same trust boundary to live and restored groups. The embedded
    /// MCP tool already emits this shape, but provider history is durable input
    /// and the JS bridge must stay bounded even if that history was edited.
    static func validatedGroup(_ group: ChatPaperGroup) -> ChatPaperGroup? {
        var seen = Set<String>()
        let valid = group.items.prefix(maximumItemCount).filter { paper in
            let title = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let badge = paper.badge.trimmingCharacters(in: .whitespacesAndNewlines)
            let authors = paper.authors?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  title.count <= maximumTitleLength,
                  authors.map({ !$0.isEmpty && $0.count <= maximumAuthorsLength }) ?? true,
                  !badge.isEmpty,
                  badge.count <= maximumBadgeLength,
                  paper.year.map({ (1...9_999).contains($0) }) ?? true
            else { return false }
            switch paper.kind {
            case .library:
                guard paper.referenceId.map({ $0 > 0 }) == true
                    && paper.url == nil
                else { return false }
            case .web:
                guard paper.referenceId == nil,
                      let raw = paper.url,
                      raw.utf8.count <= maximumURLBytes,
                      let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      url.host != nil
                else { return false }
            }
            return seen.insert(paper.id).inserted
        }
        return valid.isEmpty ? nil : ChatPaperGroup(items: valid)
    }

    /// One canonical group per completed turn: invocation order first, call id
    /// as a deterministic tie-breaker, then paper-id de-duplication and the
    /// renderer's ten-card cap.
    static func merge(
        _ calls: [(callID: String, ordinal: Int, group: ChatPaperGroup)]
    ) -> ChatPaperGroup? {
        var merged: [ChatPaper] = []
        var seen = Set<String>()
        for call in calls.sorted(by: {
            $0.ordinal == $1.ordinal ? $0.callID < $1.callID : $0.ordinal < $1.ordinal
        }) {
            guard let group = validatedGroup(call.group) else { continue }
            for paper in group.items where merged.count < maximumItemCount {
                if seen.insert(paper.id).inserted { merged.append(paper) }
            }
        }
        return merged.isEmpty ? nil : ChatPaperGroup(items: merged)
    }

    /// Decode the exact bounded MCP text result shape. Provider adapters pass
    /// either Claude's tool-result content string or Codex's MCP result object.
    static func decodeToolResult(_ value: Any?) -> ChatPaperGroup? {
        let text: String?
        if let string = value as? String {
            text = string
        } else if let object = value as? [String: Any],
                  let content = object["content"] as? [[String: Any]] {
            text = content.first {
                $0["type"] as? String == "text" && $0["text"] is String
            }?["text"] as? String
        } else if let content = value as? [[String: Any]] {
            text = content.first {
                $0["type"] as? String == "text" && $0["text"] is String
            }?["text"] as? String
        } else {
            text = nil
        }

        guard let text,
              let data = text.data(using: .utf8),
              data.count <= maximumResultBytes,
              let decoded = try? JSONDecoder().decode(ChatPaperGroup.self, from: data)
        else { return nil }

        return validatedGroup(decoded)
    }
}
