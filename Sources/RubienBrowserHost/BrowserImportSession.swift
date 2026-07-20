import RubienCore

/// One Chrome native-messaging port owns one prepared import. This keeps
/// preview and confirmation bound to the same helper process and guarantees a
/// popup close discards temporary downloads without touching the database.
struct BrowserImportSession {
    private let service: BrowserClipImportService
    private var prepared: PreparedBrowserImport?

    init(service: BrowserClipImportService = BrowserClipImportService()) {
        self.service = service
    }

    mutating func handle(_ request: BrowserClipRequest) async throws -> BrowserClipResponse {
        guard request.version == BrowserClipContract.protocolVersion else {
            throw BrowserClipHostError.unsupportedVersion(request.version)
        }
        switch request.command {
        case "preview":
            prepared?.discard()
            prepared = nil
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
            return try await service.confirm(
                current,
                downloadedPDFPath: request.downloadedPDFPath,
                downloadPDF: request.downloadPDF ?? true
            )
        default:
            throw BrowserClipHostError.unsupportedCommand
        }
    }

    mutating func close() {
        prepared?.discard()
        prepared = nil
    }
}
