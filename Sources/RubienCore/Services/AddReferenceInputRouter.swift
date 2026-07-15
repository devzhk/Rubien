import Foundation

/// Classifies the app's single Add Reference input before handing it to one of
/// the existing paper, website, or PDF/Markdown flows. Unlike `ImportRouter`,
/// this router intentionally treats otherwise-unrecognized text as a title
/// search and otherwise-unrecognized HTTP(S) URLs as web clips.
public enum AddReferenceInputRouter {
    public enum InvalidReason: Equatable, Sendable {
        case emptyInput
        case directory
        case invalidHTTPURL
        case unsupportedURLScheme
        case unsupportedFileType(pathExtension: String?)
        case relativeFilePath
    }

    public enum Route: Equatable, Sendable {
        case metadata(String)
        case website(String)
        case file(String)
        case invalid(InvalidReason)
    }

    public static func classify(
        _ rawInput: String,
        probe: (String) -> ImportRouter.PathProbe = ImportRouter.defaultProbe
    ) -> Route {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            return .invalid(.emptyInput)
        }

        switch ImportRouter.classify(source: input, probe: probe) {
        case .existingPath(let isDirectory):
            guard !isDirectory else {
                return .invalid(.directory)
            }
            return supportedFileInput(input)

        case .resolver:
            return .metadata(input)

        case .downloadImport:
            return .file(input)

        case .stdin:
            return .metadata(input)

        case .unroutable:
            let lowercasedInput = input.lowercased()
            if lowercasedInput.hasPrefix("http://") || lowercasedInput.hasPrefix("https://") {
                guard let url = URL(string: input), url.host != nil else {
                    return .invalid(.invalidHTTPURL)
                }
                return .website(input)
            }

            if ImportRouter.hasURLScheme(input) {
                return .invalid(.unsupportedURLScheme)
            }

            if looksLikeFileInput(input) {
                return supportedFileInput(input)
            }

            return .metadata(input)
        }
    }

    private static func supportedFileInput(_ input: String) -> Route {
        let pathExtension: String
        if let url = URL(string: input), ImportRouter.hasURLScheme(input) {
            pathExtension = url.pathExtension.lowercased()
        } else {
            let expandedPath = (input as NSString).expandingTildeInPath
            guard expandedPath.hasPrefix("/") else {
                return .invalid(.relativeFilePath)
            }
            pathExtension = (input as NSString).pathExtension.lowercased()
        }

        guard ImportSourceKind(pathExtension: pathExtension) != nil else {
            return .invalid(.unsupportedFileType(
                pathExtension: pathExtension.isEmpty ? nil : pathExtension
            ))
        }
        return .file(input)
    }

    private static func looksLikeFileInput(_ input: String) -> Bool {
        let pathExtension = (input as NSString).pathExtension.lowercased()
        return ImportSourceKind(pathExtension: pathExtension) != nil
            || input.hasPrefix("/")
            || input.hasPrefix("~/")
            || input.hasPrefix("./")
            || input.hasPrefix("../")
    }
}
