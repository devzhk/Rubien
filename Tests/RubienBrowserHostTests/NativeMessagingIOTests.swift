import Foundation
import XCTest
@testable import RubienBrowserHost
import RubienCore

final class NativeMessagingIOTests: XCTestCase {
    func testMaximumHTMLFitsEnvelopeAfterWorstCaseJSONEscaping() {
        let worstCaseEscapedHTMLBytes = BrowserClipContract.maximumHTMLBytes * 6
        let metadataHeadroom = 1024 * 1024

        XCTAssertGreaterThanOrEqual(
            BrowserClipContract.maximumMessageBytes,
            worstCaseEscapedHTMLBytes + metadataHeadroom
        )
    }

    func testFrameUsesNativeLengthPrefix() throws {
        let payload = Data("{\"ok\":true}".utf8)
        let frame = try NativeMessagingIO.frame(payload)

        XCTAssertEqual(frame.count, payload.count + 4)
        XCTAssertEqual(NativeMessagingIO.decodeNativeUInt32(frame.prefix(4)), UInt32(payload.count))
        XCTAssertEqual(frame.dropFirst(4), payload)
    }

    func testOversizedResponseBecomesBoundedFailure() throws {
        let oversized = BrowserClipResponse.success(
            result: .created,
            title: String(
                repeating: "x",
                count: BrowserClipContract.maximumResponseMessageBytes + 1
            ),
            kind: .webpage
        )

        let payload = try NativeMessagingIO.responsePayload(oversized)
        XCTAssertLessThanOrEqual(
            payload.count,
            BrowserClipContract.maximumResponseMessageBytes
        )
        let decoded = try JSONDecoder().decode(BrowserClipResponse.self, from: payload)
        XCTAssertEqual(decoded.error?.code, "response-too-large")
    }

    func testReadsVersionedRequest() throws {
        let request = BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "preview",
            page: BrowserClipPage(url: "https://example.com", title: "Example")
        )
        let payload = try JSONEncoder().encode(request)
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(try NativeMessagingIO.frame(payload))
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            try NativeMessagingIO.readRequest(from: pipe.fileHandleForReading),
            request
        )
    }

    func testLongLivedReaderReturnsNilAtCleanEOF() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()

        XCTAssertNil(
            try NativeMessagingIO.readRequestOrEOF(from: pipe.fileHandleForReading)
        )
    }

    func testLongLivedReaderReadsTwoFrames() throws {
        let first = BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "preview",
            page: BrowserClipPage(url: "https://example.com")
        )
        let second = BrowserClipRequest(
            version: BrowserClipContract.protocolVersion,
            command: "confirm",
            confirmationID: "confirmation",
            downloadPDF: false
        )
        let pipe = Pipe()
        for request in [first, second] {
            let payload = try JSONEncoder().encode(request)
            pipe.fileHandleForWriting.write(try NativeMessagingIO.frame(payload))
        }
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            try NativeMessagingIO.readRequestOrEOF(from: pipe.fileHandleForReading),
            first
        )
        XCTAssertEqual(
            try NativeMessagingIO.readRequestOrEOF(from: pipe.fileHandleForReading),
            second
        )
        XCTAssertNil(
            try NativeMessagingIO.readRequestOrEOF(from: pipe.fileHandleForReading)
        )
    }

    func testRejectsOversizedMessageBeforeReadingPayload() throws {
        var oversized = UInt32(BrowserClipContract.maximumMessageBytes + 1)
        let header = withUnsafeBytes(of: &oversized) { Data($0) }
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(header)
        try pipe.fileHandleForWriting.close()

        XCTAssertThrowsError(
            try NativeMessagingIO.readRequest(from: pipe.fileHandleForReading)
        ) { error in
            XCTAssertEqual(
                error as? BrowserClipHostError,
                .messageTooLarge(BrowserClipContract.maximumMessageBytes + 1)
            )
        }
    }

    func testCallerOriginMustMatchManifestOrigin() throws {
        XCTAssertNoThrow(
            try RubienBrowserHost.validateCallerOrigin(
                BrowserClipContract.allowedExtensionOrigin
            )
        )
        XCTAssertThrowsError(
            try RubienBrowserHost.validateCallerOrigin("chrome-extension://attacker/")
        ) { error in
            XCTAssertEqual(
                error as? BrowserClipHostError,
                .unauthorizedOrigin("chrome-extension://attacker/")
            )
        }
    }
}
