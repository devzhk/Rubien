import Foundation

/// Canonical access policy for Rubien's native MCP catalog.
///
/// Keep this list in lockstep with the native and npm MCP catalogs. Both the
/// CLI server and the Assistant approval gate consume it so an unclassified
/// Rubien tool can never silently inherit read-only treatment.
public enum RubienMCPToolAccess: Sendable, Equatable {
    case read
    case write
}

/// Shared wire contract for the presentation tool exposed only inside Rubien's
/// Assistant content channel. This deliberately remains outside the public MCP
/// policy sets below.
public enum RubienAppPresentationContract {
    public static let toolName = "rubien_present_document_cards"
    public static let maximumItemCount = 10
    public static let maximumResultBytes = 64 * 1_024
    public static let maximumTitleLength = 500
    public static let maximumAuthorsLength = 1_000
    public static let maximumBadgeLength = 64
    public static let maximumURLBytes = 2_048

    /// External cards are still unverified candidates, but their badge should
    /// reflect the intake path Rubien will use when the user chooses Add. This
    /// keeps a recognized paper URL from looking (and later behaving) like a
    /// generic web clip.
    public static func externalCandidateBadge(for rawURL: String) -> String {
        switch AddReferenceInputRouter.classify(rawURL, probe: { _ in
            ImportRouter.PathProbe(exists: false, isDirectory: false)
        }) {
        case .metadata:
            return "Paper candidate"
        case .file:
            guard let url = URL(string: rawURL) else { return "Document candidate" }
            return url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
                ? "PDF candidate"
                : "Document candidate"
        case .website, .invalid:
            return "Web candidate"
        }
    }
}

public enum RubienMCPToolPolicy {
    public static let readToolNames: Set<String> = [
        "rubien_search_references",
        "rubien_list_references",
        "rubien_get_reference",
        "rubien_list_properties",
        "rubien_list_views",
        "rubien_cite",
        "rubien_list_styles",
        "rubien_export",
        "rubien_get_pdf_info",
        "rubien_render_pdf_page",
        "rubien_read_text",
        "rubien_read_annotations",
        "rubien_grep_text",
        "rubien_get_sync_status",
        "rubien_reading_activity",
    ]

    public static let writeToolNames: Set<String> = [
        "rubien_create_reference",
        "rubien_update_reference",
        "rubien_delete_reference",
        "rubien_create_property",
        "rubien_update_property",
        "rubien_delete_property",
        "rubien_create_option",
        "rubien_update_option",
        "rubien_delete_option",
        "rubien_create_view",
        "rubien_update_view",
        "rubien_delete_view",
        "rubien_download_pdf",
    ]

    public static let allToolNames = readToolNames.union(writeToolNames)

    public static func access(for toolName: String) -> RubienMCPToolAccess? {
        if readToolNames.contains(toolName) { return .read }
        if writeToolNames.contains(toolName) { return .write }
        return nil
    }
}

/// Shared contract for scheduling tools exposed only inside Rubien's
/// interactive Assistant content channel. Keeping the enablement key and access
/// classification here prevents the MCP host and approval gate from drifting.
/// This deliberately remains outside the public native/Node MCP policy above.
public enum RubienAppSchedulingContract {
    public static let environmentKey = "RUBIEN_APP_SCHEDULING"
    public static let environmentValue = "1"
    public static let createToolName = "rubien_create_scheduled_job"
    public static let createToolAccess = RubienMCPToolAccess.write

    public static func access(for toolName: String) -> RubienMCPToolAccess? {
        toolName == createToolName ? createToolAccess : nil
    }
}
