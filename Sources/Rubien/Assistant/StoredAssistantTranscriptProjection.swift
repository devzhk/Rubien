#if os(macOS)
import Foundation
import RubienCore

/// Converts Rubien's provider-neutral durable transcript into the existing chat
/// renderer contract. Provider payloads are never consulted on this read path.
enum StoredAssistantTranscriptProjection {
    static func messages(
        from detail: AssistantConversationDetail,
        attachmentIsAvailable: (StoredAssistantAttachment) -> Bool = { _ in false },
        attachmentThumbnailDataURL: (StoredAssistantAttachment) -> String? = { _ in nil }
    ) -> [ChatRenderMessage] {
        let attachments = Dictionary(grouping: detail.attachments, by: \.entryId)
        return detail.entries.enumerated().map { index, entry in
            let presentation: [ChatAttachmentPresentation] = (
                attachments[entry.id] ?? []
            ).compactMap { attachment in
                guard let id = UUID(uuidString: attachment.id) else { return nil }
                return ChatAttachmentPresentation(
                    id: id,
                    displayName: attachment.displayName,
                    kind: attachment.kind == .image ? .image : .text,
                    byteCount: attachment.byteCount,
                    isAvailable: attachmentIsAvailable(attachment),
                    thumbnailDataURL: attachmentThumbnailDataURL(attachment)
                )
            }
            return message(entry, seq: index, attachments: presentation)
        }
    }

    private static func message(
        _ entry: AssistantTranscriptEntry,
        seq: Int,
        attachments: [ChatAttachmentPresentation]
    ) -> ChatRenderMessage {
        if entry.hasUnavailablePayloadDetails {
            return ChatRenderMessage(
                role: .notice,
                body: "Some stored Assistant details use a newer format and are unavailable.",
                seq: seq
            )
        }
        switch entry.kind {
        case .user:
            return ChatRenderMessage(
                role: .user,
                body: entry.body,
                seq: seq,
                attachments: attachments
            )
        case .assistant:
            return ChatRenderMessage(
                role: .assistant,
                body: entry.body,
                turnStatus: entry.status == .interrupted ? .interrupted : nil,
                seq: seq
            )
        case .tool:
            return ChatRenderMessage(role: .tool, body: entry.body, seq: seq)
        case .notice:
            return ChatRenderMessage(role: .notice, body: entry.body, seq: seq)
        case .paper:
            return ChatRenderMessage(role: .paper, body: entry.body, seq: seq)
        case .unknown(let rawValue):
            let body = entry.body.isEmpty
                ? "Unsupported Assistant transcript item (\(rawValue))."
                : entry.body
            return ChatRenderMessage(role: .notice, body: body, seq: seq)
        }
    }
}
#endif
