import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if !canImport(Darwin)
// Linux has no Objective-C autorelease pool — provide a no-op so the
// `while autoreleasepool { … }` chunked read in `sha256(of:)` compiles
// untouched on swift-corelibs-foundation.
@inline(__always)
private func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T {
    try body()
}
#endif

/// SHA-256 of a file's contents, returned as lowercase hex.
///
/// Streams the file in 1MB chunks rather than `Data(contentsOf:)` so a 50MB
/// PDF doesn't allocate 50MB. Used by `PDFAssetCache` for content-addressed
/// asset versioning and by sync push to detect "no actual change" uploads.
public enum PDFContentHasher {

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_048_576
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: chunkSize),
                  !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
