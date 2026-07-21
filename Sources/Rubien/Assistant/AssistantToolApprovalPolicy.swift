#if os(macOS)
import RubienCore

/// One exact-name policy shared by the Claude subprocess boundary and the chat UI.
/// Read-only tools are answered inside the provider as soon as Claude asks, so a
/// delayed UI event can never leave the CLI blocked on its stdin approval bus.
enum AssistantToolApprovalPolicy {
    private static let silentReadBuiltins: Set<String> = [
        "ToolSearch", "Read", "Glob", "Grep", "LS", "NotebookRead", "WebFetch", "WebSearch",
    ]

    static func isSilentReadTool(_ toolName: String) -> Bool {
        if let rubienName = bareRubienToolName(toolName) {
            return rubienName == ChatPaperPresentation.toolName
                || RubienMCPToolPolicy.access(for: rubienName) == .read
        }
        return silentReadBuiltins.contains(toolName)
    }

    static func isUnknownRubienTool(_ toolName: String) -> Bool {
        guard let bare = bareRubienToolName(toolName) else { return false }
        return bare != ChatPaperPresentation.toolName
            && RubienAppSchedulingContract.access(for: bare) == nil
            && RubienMCPToolPolicy.access(for: bare) == nil
    }

    private static func bareRubienToolName(_ toolName: String) -> String? {
        if toolName.hasPrefix(ReferenceAttribution.claudeToolPrefix) {
            return String(toolName.dropFirst(ReferenceAttribution.claudeToolPrefix.count))
        }
        let codexPrefix = "\(ReferenceAttribution.serverName)/"
        if toolName.hasPrefix(codexPrefix) {
            return String(toolName.dropFirst(codexPrefix.count))
        }
        if toolName.hasPrefix("rubien_") { return toolName }
        return nil
    }
}
#endif
