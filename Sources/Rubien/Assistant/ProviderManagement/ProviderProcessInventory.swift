#if os(macOS)
import Foundation

/// Consumes the entire process listing without retaining unrelated commands.
/// Retains the current line, parent IDs, and matching PIDs; command text is discarded.
final class ProviderProcessInventory: @unchecked Sendable {
    private let lock = NSLock()
    private let root: String
    private let launcher: String
    private var pending = Data()
    private var holders = Set<Int>()
    private var parents: [Int: Int] = [:]
    private let ignoredAncestor: Int?

    init(root: String, launcher: String, ignoringDescendantsOf ancestor: Int? = nil) {
        self.root = root
        self.launcher = launcher
        ignoredAncestor = ancestor
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            inspect(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
    }

    func finish() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            inspect(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        guard let ignoredAncestor else { return holders.sorted() }
        return holders.filter { pid in
            var ancestor = pid
            var visited = Set<Int>()
            while let parent = parents[ancestor], parent > 0, visited.insert(ancestor).inserted {
                if parent == ignoredAncestor { return false }
                ancestor = parent
            }
            return true
        }.sorted()
    }

    private func inspect(_ line: String) {
        let columns = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard columns.count == 3, let pid = Int(columns[0]), let parent = Int(columns[1]) else { return }
        if ignoredAncestor != nil { parents[pid] = parent }
        guard pid != Int(ProcessInfo.processInfo.processIdentifier) else { return }
        let command = String(columns[2])
        if containsPath(root + "/", in: command, isDirectory: true)
            || containsPath(launcher, in: command, isDirectory: false) {
            holders.insert(pid)
        }
    }

    private func containsPath(_ path: String, in command: String, isDirectory: Bool) -> Bool {
        func boundary(_ character: Character) -> Bool {
            character.isWhitespace || character == "\"" || character == "'"
        }
        var start = command.startIndex
        while let range = command.range(of: path, range: start..<command.endIndex) {
            let beginsPath = range.lowerBound == command.startIndex || boundary(command[command.index(before: range.lowerBound)])
            let endsPath = isDirectory || range.upperBound == command.endIndex || boundary(command[range.upperBound])
            if beginsPath && endsPath { return true }
            start = range.upperBound
        }
        return false
    }
}
#endif
