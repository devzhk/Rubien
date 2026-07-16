/// Canonical access policy for Rubien's native MCP catalog.
///
/// Keep this list in lockstep with the native and npm MCP catalogs. Both the
/// CLI server and the Assistant approval gate consume it so an unclassified
/// Rubien tool can never silently inherit read-only treatment.
public enum RubienMCPToolAccess: Sendable, Equatable {
    case read
    case write
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
