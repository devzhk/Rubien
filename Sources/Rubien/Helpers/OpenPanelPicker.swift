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
    static func pickCitationStyleFiles() -> [URL] {
        pickFiles(
            title: "Import citation styles",
            prompt: "Import",
            allowedContentTypes: [.xml, type(forExtension: "csl", fallback: .xml)]
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

    @MainActor
    static func pickZoteroFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Zotero Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    private static func pickSingleFile(title: String, prompt: String, allowedContentTypes: [UTType]) -> URL? {
        let panel = configuredPanel(title: title, prompt: prompt, allowedContentTypes: allowedContentTypes)
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    private static func pickFiles(title: String, prompt: String, allowedContentTypes: [UTType]) -> [URL] {
        let panel = configuredPanel(title: title, prompt: prompt, allowedContentTypes: allowedContentTypes)
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
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
