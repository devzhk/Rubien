#if os(macOS)
import Foundation

/// SemVer precedence, including prereleases. Build metadata never changes ordering.
struct ProviderReleaseVersion: Comparable, Sendable {
    let rawValue: String
    private let core: [UInt64]
    private let prerelease: [String]
    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ value: String) {
        guard value.utf8.count <= 128,
              value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"#,
                          options: .regularExpression) != nil else { return nil }
        let precedence = value.split(separator: "+", maxSplits: 1)[0]
        let parts = precedence.split(separator: "-", maxSplits: 1)
        let numbers = parts[0].split(separator: ".")
        guard numbers.allSatisfy({ ($0.count == 1 || $0.first != "0") && UInt64($0) != nil }) else { return nil }
        let pre = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        guard pre.allSatisfy({ !Self.numeric($0) || $0.count == 1 || $0.first != "0" }) else { return nil }
        rawValue = value
        core = numbers.compactMap { UInt64($0) }
        prerelease = pre
    }

    private static func numeric(_ value: String) -> Bool { value.utf8.allSatisfy { (48...57).contains($0) } }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.core == rhs.core && lhs.prerelease == rhs.prerelease }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = numeric(left), rn = numeric(right)
            if ln != rn { return ln }
            if ln, left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// Public distribution metadata describes a release, not permission to replace an installation.
enum ProviderReleaseSource: String, Codable, Sendable {
    case codexNative, claudeNative, codexNPM, claudeNPM, codexHomebrew, claudeHomebrew

    static func source(provider: AgentProviderKind, hint: ProviderInstallation.MethodHint) -> Self? {
        switch (provider, hint) {
        case (.codex, .native): return .codexNative
        case (.claude, .native): return .claudeNative
        case (.codex, .npm): return .codexNPM
        case (.claude, .npm): return .claudeNPM
        case (.codex, .homebrew): return .codexHomebrew
        case (.claude, .homebrew): return .claudeHomebrew
        default: return nil
        }
    }

    var url: URL {
        let address: String
        switch self {
        case .codexNative: address = "https://releases.openai.com/codex/channels/latest"
        case .claudeNative: address = "https://downloads.claude.ai/claude-code-releases/latest"
        case .codexNPM: address = "https://registry.npmjs.org/@openai%2Fcodex/latest"
        case .claudeNPM: address = "https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/latest"
        case .codexHomebrew: address = "https://formulae.brew.sh/api/cask/codex.json"
        case .claudeHomebrew: address = "https://formulae.brew.sh/api/cask/claude-code.json"
        }
        return URL(string: address)!
    }
    var label: String {
        switch self {
        case .codexNative, .claudeNative: return "Native latest release"
        case .codexNPM, .claudeNPM: return "Public npm latest release"
        case .codexHomebrew, .claudeHomebrew: return "Homebrew cask release"
        }
    }
    var allowsReleaseNotice: Bool {
        switch self {
        case .codexNPM, .claudeNPM, .codexHomebrew, .claudeHomebrew: return true
        // Native updater/channel policy is not established by a layout hint.
        case .codexNative, .claudeNative: return false
        }
    }
    var updateCommand: String? {
        switch self {
        case .codexNPM: return "npm install -g @openai/codex@latest"
        case .claudeNPM: return "npm install -g @anthropic-ai/claude-code@latest"
        case .codexHomebrew: return "brew upgrade --cask codex"
        case .claudeHomebrew: return "brew upgrade --cask claude-code"
        case .codexNative, .claudeNative: return nil
        }
    }

    func decode(_ data: Data) throws -> ProviderReleaseVersion {
        guard !data.isEmpty, data.count <= ProviderReleaseClient.maximumBytes else { throw ProviderReleaseError.invalidMetadata }
        let value: String?
        if self == .claudeNative {
            value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderReleaseError.invalidMetadata
            }
            switch self {
            case .codexNative:
                guard let tag = object["tag_name"] as? String, tag.hasPrefix("rust-v"),
                      object["draft"] as? Bool != true, object["prerelease"] as? Bool != true else {
                    throw ProviderReleaseError.invalidMetadata
                }
                value = String(tag.dropFirst(6))
            case .codexNPM, .claudeNPM:
                let name = self == .codexNPM ? "@openai/codex" : "@anthropic-ai/claude-code"
                guard object["name"] as? String == name else { throw ProviderReleaseError.invalidMetadata }
                value = object["version"] as? String
            case .codexHomebrew, .claudeHomebrew:
                let token = self == .codexHomebrew ? "codex" : "claude-code"
                guard object["token"] as? String == token, object["tap"] as? String == "homebrew/cask" else {
                    throw ProviderReleaseError.invalidMetadata
                }
                value = object["version"] as? String
            case .claudeNative: value = nil
            }
        }
        guard let value, let version = ProviderReleaseVersion(value), !version.isPrerelease else {
            throw ProviderReleaseError.invalidMetadata
        }
        return version
    }
}

enum ProviderReleaseError: LocalizedError {
    case invalidMetadata, unexpectedResponse, installedVersionUnavailable, rateLimited(Date)
    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "The release service returned an unrecognized version. Try again later."
        case .unexpectedResponse: return "The release service could not be reached. Try again later."
        case .installedVersionUnavailable: return "Rubien could not read the installed version. Recheck the executable and try again."
        case .rateLimited: return "The release service asked Rubien to wait before checking again."
        }
    }
}

enum ProviderReleaseClient {
    static let maximumBytes = 512 * 1024

    static func fetch(_ source: ProviderReleaseSource) async throws -> ProviderReleaseVersion {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ReleaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Rubien-Provider-Updates", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        try validateResponse(response, source: source, now: Date())
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ProviderReleaseError.invalidMetadata }
            data.append(byte)
        }
        return try source.decode(data)
    }

    static func validateResponse(_ response: URLResponse, source: ProviderReleaseSource, now: Date) throws {
        guard let http = response as? HTTPURLResponse, response.url == source.url else {
            throw ProviderReleaseError.unexpectedResponse
        }
        if http.statusCode == 429 || http.statusCode == 503 {
            let fallback = http.statusCode == 429 ? "60" : nil
            if let until = retryDate(http.value(forHTTPHeaderField: "Retry-After") ?? fallback, now: now) {
                throw ProviderReleaseError.rateLimited(until)
            }
        }
        guard http.statusCode == 200, response.expectedContentLength <= maximumBytes else {
            throw ProviderReleaseError.unexpectedResponse
        }
    }

    static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 7 * 86400))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(now, $0) }
    }
}

private final class ReleaseRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The verified metadata endpoints do not redirect. Revalidate any contract change.
        completionHandler(nil)
    }
}
#endif
