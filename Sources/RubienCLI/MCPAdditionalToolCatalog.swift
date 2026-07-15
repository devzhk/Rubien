import Foundation
import RubienCore

/// The remainder of the native catalog beyond the document-reading tools in
/// `MCPToolCatalog.swift`. Routes intentionally mirror `mcp-server/src/tools`.
enum MCPAdditionalToolCatalog {
    static let readTools: [MCPTool] = [
        listPropertiesTool,
        listViewsTool,
        citeTool,
        listStylesTool,
        exportTool,
        syncStatusTool,
    ]

    static let writeTools: [MCPTool] = [
        createReferenceTool,
        updateReferenceTool,
        deleteReferenceTool,
        createPropertyTool,
        updatePropertyTool,
        deletePropertyTool,
        createOptionTool,
        updateOptionTool,
        deleteOptionTool,
        createViewTool,
        updateViewTool,
        deleteViewTool,
        downloadPDFTool,
    ]

    // MARK: Additional reads

    private static let listPropertiesTool = MCPTool(
        name: "rubien_list_properties",
        description: "List property definitions. Returns PropertyDefinitionDTO[] with options inlined. Pass `ids` and/or `names` to filter; selectors are unioned and override `visible`. Unresolved selectors fail loudly.",
        inputSchema: objectSchema(properties: [
            "ids": ["type": "array", "items": ["type": "integer"], "description": "Repeatable property IDs to include."],
            "names": ["type": "array", "items": ["type": "string"], "description": "Exact, case-sensitive property names to include."],
            "visible": ["type": "boolean", "description": "Restrict to user-visible properties. Ignored when ids/names are supplied."],
        ]),
        isImage: false,
        buildArgv: { args in
            var argv = ["properties"]
            if try mcpBool(args, "visible") == true { argv.append("--visible") }
            for id in try mcpIntArray(args, "ids") ?? [] { argv += ["--id", String(id)] }
            for name in try mcpStringArray(args, "names") ?? [] { argv += ["--name", name] }
            return argv
        }
    )

    private static let listViewsTool = MCPTool(
        name: "rubien_list_views",
        description: "List saved database views (persisted filter/sort/group configurations). Returns DatabaseViewDTO[]. To run a view, pass its id as `view` to rubien_list_references.",
        inputSchema: objectSchema(),
        isImage: false,
        buildArgv: { _ in ["views"] }
    )

    private static let citeTool = MCPTool(
        name: "rubien_cite",
        description: "Generate formatted citations for one or more references. Formats: text, bibliography, or docx-cc. Use arbitrary CSL style IDs from rubien_list_styles.",
        inputSchema: objectSchema(properties: [
            "ids": ["type": "array", "items": ["type": "integer"], "minItems": 1, "description": "Reference IDs to cite"],
            "style": ["type": "string", "description": "Citation style (default apa)"],
            "format": ["type": "string", "enum": ["text", "bibliography", "docx-cc"]],
        ], required: ["ids"]),
        isImage: false,
        buildArgv: { args in
            guard let ids = try mcpIntArray(args, "ids"), !ids.isEmpty else {
                throw MCPToolError.invalidArguments("Missing required argument: ids")
            }
            var argv = ["cite"] + ids.map(String.init)
            mcpAppendString(&argv, "--style", try mcpString(args, "style"))
            mcpAppendString(&argv, "--format", try mcpString(args, "format"))
            return argv
        }
    )

    private static let listStylesTool = MCPTool(
        name: "rubien_list_styles",
        description: "List all available citation styles (built-in + installed CSL).",
        inputSchema: objectSchema(),
        isImage: false,
        buildArgv: { _ in ["styles"] }
    )

    private static let exportTool = MCPTool(
        name: "rubien_export",
        description: "Export the library (or a subset) as JSON, BibTeX, or RIS.",
        inputSchema: objectSchema(properties: [
            "format": ["type": "string", "enum": ["json", "bibtex", "ris"], "description": "Default is json"],
        ]),
        wrapsTextExport: true,
        isImage: false,
        buildArgv: { args in
            var argv = ["export"]
            mcpAppendString(&argv, "--format", try mcpString(args, "format"))
            return argv
        }
    )

    private static let syncStatusTool = MCPTool(
        name: "rubien_get_sync_status",
        description: "Report the current CloudKit sync state without starting the engine.",
        inputSchema: objectSchema(),
        isImage: false,
        buildArgv: { _ in ["sync", "status"] }
    )

    // MARK: Reference writes

    private static let createReferenceTool = MCPTool(
        name: "rubien_create_reference",
        description: "Create reference(s) from exactly one of `source`, inline `bibtex`, or `title`. `source` accepts identifiers, paper URLs, files, or folders. Stdin is unavailable over MCP.",
        inputSchema: objectSchema(properties: [
            "source": ["type": "string", "description": "Identifier, paper URL, file URL, absolute path, or folder path"],
            "bibtex": ["type": "string", "description": "Inline BibTeX, possibly containing multiple entries"],
            "title": ["type": "string", "description": "Title for a minimal manual entry"],
            "downloadPdf": ["type": "boolean", "description": "Tri-state PDF fetch override; absent lets the router decide"],
            "format": ["type": "string", "enum": ["bib", "ris", "md"]],
            "property": ["type": "string", "description": "Folder route property"],
            "value": ["type": "string", "description": "Folder route property value"],
        ]),
        access: .write,
        timeout: 300,
        isImage: false,
        buildArgv: { args in
            let source = try mcpString(args, "source")
            let bibtex = try mcpString(args, "bibtex")
            let title = try mcpString(args, "title")
            guard [source, bibtex, title].compactMap({ $0 }).count == 1 else {
                throw MCPToolError.invalidArguments("provide exactly one of source / bibtex / title")
            }
            if source?.trimmingCharacters(in: .whitespacesAndNewlines) == "-" {
                throw MCPToolError.invalidArguments("stdin ('-') is not supported over MCP — pass a path, URL, or identifier")
            }
            var argv = ["add"]
            mcpAppendString(&argv, "--source", source)
            mcpAppendString(&argv, "--bibtex", bibtex)
            mcpAppendString(&argv, "--title", title)
            if let download = try mcpBool(args, "downloadPdf") {
                argv.append(download ? "--download-pdf" : "--no-download-pdf")
            }
            mcpAppendString(&argv, "--format", try mcpString(args, "format"))
            mcpAppendString(&argv, "--property", try mcpString(args, "property"))
            mcpAppendString(&argv, "--value", try mcpString(args, "value"))
            return argv
        }
    )

    private static let updateReferenceTool = MCPTool(
        name: "rubien_update_reference",
        description: "Modify an existing reference's metadata fields and/or property cells in one atomic call. `clearFields` nulls metadata; `properties` is keyed by exact property name or digit-only id.",
        inputSchema: objectSchema(properties: updateReferenceProperties, required: ["id"]),
        access: .write,
        destructive: true,
        isImage: false,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            var argv = ["update", String(id)]
            let stringFields: [(String, String)] = [
                ("title", "--title"), ("authors", "--authors"), ("type", "--type"),
                ("journal", "--journal"), ("volume", "--volume"), ("issue", "--issue"),
                ("pages", "--pages"), ("doi", "--doi"), ("url", "--url"),
                ("abstract", "--abstract"), ("notes", "--notes"), ("publisher", "--publisher"),
                ("isbn", "--isbn"), ("issn", "--issn"), ("language", "--language"),
                ("edition", "--edition"), ("readingStatus", "--reading-status"),
            ]
            for (key, flag) in stringFields {
                mcpAppendString(&argv, flag, try mcpString(args, key))
            }
            mcpAppendInt(&argv, "--year", try mcpInt(args, "year"))
            for field in try mcpStringArray(args, "clearFields") ?? [] {
                argv += ["--clear-field", field]
            }
            if args.index(forKey: "properties") != nil {
                guard let payload = args["properties"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(payload) else {
                    throw MCPToolError.invalidArguments("`properties` must be an object")
                }
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
                argv += ["--properties", String(decoding: data, as: UTF8.self)]
            }
            return argv
        }
    )

    private static let deleteReferenceTool = MCPTool(
        name: "rubien_delete_reference",
        description: "Permanently delete one or more references by ID.",
        inputSchema: objectSchema(properties: [
            "ids": ["type": "array", "items": ["type": "integer"], "minItems": 1],
        ], required: ["ids"]),
        access: .write,
        destructive: true,
        idempotent: false,
        isImage: false,
        buildArgv: { args in
            guard let ids = try mcpIntArray(args, "ids"), !ids.isEmpty else {
                throw MCPToolError.invalidArguments("Missing required argument: ids")
            }
            return ["delete", "--force"] + ids.map(String.init)
        }
    )

    // MARK: Property and option writes

    private static let createPropertyTool = MCPTool(
        name: "rubien_create_property",
        description: "Create a custom property definition. All-digit names are rejected.",
        inputSchema: objectSchema(properties: [
            "name": ["type": "string"],
            "type": ["type": "string", "enum": propertyTypes],
            "options": ["type": "string", "description": "Comma-separated select options"],
        ], required: ["name", "type"]),
        access: .write,
        isImage: false,
        buildArgv: { args in
            guard let name = try mcpString(args, "name"), let type = try mcpString(args, "type") else {
                throw MCPToolError.invalidArguments("Missing required arguments: name and type")
            }
            var argv = ["properties", "--create", "--name", name, "--type", type]
            mcpAppendString(&argv, "--options", try mcpString(args, "options"))
            return argv
        }
    )

    private static let updatePropertyTool = MCPTool(
        name: "rubien_update_property",
        description: "Rename a property definition and/or change its UI visibility.",
        inputSchema: objectSchema(properties: [
            "id": ["type": "integer"], "name": ["type": "string"], "visible": ["type": "boolean"],
        ], required: ["id"]),
        access: .write,
        isImage: false,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else { throw MCPToolError.invalidArguments("Missing required argument: id") }
            var argv = ["properties", "--update", "--id", String(id)]
            mcpAppendString(&argv, "--name", try mcpString(args, "name"))
            if let visible = try mcpBool(args, "visible") { argv += ["--set-visible", String(visible)] }
            return argv
        }
    )

    private static let deletePropertyTool = MCPTool(
        name: "rubien_delete_property",
        description: "Remove a custom property definition and all its values. Built-in properties cannot be deleted.",
        inputSchema: integerIDSchema,
        access: .write,
        destructive: true,
        isImage: false,
        buildArgv: { args in ["properties", "--delete", String(try requiredInt(args, "id"))] }
    )

    private static let createOptionTool = MCPTool(
        name: "rubien_create_option",
        description: "Append a select option. Against the built-in Tags property this creates a Tag.",
        inputSchema: objectSchema(properties: [
            "propertyId": ["type": "integer"], "value": ["type": "string"], "color": ["type": "string"],
        ], required: ["propertyId", "value"]),
        access: .write,
        isImage: false,
        buildArgv: { args in
            var argv = ["properties", "--add-option", "--id", String(try requiredInt(args, "propertyId")), "--value", try requiredString(args, "value")]
            mcpAppendString(&argv, "--color", try mcpString(args, "color"))
            return argv
        }
    )

    private static let updateOptionTool = MCPTool(
        name: "rubien_update_option",
        description: "Rename and/or recolor an existing select option. Renames bulk-update affected references.",
        inputSchema: objectSchema(properties: [
            "propertyId": ["type": "integer"], "option": ["type": "string"],
            "name": ["type": "string"], "color": ["type": "string"],
        ], required: ["propertyId", "option"]),
        access: .write,
        isImage: false,
        buildArgv: { args in
            var argv = ["properties", "--update-option", "--id", String(try requiredInt(args, "propertyId")), "--option", try requiredString(args, "option")]
            mcpAppendString(&argv, "--to", try mcpString(args, "name"))
            mcpAppendString(&argv, "--color", try mcpString(args, "color"))
            return argv
        }
    )

    private static let deleteOptionTool = MCPTool(
        name: "rubien_delete_option",
        description: "Delete a select option. Use `replaceWith` to migrate affected rows or `clearInUse` to clear it.",
        inputSchema: objectSchema(properties: [
            "propertyId": ["type": "integer"], "value": ["type": "string"],
            "replaceWith": ["type": "string"], "clearInUse": ["type": "boolean"],
        ], required: ["propertyId", "value"]),
        access: .write,
        destructive: true,
        isImage: false,
        buildArgv: { args in
            var argv = ["properties", "--delete-option", "--id", String(try requiredInt(args, "propertyId")), "--value", try requiredString(args, "value")]
            mcpAppendString(&argv, "--replace-with", try mcpString(args, "replaceWith"))
            mcpAppendFlag(&argv, "--clear-in-use", try mcpBool(args, "clearInUse"))
            return argv
        }
    )

    // MARK: View writes

    private static let createViewTool = MCPTool(
        name: "rubien_create_view",
        description: "Create a saved view from JSON filter, sort, and grouping configurations.",
        inputSchema: objectSchema(properties: [
            "name": ["type": "string"], "filters": ["type": "string"],
            "sorts": ["type": "string"], "groupBy": ["type": "string"],
        ], required: ["name"]),
        access: .write,
        isImage: false,
        buildArgv: { args in
            var argv = ["views", "--create", "--name", try requiredString(args, "name")]
            mcpAppendString(&argv, "--filters", try mcpString(args, "filters"))
            mcpAppendString(&argv, "--sorts", try mcpString(args, "sorts"))
            mcpAppendString(&argv, "--group-by", try mcpString(args, "groupBy"))
            return argv
        }
    )

    private static let updateViewTool = MCPTool(
        name: "rubien_update_view",
        description: "Change a saved view's name.",
        inputSchema: objectSchema(properties: ["id": ["type": "integer"], "name": ["type": "string"]], required: ["id", "name"]),
        access: .write,
        isImage: false,
        buildArgv: { args in ["views", "--rename", String(try requiredInt(args, "id")), "--name", try requiredString(args, "name")] }
    )

    private static let deleteViewTool = MCPTool(
        name: "rubien_delete_view",
        description: "Remove a saved view by ID.",
        inputSchema: integerIDSchema,
        access: .write,
        destructive: true,
        isImage: false,
        buildArgv: { args in ["views", "--delete", String(try requiredInt(args, "id"))] }
    )

    private static let downloadPDFTool = MCPTool(
        name: "rubien_download_pdf",
        description: "Download and attach the open-access PDF for an existing reference. Use `force` to replace an existing attachment.",
        inputSchema: objectSchema(properties: [
            "id": ["type": "integer"], "force": ["type": "boolean"],
        ], required: ["id"]),
        access: .write,
        timeout: 300,
        isImage: false,
        buildArgv: { args in
            var argv = ["pdf", "download", String(try requiredInt(args, "id"))]
            mcpAppendFlag(&argv, "--force", try mcpBool(args, "force"))
            return argv
        }
    )

    // MARK: Schemas

    private static let propertyTypes = ["string", "url", "number", "singleSelect", "multiSelect", "date", "checkbox"]

    private static let integerIDSchema = objectSchema(
        properties: ["id": ["type": "integer"]],
        required: ["id"]
    )

    private static let updateReferenceProperties: [String: Any] = {
        var properties: [String: Any] = [
            "id": ["type": "integer"],
            "year": ["type": "integer"],
            "clearFields": ["type": "array", "items": ["type": "string"]],
            "properties": propertyEditSchema,
        ]
        for name in ["title", "authors", "type", "journal", "volume", "issue", "pages", "doi", "url", "abstract", "notes", "publisher", "isbn", "issn", "language", "edition", "readingStatus"] {
            properties[name] = ["type": "string"]
        }
        return properties
    }()

    private static let propertyEditSchema: [String: Any] = [
        "type": "object",
        "description": "Property-cell edits keyed by property name or digit-only id: scalar/array = replace, {add/remove} = incremental multiSelect edit, null = clear.",
        "additionalProperties": [
            "anyOf": [
                ["type": "string"],
                ["type": "number"],
                ["type": "boolean"],
                ["type": "null"],
                ["type": "array", "items": ["type": "string"]],
                [
                    "type": "object",
                    "properties": [
                        "add": ["type": "array", "items": ["type": "string"]],
                        "remove": ["type": "array", "items": ["type": "string"]],
                    ],
                    "additionalProperties": false,
                ],
            ],
        ],
    ]

    private static func objectSchema(
        properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !properties.isEmpty { schema["additionalProperties"] = false }
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
}

private func requiredInt(_ args: [String: Any], _ key: String) throws -> Int {
    guard let value = try mcpInt(args, key) else {
        throw MCPToolError.invalidArguments("Missing required argument: \(key)")
    }
    return value
}

private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = try mcpString(args, key) else {
        throw MCPToolError.invalidArguments("Missing required argument: \(key)")
    }
    return value
}

private func mcpIntArray(_ args: [String: Any], _ key: String) throws -> [Int]? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    guard let values = value as? [Any] else {
        throw MCPToolError.invalidArguments("`\(key)` must be an array of integers")
    }
    return try values.map { item in
        guard let integer = mcpExactInt(item) else {
            throw MCPToolError.invalidArguments("`\(key)` must be an array of integers")
        }
        return integer
    }
}
