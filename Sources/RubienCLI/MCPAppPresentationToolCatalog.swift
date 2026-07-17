import Foundation
import RubienCore

/// Optional catalog exposed only by Rubien's embedded Assistant content channel.
/// It is intentionally absent from the public native/Node catalogs and CLI docs.
enum MCPAppPresentationToolCatalog {
    static let toolName = RubienAppPresentationContract.toolName
    private static let maximumItemCount = RubienAppPresentationContract.maximumItemCount
    private static let maximumTitleLength = RubienAppPresentationContract.maximumTitleLength
    private static let maximumAuthorsLength = RubienAppPresentationContract.maximumAuthorsLength
    private static let maximumURLBytes = RubienAppPresentationContract.maximumURLBytes
    private static let maximumOutputBytes = RubienAppPresentationContract.maximumResultBytes

    static let tools = [presentDocumentCardsTool]

    private static let presentDocumentCardsTool = MCPTool(
        name: toolName,
        description: "Present every openable document intentionally referenced in this response as clickable Rubien cards. Call this tool exactly once with up to \(maximumItemCount) saved library documents and external web documents the user should be able to open. Include authors and year for web documents when known; keep explanations and reasons in response prose, never in the arguments.",
        inputSchema: [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": maximumItemCount,
                    "items": [
                        "oneOf": [
                            [
                                "type": "object",
                                "properties": [
                                    "referenceId": ["type": "integer", "minimum": 1],
                                ],
                                "required": ["referenceId"],
                                "additionalProperties": false,
                            ],
                            [
                                "type": "object",
                                "properties": [
                                    "url": ["type": "string", "maxLength": maximumURLBytes],
                                    "title": [
                                        "type": "string",
                                        "minLength": 1,
                                        "maxLength": maximumTitleLength,
                                    ],
                                    "authors": [
                                        "type": "string",
                                        "minLength": 1,
                                        "maxLength": maximumAuthorsLength,
                                    ],
                                    "year": ["type": "integer", "minimum": 1, "maximum": 9999],
                                ],
                                "required": ["url", "title"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                ],
            ],
            "required": ["items"],
            "additionalProperties": false,
        ],
        isImage: false,
        buildArgv: { _ in [] },
        validatesPublicPolicy: false,
        directHandler: present)

    private static func present(_ arguments: [String: Any]) throws -> [String: Any] {
        guard Set(arguments.keys) == ["items"] else {
            throw MCPToolError.invalidArguments("Expected exactly one argument: items")
        }
        guard let rawItems = arguments["items"] as? [[String: Any]] else {
            throw MCPToolError.invalidArguments("Missing required argument: items")
        }
        guard !rawItems.isEmpty, rawItems.count <= maximumItemCount else {
            throw MCPToolError.invalidArguments("`items` must contain between 1 and \(maximumItemCount) items")
        }

        let database = AppDatabase.shared
        var result: [[String: Any]] = []
        var seenLibrary = Set<Int64>()
        var seenWeb = Set<String>()

        for item in rawItems {
            let keys = Set(item.keys)
            if keys == ["referenceId"] {
                guard let rawID = item["referenceId"],
                      let integerID = mcpExactInt(rawID),
                      integerID > 0,
                      let id = Int64(exactly: integerID)
                else {
                    throw MCPToolError.invalidArguments("`referenceId` must be a positive integer")
                }
                guard seenLibrary.insert(id).inserted else { continue }
                guard let reference = try database.fetchReferences(ids: [id]).first else {
                    throw MCPToolError.invalidArguments("Reference \(id) does not exist")
                }
                guard !reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      reference.title.count <= maximumTitleLength else {
                    throw MCPToolError.invalidArguments(
                        "Reference \(id) has an invalid title; titles must contain 1...\(maximumTitleLength) characters"
                    )
                }
                if let year = reference.year, !(1...9999).contains(year) {
                    throw MCPToolError.invalidArguments("Reference \(id) has an invalid year; expected 1...9999")
                }
                let badge: String
                if reference.hasPDFInCache(in: database) {
                    badge = "PDF"
                } else if reference.canOpenWebReader {
                    badge = "Web"
                } else {
                    badge = "Library"
                }
                var card: [String: Any] = [
                    "kind": "library",
                    "referenceId": id,
                    "title": reference.title,
                    "badge": badge,
                ]
                let authors = reference.authors.displayString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !authors.isEmpty {
                    card["authors"] = authors.count <= maximumAuthorsLength
                        ? authors
                        : String(authors.prefix(maximumAuthorsLength - 1)) + "…"
                }
                if let year = reference.year { card["year"] = year }
                result.append(card)
                continue
            }

            let allowedKeys: Set<String> = ["url", "title", "authors", "year"]
            guard keys.isSubset(of: allowedKeys),
                  keys.contains("url"),
                  keys.contains("title")
            else {
                throw MCPToolError.invalidArguments(
                    "Each item must be exactly a referenceId object or a url/title object with optional authors/year"
                )
            }
            guard let rawURL = item["url"] as? String,
                  rawURL.utf8.count <= maximumURLBytes,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil,
                  let rawTitle = item["title"] as? String,
                  rawTitle.count <= maximumTitleLength,
                  !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MCPToolError.invalidArguments(
                    "Web documents require an HTTP(S) URL of at most \(maximumURLBytes) bytes and a title of 1...\(maximumTitleLength) characters"
                )
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let authors: String?
            if let rawAuthors = item["authors"] as? String {
                let trimmed = rawAuthors.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= maximumAuthorsLength else {
                    throw MCPToolError.invalidArguments(
                        "`authors` must contain 1...\(maximumAuthorsLength) characters"
                    )
                }
                authors = trimmed
            } else {
                authors = nil
            }
            let year: Int?
            if let rawYear = item["year"] {
                guard let parsedYear = mcpExactInt(rawYear), (1...9999).contains(parsedYear) else {
                    throw MCPToolError.invalidArguments("`year` must be an integer from 1 through 9999")
                }
                year = parsedYear
            } else {
                year = nil
            }
            let key = webDeduplicationKey(url)
            guard seenWeb.insert(key).inserted else { continue }
            var card: [String: Any] = [
                "kind": "web",
                "url": rawURL,
                "title": title,
                "badge": "Web candidate",
            ]
            if let authors { card["authors"] = authors }
            if let year { card["year"] = year }
            result.append(card)
        }

        let envelope: [String: Any] = ["items": result]
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumOutputBytes else {
            throw MCPToolError.invalidArguments(
                "Presentation output exceeds the \(maximumOutputBytes / 1_024) KiB limit"
            )
        }
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    private static func webDeduplicationKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }
}
