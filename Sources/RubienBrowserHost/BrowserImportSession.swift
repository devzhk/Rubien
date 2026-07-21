import RubienCore
#if os(macOS)
import AppKit
#endif

/// One Chrome native-messaging port owns one prepared import. This keeps
/// preview and confirmation bound to the same helper process and guarantees a
/// popup close discards temporary downloads without touching the database.
struct BrowserImportSession {
    private var service: BrowserClipImportService?
    private let openURL: (URL) async -> Bool
    private var prepared: PreparedBrowserImport?

    init(
        service: BrowserClipImportService? = nil,
        openURL: @escaping (URL) async -> Bool = BrowserImportSession.openRubienURL
    ) {
        self.service = service
        self.openURL = openURL
    }

    mutating func handle(_ request: BrowserClipRequest) async throws -> BrowserClipResponse {
        guard request.version == BrowserClipContract.protocolVersion else {
            throw BrowserClipHostError.unsupportedVersion(request.version)
        }
        switch request.command {
        case "preview":
            prepared?.discard()
            prepared = nil
            let service = resolvedService()
            let next = try await service.prepareClip(request)
            prepared = next
            return .confirmation(next.preview)
        case "confirm":
            guard let confirmationID = request.confirmationID else {
                throw BrowserClipHostError.missingConfirmation
            }
            guard let current = prepared,
                  current.confirmationID == confirmationID else {
                throw BrowserClipHostError.staleConfirmation
            }
            prepared = nil
            let service = resolvedService()
            return try await service.confirm(
                current,
                downloadedPDFPath: request.downloadedPDFPath,
                downloadPDF: request.downloadPDF ?? true
            )
        case "open":
            guard let destination = BrowserClipDeepLink.destination(
                referenceID: request.referenceID,
                intakeID: request.intakeID
            ), let url = BrowserClipDeepLink.url(for: destination) else {
                throw BrowserClipHostError.invalidOpenDestination
            }
            guard await openURL(url) else {
                throw BrowserClipHostError.couldNotOpenRubien
            }
            return .opened(destination)
        default:
            throw BrowserClipHostError.unsupportedCommand
        }
    }

    mutating func close() {
        prepared?.discard()
        prepared = nil
    }

    private mutating func resolvedService() -> BrowserClipImportService {
        if let service { return service }
        let service = BrowserClipImportService()
        self.service = service
        return service
    }

    static func enclosingApplicationURL(for executableURL: URL) -> URL? {
        let helperDirectory = executableURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        guard helperDirectory.lastPathComponent == "Helpers" else { return nil }
        let contentsDirectory = helperDirectory.deletingLastPathComponent()
        guard contentsDirectory.lastPathComponent == "Contents" else { return nil }
        let applicationURL = contentsDirectory.deletingLastPathComponent()
        guard applicationURL.pathExtension.lowercased() == "app" else { return nil }
        return applicationURL
    }

    private static func openRubienURL(_ url: URL) async -> Bool {
#if os(macOS)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        guard let applicationURL = enclosingApplicationURL(for: executableURL) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { application, error in
                    continuation.resume(returning: application != nil && error == nil)
                }
            }
        }
#else
        return false
#endif
    }
}
