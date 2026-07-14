#if os(macOS)
import AppKit
import UniformTypeIdentifiers

enum OpenPanelPicker {
    @MainActor
    static func pickBibTeXFile() -> URL? {
        pickSingleFile(
            title: "Import BibTeX",
            prompt: "Import",
            allowedContentTypes: [type(forExtension: "bib", fallback: .plainText)]
        )
    }

    @MainActor
    static func pickRISFile() -> URL? {
        pickSingleFile(
            title: "Import RIS",
            prompt: "Import",
            allowedContentTypes: [type(forExtension: "ris", fallback: .plainText)]
        )
    }

    @MainActor
    static func pickPDFFile() -> URL? {
        pickSingleFile(
            title: "Choose PDF",
            prompt: "Choose",
            allowedContentTypes: [.pdf]
        )
    }

    /// Multi-select picker for the Import PDF/Markdown toolbar action.
    /// Returns [] when cancelled.
    @MainActor
    static func pickImportableFiles() -> [URL] {
        let panel = configuredPanel(
            title: String(localized: "Import PDF/Markdown", bundle: .module),
            prompt: String(localized: "Import", bundle: .module),
            allowedContentTypes: [
                .pdf,
                type(forExtension: "md", fallback: .plainText),
                type(forExtension: "markdown", fallback: .plainText),
            ]
        )
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    private static func pickSingleFile(title: String, prompt: String, allowedContentTypes: [UTType]) -> URL? {
        let panel = configuredPanel(title: title, prompt: prompt, allowedContentTypes: allowedContentTypes)
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    private static func configuredPanel(title: String, prompt: String, allowedContentTypes: [UTType]) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = allowedContentTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        return panel
    }

    private static func type(forExtension pathExtension: String, fallback: UTType) -> UTType {
        UTType(filenameExtension: pathExtension) ?? fallback
    }
}
#endif
