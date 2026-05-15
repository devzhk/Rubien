import Foundation

#if canImport(os)
import os.log

public typealias RubienLogger = os.Logger
#else

public struct RubienLogger: Sendable {
    let subsystem: String
    let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public func info(_ message: String)   { write("INFO",   message) }
    public func notice(_ message: String) { write("NOTICE", message) }
    public func error(_ message: String)  { write("ERROR",  message) }
    public func debug(_ message: String)  { /* dropped on Linux */ }

    private func write(_ level: String, _ message: String) {
        let line = "[\(subsystem)/\(category)] \(level): \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
#endif
