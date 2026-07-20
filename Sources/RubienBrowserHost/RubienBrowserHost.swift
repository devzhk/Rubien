import Foundation
import RubienCore

@main
enum RubienBrowserHost {
    static func main() async {
        do {
            try validateCallerOrigin(CommandLine.arguments.dropFirst().first)
            try await runSession()
        } catch let error as BrowserClipHostError {
            writeTerminalFailure(.failure(
                code: error.code,
                message: error.localizedDescription
            ))
            log(error.localizedDescription)
        } catch {
            writeTerminalFailure(.failure(
                code: "internal-error",
                message: error.localizedDescription
            ))
            log(error.localizedDescription)
        }
    }

    private static func runSession() async throws {
        var session = BrowserImportSession()
        defer { session.close() }

        while let request = try NativeMessagingIO.readRequestOrEOF() {
            let response: BrowserClipResponse
            do {
                response = try await session.handle(request)
            } catch let error as BrowserClipHostError {
                response = .failure(code: error.code, message: error.localizedDescription)
                log(error.localizedDescription)
            } catch {
                response = .failure(code: "internal-error", message: error.localizedDescription)
                log(error.localizedDescription)
            }

            do {
                try NativeMessagingIO.writeResponse(response)
            } catch {
                log("Could not write native messaging response: \(error.localizedDescription)")
                return
            }
        }
    }

    private static func writeTerminalFailure(_ response: BrowserClipResponse) {
        do {
            try NativeMessagingIO.writeResponse(response)
        } catch {
            log("Could not write native messaging response: \(error.localizedDescription)")
        }
    }

    static func validateCallerOrigin(_ origin: String?) throws {
        guard origin == BrowserClipContract.allowedExtensionOrigin else {
            throw BrowserClipHostError.unauthorizedOrigin(origin)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("rubien-browser-host: \(message)\n".utf8))
    }
}
