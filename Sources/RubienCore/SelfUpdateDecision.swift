import Foundation

public struct GitHubRelease: Decodable, Equatable {
    public let tagName: String
    public let assets: [Asset]
    public struct Asset: Decodable, Equatable {
        public let name: String
        public let browserDownloadUrl: URL
        public init(name: String, browserDownloadUrl: URL) {
            self.name = name; self.browserDownloadUrl = browserDownloadUrl
        }
    }
    public init(tagName: String, assets: [Asset]) { self.tagName = tagName; self.assets = assets }
}

public enum UpdateDecision: Equatable {
    case upToDate(current: String, latest: String)
    case updateAvailable(latest: String, tarball: URL, signature: URL)
    case noAsset(latest: String)
}

/// True iff dotted-integer version `a` is strictly greater than `b`.
public func semverGreater(_ a: String, _ b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// True iff `v` is a plain dotted-integer version (e.g. "0.1.8") — our release
/// tags. Non-numeric (prerelease/build suffixes) are never guessed at.
public func isPlainNumeric(_ v: String) -> Bool {
    // omittingEmptySubsequences: false so "1..2", ".1", "1." (empty components) are rejected.
    let parts = v.split(separator: ".", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && Int($0) != nil }
}

public func decideUpdate(currentMarketing: String, release: GitHubRelease) -> UpdateDecision {
    let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
    // Only act on plain numeric versions; anything else → treat as up-to-date.
    guard isPlainNumeric(latest), isPlainNumeric(currentMarketing),
          semverGreater(latest, currentMarketing) else {
        return .upToDate(current: currentMarketing, latest: latest)
    }
    guard let tar = release.assets.first(where: { $0.name.hasSuffix("-linux-x86_64.tar.gz") }),
          let sig = release.assets.first(where: { $0.name == tar.name + ".sig" }) else {
        return .noAsset(latest: latest)
    }
    return .updateAvailable(latest: latest, tarball: tar.browserDownloadUrl,
                            signature: sig.browserDownloadUrl)
}
