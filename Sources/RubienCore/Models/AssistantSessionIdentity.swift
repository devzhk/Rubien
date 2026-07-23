import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Shared construction for local workspace identity and hashed provider-session
/// aliases. Raw workspace paths are used only as hash input and are not stored in
/// transcript rows.
public enum AssistantSessionIdentity {
    public static let separator = "\u{1f}"

    public static func workspaceHash(_ workspaceURL: URL) -> String {
        sha256(workspaceURL.standardizedFileURL.path)
    }

    public static func aliasKeyHash(
        workspaceURL: URL,
        provider: AssistantProvider,
        providerSessionID: String
    ) -> String {
        sha256([
            workspaceURL.standardizedFileURL.path,
            provider.rawValue,
            providerSessionID,
        ].joined(separator: separator))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
