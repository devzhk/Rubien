#if os(macOS)
import Foundation
import XCTest

@testable import Rubien

final class AgentProcessOutputDrainTests: XCTestCase {
    func testDrainReadsEveryByteUntilEOF() throws {
        let pipe = Pipe()
        let expected = Data(repeating: 0xA5, count: 32 * 1_024)
        try pipe.fileHandleForWriting.write(contentsOf: expected)
        try pipe.fileHandleForWriting.close()

        var received = Data()
        AgentProcessOutputDrain.drain(pipe.fileHandleForReading) {
            received.append($0)
        }

        XCTAssertEqual(received, expected)
    }

    func testDrainTreatsHandleClosedWhileActiveAsEOF() throws {
        let pipe = Pipe()
        let expected = Data(repeating: 0xA5, count: 64 * 1_024)
        let received = LockedData()
        let receivedFirstChunk = expectation(description: "received first chunk")
        let allowNextRead = DispatchSemaphore(value: 0)
        let drainFinished = expectation(description: "drain finished")

        DispatchQueue.global(qos: .utility).async {
            AgentProcessOutputDrain.drain(pipe.fileHandleForReading) {
                received.append($0)
                receivedFirstChunk.fulfill()
                allowNextRead.wait()
            }
            drainFinished.fulfill()
        }

        try pipe.fileHandleForWriting.write(contentsOf: expected)
        wait(for: [receivedFirstChunk], timeout: 1)

        // Model shutdown closing the output handles after a chunk is delivered
        // but before the drain's next read.
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.close()
        allowNextRead.signal()

        wait(for: [drainFinished], timeout: 1)
        XCTAssertEqual(received.value, expected)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }
}
#endif
