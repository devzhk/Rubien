import Foundation
import RubienCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Content-free local metadata that distinguishes Rubien Home/reader sessions
/// from unrelated conversations in the provider's shared workspace history.
actor AssistantSessionAttributionStore {
    static let shared = AssistantSessionAttributionStore(
        fileURL: AppDatabase.libraryRootURL
            .appendingPathComponent("assistant-session-attribution.json"))

    enum Context: Codable, Sendable, Equatable {
        case library
        case reference(Int64)

        private enum CodingKeys: String, CodingKey { case kind, referenceId }
        private enum Kind: String, Codable { case library, reference }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .library: self = .library
            case .reference:
                self = .reference(try container.decode(Int64.self, forKey: .referenceId))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .library:
                try container.encode(Kind.library, forKey: .kind)
            case .reference(let id):
                try container.encode(Kind.reference, forKey: .kind)
                try container.encode(id, forKey: .referenceId)
            }
        }
    }

    struct Attribution: Codable, Sendable, Equatable {
        let provider: AgentProviderKind
        let conversationId: UUID
        let context: Context
        let recordedAt: Date
    }

    private struct FileEnvelope: Codable {
        var version = 1
        var entries: [String: Attribution]
    }

    private let fileURL: URL
    private var loaded = false
    private var entries: [String: Attribution] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(
        sessionID: String,
        provider: AgentProviderKind,
        workspaceURL: URL,
        conversationId: UUID,
        context: AssistantConversationContext
    ) {
        guard !sessionID.isEmpty, let storedContext = Self.storedContext(context) else { return }
        loadIfNeeded()
        entries[Self.key(sessionID: sessionID, provider: provider, workspaceURL: workspaceURL)] = Attribution(
            provider: provider,
            conversationId: conversationId,
            context: storedContext,
            recordedAt: Date())
        pruneIfNeeded()
        persist()
    }

    func attribution(
        sessionID: String,
        provider: AgentProviderKind,
        workspaceURL: URL
    ) -> Attribution? {
        loadIfNeeded()
        return entries[Self.key(sessionID: sessionID, provider: provider, workspaceURL: workspaceURL)]
    }

    func librarySessionIDs(
        _ sessionIDs: [String],
        provider: AgentProviderKind,
        workspaceURL: URL
    ) -> Set<String> {
        loadIfNeeded()
        return Set(sessionIDs.filter { id in
            guard let entry = entries[Self.key(
                sessionID: id,
                provider: provider,
                workspaceURL: workspaceURL)]
            else { return false }
            return entry.context == .library
        })
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? decoder.decode(FileEnvelope.self, from: data),
              envelope.version == 1
        else { return }
        entries = envelope.entries
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(FileEnvelope(entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History attribution is best-effort functional metadata. Provider
            // history remains usable through the unclassified/all scope.
        }
    }

    private func pruneIfNeeded() {
        let maximumEntries = 5_000
        guard entries.count > maximumEntries else { return }
        let keep = entries.sorted { $0.value.recordedAt > $1.value.recordedAt }
            .prefix(maximumEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private static func storedContext(_ context: AssistantConversationContext) -> Context? {
        switch context {
        case .library: return .library
        case .reference(let reference): return .reference(reference.id)
        case .unclassifiedResume: return nil
        }
    }

    private static func key(
        sessionID: String,
        provider: AgentProviderKind,
        workspaceURL: URL
    ) -> String {
        let identity = [
            workspaceURL.standardizedFileURL.path,
            provider.rawValue,
            sessionID,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
