import Foundation
import RubienCore

enum NativeMessagingIO {
    static func readRequest(from input: FileHandle = .standardInput) throws -> BrowserClipRequest {
        guard let request = try readRequestOrEOF(from: input) else {
            throw BrowserClipHostError.incompleteMessage
        }
        return request
    }

    /// Reads one message from a long-lived native messaging port. A clean EOF
    /// means the extension popup closed; a partial frame remains an error.
    static func readRequestOrEOF(
        from input: FileHandle = .standardInput
    ) throws -> BrowserClipRequest? {
        var header = input.readData(ofLength: 4)
        if header.isEmpty { return nil }
        if header.count < 4 {
            header.append(try readExactly(4 - header.count, from: input))
        }
        let length = Int(decodeNativeUInt32(header))
        guard length <= BrowserClipContract.maximumMessageBytes else {
            throw BrowserClipHostError.messageTooLarge(length)
        }
        let payload = try readExactly(length, from: input)
        do {
            return try JSONDecoder().decode(BrowserClipRequest.self, from: payload)
        } catch {
            throw BrowserClipHostError.malformedMessage(error.localizedDescription)
        }
    }

    static func writeResponse(
        _ response: BrowserClipResponse,
        to output: FileHandle = .standardOutput
    ) throws {
        output.write(try frame(responsePayload(response)))
    }

    static func responsePayload(_ response: BrowserClipResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = try encoder.encode(response)
        if payload.count > BrowserClipContract.maximumResponseMessageBytes {
            payload = try encoder.encode(BrowserClipResponse.failure(
                code: "response-too-large",
                message: "Rubien could not return this unusually large import preview."
            ))
        }
        return payload
    }

    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= Int(UInt32.max) else {
            throw BrowserClipHostError.messageTooLarge(payload.count)
        }
        var length = UInt32(payload.count)
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        return data
    }

    static func decodeNativeUInt32(_ data: Data) -> UInt32 {
        precondition(data.count == 4)
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer)
        }
        return value
    }

    private static func readExactly(_ count: Int, from input: FileHandle) throws -> Data {
        guard count >= 0 else { throw BrowserClipHostError.incompleteMessage }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = input.readData(ofLength: count - data.count)
            guard !chunk.isEmpty else {
                throw BrowserClipHostError.incompleteMessage
            }
            data.append(chunk)
        }
        return data
    }
}
