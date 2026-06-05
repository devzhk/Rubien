import ArgumentParser
import Foundation
import RubienCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Crypto
import Glibc
#endif

struct SelfUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update rubien-cli in place from the latest signed GitHub release (Linux only)")

    @Flag(name: .long, help: "Report the latest available version as JSON; change nothing.")
    var check = false

    // Raw 32-byte ed25519 public key (hex) for the dedicated Linux-CLI signing key.
    static let publicKeyHex = "636600b7b7064e14aadc8cc18b721b7203ce0d7b8e935840bb5bf526d6e16831"
    static let latestURL = URL(string:
        "https://api.github.com/repos/devzhk/Rubien-releases/releases/latest")!

    func run() async throws {
        #if os(Linux)
        try await SelfUpdater.run(checkOnly: check)
        #else
        print("rubien-cli updates with Rubien.app (Sparkle); self-update is Linux-only.")
        #endif
    }
}

#if os(Linux)
enum SelfUpdater {
    struct Err: Error, CustomStringConvertible { let description: String }
    struct CheckReport: Encodable { let current: String; let latest: String; let updateAvailable: Bool }

    static func run(checkOnly: Bool) async throws {
        let release = try await fetchLatest()
        let decision = decideUpdate(currentMarketing: RubienCLIVersion.marketing, release: release)
        if checkOnly {
            let (latest, available): (String, Bool)
            switch decision {
            case .upToDate(_, let l): (latest, available) = (l, false)
            case .updateAvailable(let l, _, _): (latest, available) = (l, true)
            case .noAsset(let l): (latest, available) = (l, false)
            }
            printJSON(CheckReport(current: RubienCLIVersion.marketing,
                                  latest: latest, updateAvailable: available))
            return
        }
        switch decision {
        case .upToDate(let c, _): print("rubien-cli \(c) is already the latest.")
        case .noAsset(let l): throw Err(description: "release \(l) has no linux-x86_64 tarball + .sig")
        case .updateAvailable(let latest, let tarURL, let sigURL):
            try await apply(latest: latest, tarURL: tarURL, sigURL: sigURL)
        }
    }

    static func fetchLatest() async throws -> GitHubRelease {
        var req = URLRequest(url: SelfUpdate.latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("rubien-cli", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            throw Err(description: "GitHub API request failed")
        }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(GitHubRelease.self, from: data)
    }

    static func apply(latest: String, tarURL: URL, sigURL: URL) async throws {
        let exeDir = (try resolveSelfPath() as NSString).deletingLastPathComponent
        try probeWritable(dir: exeDir)

        // Stage UNDER the install dir: same filesystem (so the final rename can't
        // EXDEV) and exec-allowed (so we can run the staged binary's `version`
        // even when /tmp is mounted noexec).
        let work = exeDir + "/.rubien-update-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: work) }
        let extract = work + "/x"
        try FileManager.default.createDirectory(atPath: extract, withIntermediateDirectories: true)

        let tar = try await download(tarURL, to: work + "/cli.tar.gz")
        let sig = try await download(sigURL, to: work + "/cli.tar.gz.sig")
        try verifySignature(tarball: tar, signature: sig)   // BEFORE extracting
        try runProcess("/usr/bin/tar", ["-xzf", tar, "-C", extract])

        // Extracted tree must contain the binary AND a Linux *.resources bundle.
        let newBin = extract + "/rubien-cli"
        let resources = try FileManager.default.contentsOfDirectory(atPath: extract)
            .filter { $0.hasSuffix(".resources") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBin)
        guard FileManager.default.isExecutableFile(atPath: newBin), !resources.isEmpty else {
            throw Err(description: "downloaded tarball is missing rubien-cli or its *.resources bundle")
        }

        // Rollback defense: trust the SIGNED binary's own attested build (compiled
        // in → inside the signature), NOT the mutable release tag, and only upgrade
        // if strictly newer. Stops an old signed binary served under a higher tag.
        // The staged binary is signature-verified and on an exec-allowed FS;
        // `version` needs no resources.
        let stagedBuild = try stagedBuildNumber(binary: newBin)
        guard stagedBuild > RubienCLIVersion.build else {
            throw Err(description: "refusing: downloaded build \(stagedBuild) is not newer than current \(RubienCLIVersion.build)")
        }

        try replace(newBinary: newBin, resources: resources.map { extract + "/" + $0 }, into: exeDir)
        print("rubien-cli updated to \(latest) (build \(stagedBuild)).")
    }

    static func stagedBuildNumber(binary: String) throws -> Int {
        struct V: Decodable { let build: Int }
        let out = try runProcess(binary, ["version"])
        guard let data = out.data(using: .utf8),
              let v = try? JSONDecoder().decode(V.self, from: data) else {
            throw Err(description: "could not read staged binary version")
        }
        return v.build
    }

    static func probeWritable(dir: String) throws {
        let probe = dir + "/.rubien-write-probe"
        guard FileManager.default.createFile(atPath: probe, contents: Data()) else {
            throw Err(description: "no write access to \(dir) — install where rubien-cli is writable")
        }
        try? FileManager.default.removeItem(atPath: probe)
    }

    static func verifySignature(tarball: String, signature: String) throws {
        let msg = try Data(contentsOf: URL(fileURLWithPath: tarball))
        let sig = try Data(contentsOf: URL(fileURLWithPath: signature))
        guard let raw = Data(hexString: SelfUpdate.publicKeyHex) else {
            throw Err(description: "bad embedded public key")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        guard key.isValidSignature(sig, for: msg) else {
            throw Err(description: "signature verification FAILED — refusing to update")
        }
    }

    // Transactional replace with rollback: back up existing resource bundles,
    // swap in the new ones, then atomic-rename the binary LAST. Any failure
    // restores the backups so a partial update can't brick the install.
    static func replace(newBinary: String, resources: [String], into exeDir: String) throws {
        let fm = FileManager.default
        var backups: [(restored: String, backup: String)] = []
        var movedIn: [String] = []          // newly-placed paths (no prior backup)
        func rollback() {
            for p in movedIn.reversed() { try? fm.removeItem(atPath: p) }
            for b in backups.reversed() {
                try? fm.removeItem(atPath: b.restored)
                try? fm.moveItem(atPath: b.backup, toPath: b.restored)
            }
        }
        do {
            for src in resources {
                let dest = exeDir + "/" + (src as NSString).lastPathComponent
                if fm.fileExists(atPath: dest) {
                    let bak = dest + ".bak"
                    if fm.fileExists(atPath: bak) { try fm.removeItem(atPath: bak) }
                    try fm.moveItem(atPath: dest, toPath: bak)
                    backups.append((restored: dest, backup: bak))
                }
                try fm.moveItem(atPath: src, toPath: dest)
                movedIn.append(dest)
            }
            let staged = exeDir + "/.rubien-cli.new"
            if fm.fileExists(atPath: staged) { try fm.removeItem(atPath: staged) }
            try fm.moveItem(atPath: newBinary, toPath: staged)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
            movedIn.append(staged)
            // rename(2) atomically overwrites the (possibly running) binary on Linux.
            guard rename(staged, exeDir + "/rubien-cli") == 0 else {
                throw Err(description: "failed to replace \(exeDir)/rubien-cli")
            }
        } catch {
            rollback()
            throw error
        }
        for b in backups { try? fm.removeItem(atPath: b.backup) }  // success: drop backups
    }

    static func download(_ url: URL, to path: String) async throws -> String {
        var req = URLRequest(url: url); req.setValue("rubien-cli", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            throw Err(description: "download failed: \(url.lastPathComponent)")
        }
        try data.write(to: URL(fileURLWithPath: path)); return path
    }

    @discardableResult
    static func runProcess(_ launch: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        // Separate pipes: `version`'s JSON must not be polluted by a stderr warning.
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw Err(description: "\(launch) failed: \(err.isEmpty ? out : err)")
        }
        return out
    }

    static func resolveSelfPath() throws -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { readlink("/proc/self/exe", $0.baseAddress, $0.count - 1) }
        guard n > 0 else { throw Err(description: "cannot resolve /proc/self/exe") }
        buf[n] = 0
        return String(cString: buf)
    }
}

private extension Data {
    init?(hexString s: String) {
        let c = Array(s); guard c.count % 2 == 0 else { return nil }
        var b = [UInt8](); b.reserveCapacity(c.count / 2); var i = 0
        while i < c.count { guard let v = UInt8(String(c[i...i+1]), radix: 16) else { return nil }
            b.append(v); i += 2 }
        self.init(b)
    }
}
#endif
