import SwiftUI
import WebKit
import RubienCore

struct WebImportView: View {
    let onSave: (Reference) -> Void

    @Environment(\.dismiss) private var dismiss

    @StateObject private var clipperExtractor = ClipperWebMetadataExtractor()
    @State private var url = ""
    @State private var clipperError: String?
    @State private var isSaving = false

    private var urlValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        ZStack {
            HiddenWKWebViewHost(
                configure: { configuration in
                    configuration.userContentController.add(
                        clipperExtractor.extractionManager,
                        name: ReaderExtractionManager.readerResultHandlerName
                    )
                },
                onCreate: { webView in
                    clipperExtractor.registerWebView(webView)
                }
            )
            .frame(width: 4, height: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Button(String(localized: "common.cancel", bundle: .module)) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Spacer()
                    Text("Web clip", bundle: .module)
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(String(localized: "common.save", bundle: .module)) {
                            saveWebpageWithClipper()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!urlValid || isSaving)
                    }
                }
                .padding()

                Divider()

                Form {
                    Section(String(localized: "Web page", bundle: .module)) {
                        TextField(String(localized: "Page URL", bundle: .module), text: $url, prompt: Text(verbatim: "https://…"))
                            .textContentType(.URL)
                            .disabled(isSaving)
                        Text("Rubien extracts the title, abstract, and article body from the page.", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let clipperError {
                        Section {
                            Text(clipperError)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button(String(localized: "Save URL only (skip extraction)", bundle: .module)) {
                                saveWebpageURLOnlyFallback()
                            }
                            .disabled(isSaving)
                        }
                    }

                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 460, height: clipperError == nil ? 300 : 380)
        .interactiveDismissDisabled(isSaving)
    }

    private func saveWebpageWithClipper() {
        clipperError = nil
        isSaving = true
        let urlTrimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            defer { isSaving = false }

            do {
                let result = try await clipperExtractor.extract(urlString: urlTrimmed)
                let reference = Reference(
                    title: result.title,
                    authors: result.authors,
                    url: result.resolvedURLString,
                    abstract: result.abstract,
                    webContent: result.webContent,
                    siteName: result.siteHost,
                    referenceType: .webpage
                )
                onSave(reference)
                dismiss()
            } catch {
                clipperError = error.localizedDescription
            }
        }
    }

    private func saveWebpageURLOnlyFallback() {
        let urlTrimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: urlTrimmed)?.host
        let reference = Reference(
            title: host ?? String(localized: "Web page", bundle: .module),
            url: urlTrimmed,
            siteName: host,
            referenceType: .webpage
        )
        onSave(reference)
        dismiss()
    }
}
