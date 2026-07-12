import Foundation

// MARK: - Render model types
//
// These types are the pure-data contract between Swift and the `window.RubienChat`
// JS renderer (see `Docs/superpowers/specs/2026-07-04-assistant-chat-sidebar-design.md`
// §5.2). They are deliberately AppKit-free and NOT `#if os(macOS)`-gated so the unit
// tests (and any future Linux CLI surface) can use them without a WebView.

/// A transcript row's role. Mirrors the JS contract's `role` field.
enum ChatRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case tool
    case notice
}

/// Lifecycle of a tool-use chip. Mirrors the JS contract's chip `status`.
enum ToolChipStatus: String, Codable, Sendable, Equatable {
    case started
    case completed
    case denied
}

/// Renderer color theme. Mirrors `setTheme(mode)` where mode ∈ "light"|"dark".
enum ChatTheme: String, Codable, Sendable, Equatable {
    case light
    case dark
}

/// A completed turn's terminal status, shown as a badge under the bubble.
/// `nil` = a normal turn. Mirrors the JS contract's `turnStatus`.
enum TurnStatus: String, Codable, Sendable, Equatable {
    case interrupted
    case denied
}

/// One user-authored transcript message, including local-only attachment
/// presentation metadata. The provider-facing staged paths never cross this
/// rendering boundary.
struct ChatUserMessagePayload: Codable, Sendable, Equatable {
    let body: String
    let attachments: [ChatAttachmentPresentation]
}

/// One persisted/rendered transcript message, matching the JS `loadTranscript`
/// element shape `{role, body, turnStatus, seq, attachments}`.
///
/// - `body`: markdown (user/assistant/notice) or a JSON string `{name,detail,status}`
///   for `tool` rows (the restore-path analogue of a live `addToolChip`).
/// - `turnStatus`: `nil` for a normal turn. When nil the key is omitted from the
///   encoded JSON; the JS side treats a missing key and an explicit `null`
///   identically (`m?.turnStatus !== 'interrupted' …`), so synthesized `Codable`
///   (which omits nil) is the simplest correct encoding.
struct ChatRenderMessage: Codable, Sendable, Equatable {
    let role: ChatRole
    let body: String
    let turnStatus: TurnStatus?
    let seq: Int
    let attachments: [ChatAttachmentPresentation]

    init(
        role: ChatRole,
        body: String,
        turnStatus: TurnStatus? = nil,
        seq: Int,
        attachments: [ChatAttachmentPresentation] = []
    ) {
        self.role = role
        self.body = body
        self.turnStatus = turnStatus
        self.seq = seq
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case body
        case turnStatus
        case seq
        case attachments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(ChatRole.self, forKey: .role)
        body = try container.decode(String.self, forKey: .body)
        turnStatus = try container.decodeIfPresent(TurnStatus.self, forKey: .turnStatus)
        seq = try container.decode(Int.self, forKey: .seq)
        attachments = try container.decodeIfPresent(
            [ChatAttachmentPresentation].self,
            forKey: .attachments
        ) ?? []
    }
}

/// The `{name, detail, status}` object passed to the JS `addToolChip(chip)`.
/// A nil `detail` is omitted from the JSON; JS treats missing/null identically
/// (`chip?.detail == null`), so synthesized `Codable` is correct.
struct ToolChipPayload: Codable, Sendable, Equatable {
    let name: String
    let detail: String?
    let status: ToolChipStatus

    init(name: String, detail: String?, status: ToolChipStatus) {
        self.name = name
        self.detail = detail
        self.status = status
    }
}

// MARK: - External-link safety classifier
//
// Threat-model layer 6 (§3): the transcript may render a link chosen by an
// untrusted document. The JS side already limits anchors to http/https, but the
// `openExternalLink` bridge re-validates in Swift before handing a URL to
// `NSWorkspace`. This classifier is the pure, unit-testable core of that gate.

enum ExternalLinkDecision: Equatable, Sendable {
    /// A normal http(s) URL to a plain host — open without prompting.
    case open
    /// http(s) but an unusual host (IP literal, punycode, embedded userinfo,
    /// non-standard port) — confirm with the user before opening.
    case confirm
    /// Not an openable web link (non-http(s) scheme, hostless, unparseable) —
    /// drop it silently.
    case reject
}

enum ChatExternalLink {
    /// Re-validate a URL string the JS bridge asked us to open.
    static func classify(_ urlString: String) -> ExternalLinkDecision {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return .reject
        }
        // Odd hosts → confirm.
        if url.user != nil || url.password != nil { return .confirm }
        if host.lowercased().contains("xn--") { return .confirm }
        if isIPAddress(host) { return .confirm }
        if let port = url.port, port != 80, port != 443 { return .confirm }
        return .open
    }

    /// True for an IPv4 dotted-quad or an IPv6 literal host.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 literal (brackets stripped by URL)
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty, octet.allSatisfy(\.isNumber),
                  let n = Int(octet), (0...255).contains(n) else { return false }
            return true
        }
    }
}
