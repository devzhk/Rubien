# Codex Model Auto-Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The assistant's Codex model/effort pickers reflect whatever the *installed* codex CLI reports via its `model/list` app-server RPC, with a "Codex default" option that sends no model at all (codex resolves its own config), replacing the stale hardcoded `gpt-5.5` lists.

**Architecture:** A new `CodexModelCatalog` actor spawns a short-lived `codex app-server`, runs `initialize → initialized → model/list`, and memoizes the decoded catalog per resolved binary path. The catalog feeds pickers only — no turn ever waits on it. "Codex default" = `modelOverride == nil` = the `model` key is omitted from `thread/start`; the resolved model is read back from the `thread/start` response and surfaced via a new `AgentEvent.modelResolved`. Effort stays explicit-always on `turn/start`. Claude is untouched.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15 target), JSON-RPC 2.0 over stdio against `codex app-server`, XCTest with the `fake-codex-app-server.py` fixture harness.

**Spec:** `Docs/superpowers/specs/2026-07-10-codex-model-autodiscovery-design.md` (committed as `611dc19`). Read it before starting; §7 maps the codex-review findings each design point answers.

## Global Constraints

- Swift toolchain 6.x; macOS deployment target 15.0; run tests with `swift test --filter RubienTests` (NEVER bare `swift test` — RubienCLITests hangs the run).
- Every NEW file in `Tests/RubienTests/` MUST be wrapped in `#if os(macOS)` … `#endif` (Linux CI compiles all test targets; the Mac-only `Rubien` module doesn't exist there).
- Cross-platform-looking sources that touch CF need the explicit-`import CoreFoundation` guard — not expected in this plan, but if you add a CFBoolean check anywhere, follow `CodexAppServerProtocol.swift:2-4`.
- Logging via `RubienLogger` (never `import os.Logger` directly).
- UI copy: the model row is **"Codex default"** — never the word "Auto" (collides with the composer's Ask/Auto approvals switch; spec §3).
- Each task ends with a commit whose message ends with:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_018wiXcogfpj6L2Xbh4fUZQy
  ```
- Between Tasks 5 and 7 the Codex sidebar picker is transiently empty in the running app (descriptor slimmed before the dynamic rows land). Builds and tests stay green throughout; the branch merges as a whole.

---

### Task 1: Wire codec — model-catalog types, `model/list`, resolved-model readback

**Files:**
- Modify: `Sources/Rubien/Assistant/CodexAppServerProtocol.swift`
- Test: `Tests/RubienTests/CodexAppServerProtocolTests.swift`

**Interfaces:**
- Consumes: existing `CodexAppServerProtocol.request(id:method:params:)` private encoder, existing decode patterns.
- Produces (later tasks rely on these exact shapes):
  ```swift
  struct CodexEffortInfo: Sendable, Equatable {
      let value: String            // wire slug: "low" … "ultra"
      let label: String            // display: "Low" … "Ultra" ("xhigh" → "xHigh")
      let description: String?
  }
  struct CodexModelInfo: Sendable, Equatable, Identifiable {
      let id: String               // slug for thread/start `model`
      let displayName: String
      let description: String?
      let efforts: [CodexEffortInfo]   // server order; may be empty
      let defaultEffort: String?
      let isDefault: Bool
      let hidden: Bool
  }
  struct CodexCatalog: Sendable, Equatable {
      var models: [CodexModelInfo]
      var fetchedOK: Bool
      static let unavailable: CodexCatalog   // ([], false)
      var visibleModels: [CodexModelInfo]    // models.filter { !$0.hidden }
  }
  static func CodexAppServerProtocol.modelList(requestID: Int) -> String
  static func CodexAppServerProtocol.decodeModelList(_ result: [String: Any]) -> [CodexModelInfo]
  static func CodexAppServerProtocol.resolvedModel(fromThreadResponse result: [String: Any]) -> String?
  static func CodexEffortInfo.label(for value: String) -> String
  ```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RubienTests/CodexAppServerProtocolTests.swift` (inside the existing class and `#if os(macOS)`):

```swift
    // MARK: - model/list (model auto-discovery)

    /// Shape sanitized from a real codex 0.144.1 `model/list` capture (spec §2.1).
    private let modelListResult: [String: Any] = [
        "data": [
            [
                "id": "gpt-5.5", "model": "gpt-5.5", "displayName": "GPT-5.5",
                "description": "Frontier model.", "hidden": false, "isDefault": true,
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": "Fast"],
                    ["reasoningEffort": "medium", "description": "Balanced"],
                    ["reasoningEffort": "high", "description": "Deep"],
                    ["reasoningEffort": "xhigh", "description": "Extra deep"],
                ],
                "defaultReasoningEffort": "medium",
                "inputModalities": ["text", "image"], "futureUnknownField": 42,
            ],
            [
                "id": "gpt-5.6-sol", "model": "gpt-5.6-sol", "displayName": "GPT-5.6-Sol",
                "description": "Latest frontier agentic coding model.", "hidden": false,
                "isDefault": false,
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": "Fast"],
                    ["reasoningEffort": "max", "description": "Maximum"],
                    ["reasoningEffort": "ultra", "description": "Maximum + delegation"],
                ],
                "defaultReasoningEffort": "low",
            ],
            // Hidden entry — decoded, filtered only by visibleModels.
            ["id": "gpt-5.4", "displayName": "GPT-5.4", "hidden": true, "isDefault": false],
            // Missing efforts + displayName — falls back to id, empty efforts.
            ["id": "gpt-x-experimental"],
            // No usable id — dropped.
            ["displayName": "Ghost"],
        ]
    ]

    func testDecodeModelListMapsFieldsAndTolerartesUnknowns() {
        let models = CodexAppServerProtocol.decodeModelList(modelListResult)
        XCTAssertEqual(models.map(\.id), ["gpt-5.5", "gpt-5.6-sol", "gpt-5.4", "gpt-x-experimental"])

        let five5 = models[0]
        XCTAssertEqual(five5.displayName, "GPT-5.5")
        XCTAssertEqual(five5.description, "Frontier model.")
        XCTAssertTrue(five5.isDefault)
        XCTAssertFalse(five5.hidden)
        XCTAssertEqual(five5.efforts.map(\.value), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(five5.efforts.map(\.label), ["Low", "Medium", "High", "xHigh"])
        XCTAssertEqual(five5.defaultEffort, "medium")

        let sol = models[1]
        XCTAssertEqual(sol.efforts.map(\.value), ["low", "max", "ultra"])
        XCTAssertEqual(sol.efforts.map(\.label), ["Low", "Max", "Ultra"])
        XCTAssertEqual(sol.defaultEffort, "low")

        XCTAssertTrue(models[2].hidden)
        let experimental = models[3]
        XCTAssertEqual(experimental.displayName, "gpt-x-experimental", "missing displayName falls back to id")
        XCTAssertTrue(experimental.efforts.isEmpty)
        XCTAssertNil(experimental.defaultEffort)
        XCTAssertFalse(experimental.isDefault)
    }

    func testCodexCatalogVisibleModelsFiltersHidden() {
        let catalog = CodexCatalog(models: CodexAppServerProtocol.decodeModelList(modelListResult), fetchedOK: true)
        XCTAssertEqual(catalog.visibleModels.map(\.id), ["gpt-5.5", "gpt-5.6-sol", "gpt-x-experimental"])
        XCTAssertEqual(CodexCatalog.unavailable, CodexCatalog(models: [], fetchedOK: false))
    }

    func testDecodeModelListEmptyOrGarbageYieldsEmpty() {
        XCTAssertTrue(CodexAppServerProtocol.decodeModelList([:]).isEmpty)
        XCTAssertTrue(CodexAppServerProtocol.decodeModelList(["data": "not-an-array"]).isEmpty)
    }

    func testModelListRequestEncoding() throws {
        let line = CodexAppServerProtocol.modelList(requestID: 7)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(line.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "model/list")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual((object["params"] as? [String: Any])?.isEmpty, true)
    }

    /// The thread/start response reports the RESOLVED model — including when the
    /// request omitted `model` (Codex default; spec §2.2, verified 0.144.1).
    func testResolvedModelFromThreadResponse() {
        XCTAssertEqual(
            CodexAppServerProtocol.resolvedModel(fromThreadResponse:
                ["thread": ["id": "T1"], "model": "gpt-5.6-terra", "reasoningEffort": "max"]),
            "gpt-5.6-terra")
        XCTAssertNil(CodexAppServerProtocol.resolvedModel(fromThreadResponse: ["thread": ["id": "T1"]]))
        XCTAssertNil(CodexAppServerProtocol.resolvedModel(fromThreadResponse: ["model": ""]))
    }

    func testEffortLabelMapping() {
        XCTAssertEqual(CodexEffortInfo.label(for: "low"), "Low")
        XCTAssertEqual(CodexEffortInfo.label(for: "xhigh"), "xHigh")
        XCTAssertEqual(CodexEffortInfo.label(for: "ultra"), "Ultra")
        XCTAssertEqual(CodexEffortInfo.label(for: "some-new-tier"), "Some-New-Tier")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RubienTests.CodexAppServerProtocolTests 2>&1 | tail -20`
Expected: compile FAILURE — `CodexModelInfo`/`CodexCatalog`/`modelList` not defined.

- [ ] **Step 3: Implement the codec**

In `Sources/Rubien/Assistant/CodexAppServerProtocol.swift`, add after the `PendingCodexApproval` struct (around line 313):

```swift
// MARK: - Model catalog wire types (model/list — model auto-discovery)

/// One reasoning-effort level a model supports, from `supportedReasoningEfforts`.
struct CodexEffortInfo: Sendable, Equatable {
    let value: String
    let label: String
    let description: String?

    /// Display label for an effort slug, matching the static list's style
    /// ("xhigh" → "xHigh"); unknown future tiers just capitalize.
    static func label(for value: String) -> String {
        value == "xhigh" ? "xHigh" : value.capitalized
    }
}

/// One model the installed codex reports via `model/list` (spec §2.1). `isDefault`
/// is cosmetic only — it is rollout-state volatile and does NOT reflect the user's
/// `~/.codex` config (verified: config said terra, isDefault said gpt-5.5).
struct CodexModelInfo: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let description: String?
    let efforts: [CodexEffortInfo]
    let defaultEffort: String?
    let isDefault: Bool
    let hidden: Bool
}

/// A `model/list` fetch outcome. Three provider-level states: `nil` (backend has no
/// discovery — Claude), `fetchedOK == false` (discovery attempted, failed → degraded
/// picker), `fetchedOK == true` (live list).
struct CodexCatalog: Sendable, Equatable {
    var models: [CodexModelInfo]
    var fetchedOK: Bool

    static let unavailable = CodexCatalog(models: [], fetchedOK: false)

    /// The picker-facing list (`hidden` entries dropped).
    var visibleModels: [CodexModelInfo] { models.filter { !$0.hidden } }
}
```

In the `enum CodexAppServerProtocol`, add beside the other client encoders (after `turnInterrupt`, around line 448):

```swift
    /// The installed codex's own model catalog (local, fast, not auth-gated —
    /// verified back to codex 0.142.5; spec §2.1). Params are empty by design.
    static func modelList(requestID: Int) -> String {
        request(id: requestID, method: "model/list", params: [:])
    }
```

Add beside the History decoders (after `sessionSummary(fromThread:snippet:)`, around line 531):

```swift
    /// `model/list` result → decoded catalog entries. Tolerant: unknown fields are
    /// ignored, a missing `displayName` falls back to the slug, missing efforts
    /// decode as empty (the UI then offers the universal fallback four), and an
    /// entry without a usable id is dropped.
    static func decodeModelList(_ result: [String: Any]) -> [CodexModelInfo] {
        let data = result["data"] as? [[String: Any]] ?? []
        return data.compactMap { entry in
            let slug = (entry["id"] as? String) ?? (entry["model"] as? String)
            guard let id = slug, !id.isEmpty else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { effort -> CodexEffortInfo? in
                    guard let value = effort["reasoningEffort"] as? String, !value.isEmpty else { return nil }
                    return CodexEffortInfo(
                        value: value,
                        label: CodexEffortInfo.label(for: value),
                        description: effort["description"] as? String)
                }
            let displayName = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CodexModelInfo(
                id: id,
                displayName: displayName ?? id,
                description: entry["description"] as? String,
                efforts: efforts,
                defaultEffort: (entry["defaultReasoningEffort"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isDefault: entry["isDefault"] as? Bool ?? false,
                hidden: entry["hidden"] as? Bool ?? false)
        }
    }

    /// The model a `thread/start` / `thread/resume` response reports as RESOLVED for
    /// the thread — present even when the request omitted `model` (Codex default;
    /// spec §2.2). Optional: older servers may not report it.
    static func resolvedModel(fromThreadResponse result: [String: Any]) -> String? {
        guard let model = result["model"] as? String, !model.isEmpty else { return nil }
        return model
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RubienTests.CodexAppServerProtocolTests 2>&1 | tail -5`
Expected: all tests PASS (existing + 6 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/CodexAppServerProtocol.swift Tests/RubienTests/CodexAppServerProtocolTests.swift
git commit -m "feat(assistant): codex model/list codec + resolved-model readback"
```

---

### Task 2: `CodexModelCatalog` discovery actor + fake-server `model/list`

**Files:**
- Create: `Sources/Rubien/Assistant/CodexModelCatalog.swift`
- Modify: `Tests/RubienTests/Fixtures/fake-codex-app-server.py`
- Test: `Tests/RubienTests/CodexModelCatalogTests.swift` (new)

**Interfaces:**
- Consumes: Task 1's `CodexCatalog`/`decodeModelList`/`modelList(requestID:)`; existing `SpawnedAgentProcess.spawn(executablePath:arguments:environment:workingDirectory:)`, `.writeLine`, `.stdoutHandle`, `.stderrHandle`, `.signalGroup`, `.closeStdin`, `.wait()`; `CodexInvocation.arguments/environment`; `CodexProvider.resolveExecutable(override:)`.
- Produces:
  ```swift
  actor CodexModelCatalog {
      static let shared: CodexModelCatalog          // production singleton
      init(workingDirectory: URL = FileManager.default.temporaryDirectory)  // tests use fresh instances
      func catalog(executableOverride: String?, forceReload: Bool = false) async -> CodexCatalog
  }
  ```

- [ ] **Step 1: Teach the fake server `model/list`**

In `Tests/RubienTests/Fixtures/fake-codex-app-server.py`, add a handler in `Server.serve()` after the `elif method == "thread/read":` block (before the final `elif req_id is not None:`):

```python
            elif method == "model/list":
                # Model auto-discovery. Config `models` overrides the default set;
                # `modelListError: true` answers with a JSON-RPC error (old-codex /
                # failure path). Request count recorded for memoization assertions.
                cfg = load_config()
                record(modelListRequests=OBSERVED.get("modelListRequests", 0) + 1)
                if cfg.get("modelListError"):
                    emit({"jsonrpc": "2.0", "id": req_id,
                          "error": {"code": -32601, "message": "Method not found"}})
                else:
                    respond(req_id, {"data": cfg.get("models", [
                        {"id": "fake-default", "displayName": "Fake Default", "hidden": False,
                         "isDefault": True, "defaultReasoningEffort": "medium",
                         "description": "The fake default model.",
                         "supportedReasoningEfforts": [
                             {"reasoningEffort": "low", "description": "Fast"},
                             {"reasoningEffort": "medium", "description": "Balanced"},
                             {"reasoningEffort": "high", "description": "Deep"},
                         ]},
                        {"id": "fake-frontier", "displayName": "Fake Frontier", "hidden": False,
                         "isDefault": False, "defaultReasoningEffort": "low",
                         "supportedReasoningEfforts": [
                             {"reasoningEffort": "low", "description": "Fast"},
                             {"reasoningEffort": "max", "description": "Maximum"},
                             {"reasoningEffort": "ultra", "description": "Delegating"},
                         ]},
                        {"id": "fake-hidden", "displayName": "Fake Hidden", "hidden": True,
                         "isDefault": False},
                    ])})
```

Also update the module docstring's config-keys line to mention the new keys:

```python
Config keys (all optional): deltas[], assistantText (supports "{threadStarts}"),
usageLast{...}, approval{reason,command,availableDecisions[]}, unknownRequest(bool),
hang(bool), exitAfterTurnStart(int), models[] / modelListError (model/list).
History (3b-4): threads[] (thread/list data), searchHits[] (thread/search data,
each {thread,snippet}), transcript{turns:[…]} (thread/read). All record params.
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/RubienTests/CodexModelCatalogTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import Rubien

/// Drives `CodexModelCatalog` end-to-end against `fake-codex-app-server.py`:
/// fetch + decode, per-binary memoization (one spawn), forceReload, concurrent
/// callers sharing one in-flight fetch, and the failure → `.unavailable` paths.
final class CodexModelCatalogTests: XCTestCase {

    private var workspacesToClean: [URL] = []

    override func setUpWithError() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeServerPath)
    }

    override func tearDown() {
        for url in workspacesToClean { try? FileManager.default.removeItem(at: url) }
        workspacesToClean.removeAll()
    }

    func testFetchesAndDecodesModelList() async throws {
        let catalog = await freshCatalog().catalog(executableOverride: fakeServerPath)
        XCTAssertTrue(catalog.fetchedOK)
        XCTAssertEqual(catalog.models.map(\.id), ["fake-default", "fake-frontier", "fake-hidden"])
        XCTAssertEqual(catalog.visibleModels.map(\.id), ["fake-default", "fake-frontier"])
        XCTAssertEqual(catalog.models[0].defaultEffort, "medium")
        XCTAssertTrue(catalog.models[0].isDefault)
        XCTAssertEqual(catalog.models[1].efforts.map(\.value), ["low", "max", "ultra"])
    }

    func testMemoizesPerBinaryPath() async throws {
        let store = freshCatalog()
        _ = await store.catalog(executableOverride: fakeServerPath)
        _ = await store.catalog(executableOverride: fakeServerPath)
        XCTAssertEqual(try modelListRequests(), 1, "second call must hit the memo, not respawn")
    }

    func testForceReloadRefetches() async throws {
        let store = freshCatalog()
        _ = await store.catalog(executableOverride: fakeServerPath)
        let second = await store.catalog(executableOverride: fakeServerPath, forceReload: true)
        XCTAssertTrue(second.fetchedOK)
        XCTAssertEqual(try modelListRequests(), 2)
    }

    func testConcurrentCallersShareOneFetch() async throws {
        let store = freshCatalog()
        async let a = store.catalog(executableOverride: fakeServerPath)
        async let b = store.catalog(executableOverride: fakeServerPath)
        let (first, second) = await (a, b)
        XCTAssertTrue(first.fetchedOK)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try modelListRequests(), 1, "concurrent callers must join one in-flight fetch")
    }

    func testMissingBinaryIsUnavailable() async {
        let catalog = await freshCatalog().catalog(executableOverride: "/nonexistent/codex-binary")
        XCTAssertEqual(catalog, .unavailable)
    }

    func testServerErrorIsUnavailable() async throws {
        let store = freshCatalog(config: ["modelListError": true])
        let catalog = await store.catalog(executableOverride: fakeServerPath)
        XCTAssertEqual(catalog, .unavailable)
    }

    // MARK: Helpers

    /// A fresh actor with its own temp working directory (the fake writes its
    /// observed/config JSON to cwd; sharing a cwd across tests would collide).
    private func freshCatalog(config: [String: Any] = [:]) -> CodexModelCatalog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspacesToClean.append(dir)
        if !config.isEmpty {
            let data = try? JSONSerialization.data(withJSONObject: config)
            try? data?.write(to: dir.appendingPathComponent("fake-codex.json"))
        }
        currentWorkspace = dir
        return CodexModelCatalog(workingDirectory: dir)
    }

    private var currentWorkspace: URL?

    /// Poll the fake's observed file for the model/list request count (atomic writes;
    /// brief poll covers the child's write racing the assertion).
    private func modelListRequests() throws -> Int {
        let url = try XCTUnwrap(currentWorkspace).appendingPathComponent("fake-codex-observed.json")
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: url),
               let observed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let count = observed["modelListRequests"] as? Int {
                return count
            }
            usleep(100_000)
        }
        throw XCTSkip("observed file never appeared — fake server did not run")
    }

    private var fakeServerPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-codex-app-server.py")
            .path
    }
}
#endif
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter RubienTests.CodexModelCatalogTests 2>&1 | tail -10`
Expected: compile FAILURE — `CodexModelCatalog` not defined.

- [ ] **Step 4: Implement the actor**

Create `Sources/Rubien/Assistant/CodexModelCatalog.swift`:

```swift
#if os(macOS)
import Darwin
import Foundation
import RubienCore

// MARK: - Codex model catalog (model/list auto-discovery)
//
// Fetches the installed codex's OWN model list via a short-lived `codex app-server`
// (`initialize → initialized → model/list`; verified back to codex 0.142.5 — spec
// §2.1) and memoizes it per resolved binary path. The catalog feeds PICKERS ONLY:
// no turn ever waits on it (spec §4.1) — "Codex default" sends no model at all, and
// a pinned slug is sent verbatim, so a turn racing this fetch is already correct.
//
// Correctness internals (spec review finding #9): concurrent callers join one
// in-flight Task per path; a generation token invalidates on forceReload / path
// change so a stale completion cannot repopulate an invalidated entry.

actor CodexModelCatalog {
    /// Production singleton — Settings and every reader window share one result
    /// (one probe spawn per launch per binary path).
    static let shared = CodexModelCatalog()

    private let workingDirectory: URL
    private let logger = RubienLogger(subsystem: "com.rubien.assistant", category: "CodexModelCatalog")

    private var cache: [String: CodexCatalog] = [:]
    private var inflight: [String: Task<CodexCatalog, Never>] = [:]
    private var generation = 0

    /// Bound on the whole probe (spawn → handshake → model/list). Local IPC answers
    /// in well under a second; a wedged binary must not hold a picker open forever.
    private static let fetchTimeout: Double = 10

    init(workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.workingDirectory = workingDirectory
    }

    /// The catalog for the codex the override resolves to. Memoized; `forceReload`
    /// (Settings ▸ Recheck) drops the memo and refetches. Failure of any kind —
    /// unresolvable binary, spawn error, JSON-RPC error (a codex too old for
    /// `model/list`), timeout — returns `.unavailable`; callers degrade per §4.7.
    func catalog(executableOverride: String?, forceReload: Bool = false) async -> CodexCatalog {
        guard let path = CodexProvider.resolveExecutable(override: executableOverride) else {
            return .unavailable
        }
        if forceReload {
            cache[path] = nil
            inflight[path] = nil
            generation += 1
        }
        if let cached = cache[path] { return cached }
        if let running = inflight[path] { return await running.value }

        let gen = generation
        let directory = workingDirectory
        let task = Task { await Self.fetch(executablePath: path, workingDirectory: directory) }
        inflight[path] = task
        let result = await task.value
        // A forceReload / path invalidation that raced this fetch wins: don't let
        // the stale completion repopulate the entry it invalidated.
        if generation == gen {
            cache[path] = result
            if inflight[path] == task { inflight[path] = nil }
        }
        return result
    }

    /// One standalone probe: spawn, handshake, `model/list`, kill. Static + isolated
    /// from the actor so a slow probe never blocks other paths' lookups.
    private static func fetch(executablePath: String, workingDirectory: URL) async -> CodexCatalog {
        let arguments = CodexInvocation.arguments(
            rubienCLIPath: nil, libraryRoot: nil, webAccess: true)
        let environment = CodexInvocation.environment(
            binaryDirectory: (executablePath as NSString).deletingLastPathComponent)

        let process: SpawnedAgentProcess
        do {
            process = try SpawnedAgentProcess.spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory.path)
        } catch {
            return .unavailable
        }

        // Drain stderr so a chatty binary can't fill the pipe and block itself.
        let stderrHandle = process.stderrHandle
        DispatchQueue.global(qos: .utility).async {
            while !stderrHandle.availableData.isEmpty {}
        }
        // Watchdog: a wedged probe is killed, which EOFs the read loop below.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(fetchTimeout))
            process.signalGroup(SIGKILL)
        }

        var models: [CodexModelInfo]?
        process.writeLine(CodexAppServerProtocol.initialize(
            requestID: 1, clientName: "rubien-model-catalog",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
        do {
            for try await line in process.stdoutHandle.bytes.lines {
                guard case let .response(id, result, error)? =
                        CodexAppServerProtocol.decodeInbound(line: line) else { continue }
                if id == .number(1) {
                    guard error == nil else { break }
                    process.writeLine(CodexAppServerProtocol.initialized())
                    process.writeLine(CodexAppServerProtocol.modelList(requestID: 2))
                } else if id == .number(2) {
                    if error == nil, let result {
                        models = CodexAppServerProtocol.decodeModelList(result)
                    }
                    break
                }
            }
        } catch {
            // Early EOF / read error → unavailable below.
        }
        watchdog.cancel()
        process.closeStdin()
        process.signalGroup(SIGKILL)
        Task { _ = await process.wait() }   // reap off-path

        guard let models else { return .unavailable }
        return CodexCatalog(models: models, fetchedOK: true)
    }
}
#endif
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RubienTests.CodexModelCatalogTests 2>&1 | tail -8`
Expected: 6 tests PASS.

Also run: `swift test --filter RubienTests.CodexProviderTests 2>&1 | tail -5`
Expected: PASS (the fake-server change must not disturb existing turn tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Rubien/Assistant/CodexModelCatalog.swift Tests/RubienTests/CodexModelCatalogTests.swift Tests/RubienTests/Fixtures/fake-codex-app-server.py
git commit -m "feat(assistant): CodexModelCatalog discovery actor over model/list"
```

---

### Task 3: Provider seam — `availableModels()` + `AgentEvent.modelResolved`

**Files:**
- Modify: `Sources/Rubien/Assistant/AgentProvider.swift`
- Modify: `Sources/Rubien/Assistant/CodexProvider.swift`
- Modify: `Sources/Rubien/Assistant/ChatSessionController.swift` (minimal: handle the new event)
- Test: `Tests/RubienTests/CodexProviderTests.swift`

**Interfaces:**
- Consumes: Task 1 types; Task 2 `CodexModelCatalog.shared.catalog(executableOverride:)`.
- Produces:
  ```swift
  // AgentEvent gains:
  case modelResolved(model: String)
  // AgentProvider gains (default nil = "no discovery surface, use static"):
  func availableModels() async -> CodexCatalog?
  // ChatSessionController gains:
  @Published private(set) var resolvedModel: String?
  ```

- [ ] **Step 1: Check for other exhaustive switches over `AgentEvent`**

Run: `grep -rn "case .turnCompleted\|switch event\|switch $0" Sources Tests --include="*.swift" | grep -v CodexAppServerProtocol | head -20`
Expected: the only exhaustive production switch is `ChatSessionController.handle` (`Sources/Rubien/Assistant/ChatSessionController.swift:497`). If others appear, add the new case there too in Step 4.

- [ ] **Step 2: Write the failing tests**

Append to `Tests/RubienTests/CodexProviderTests.swift` (inside the class):

```swift
    // MARK: Model auto-discovery seam

    /// The fake's thread/start response carries `"model": "gpt-5.5-fake"` — the
    /// provider must surface it as `.modelResolved` (spec §2.2/§4.5), after
    /// `.sessionStarted` and before the turn's content events.
    func testThreadStartResolvedModelIsSurfaced() async throws {
        let workspace = try makeWorkspace()
        try writeConfig(["assistantText": "ok"], into: workspace)
        let provider = CodexProvider(executableOverride: fakeServerPath)
        defer { provider.shutdown() }

        let events = try await collectAllEvents(provider.send(turn: turn(workspace: workspace)))

        XCTAssertTrue(events.contains(.modelResolved(model: "gpt-5.5-fake")),
                      "thread/start's resolved model must stream as an event; got \(events)")
        let sessionIdx = try XCTUnwrap(events.firstIndex(of: .sessionStarted(sessionID: "TH-1")))
        let modelIdx = try XCTUnwrap(events.firstIndex(of: .modelResolved(model: "gpt-5.5-fake")))
        XCTAssertGreaterThan(modelIdx, sessionIdx)
    }

    func testAvailableModelsDelegatesToCatalog() async throws {
        let provider = CodexProvider(executableOverride: fakeServerPath)
        let catalog = await provider.availableModels()
        XCTAssertEqual(catalog?.fetchedOK, true)
        XCTAssertEqual(catalog?.visibleModels.map(\.id), ["fake-default", "fake-frontier"])
    }
```

(`makeWorkspace()`, `writeConfig(_:into:)`, `turn(workspace:)`, and `collectAllEvents(_:)` are this test class's existing helpers — `CodexProviderTests.swift:737/745` and the pattern at `:110-125`. `availableModels` spawns its own probe in the shared temp directory, so no workspace setup is needed for the second test.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter RubienTests.CodexProviderTests 2>&1 | tail -10`
Expected: compile FAILURE — `.modelResolved` / `availableModels` not defined.

- [ ] **Step 4: Implement**

(a) `Sources/Rubien/Assistant/AgentProvider.swift` — add the event case after `.sessionStarted` (line ~118):

```swift
    /// The model the runtime RESOLVED for this conversation — reported by codex's
    /// `thread/start`/`thread/resume` response, including (especially) when the
    /// request omitted `model` ("Codex default": codex applies its own config
    /// chain — spec §2.2). Claude never emits this.
    case modelResolved(model: String)
```

(b) Same file — add to the `AgentProvider` protocol after `searchSessions` (line ~342):

```swift
    /// The models the installed runtime reports it supports, for the model picker.
    /// Three states (spec §4.3): `nil` — this backend has no discovery surface
    /// (Claude → static list); `.fetchedOK == false` — discovery attempted and
    /// failed (→ degraded picker); otherwise the live list. Never blocks a turn.
    func availableModels() async -> CodexCatalog?
```

And to the extension (after the `searchSessions` default, line ~349):

```swift
    func availableModels() async -> CodexCatalog? { nil }
```

(c) `Sources/Rubien/Assistant/CodexProvider.swift` — store the override and implement. In `CodexProvider`, change the stored properties + init (lines 30-35):

```swift
    private let connection: CodexAppServerConnection
    private let executableOverride: String?

    init(executableOverride: String? = nil, contentChannel: MCPContentChannel? = nil) {
        self.executableOverride = executableOverride
        self.connection = CodexAppServerConnection(
            executableOverride: executableOverride, contentChannel: contentChannel)
    }
```

Add after `sessionTranscript` (line ~90):

```swift
    /// The installed codex's own model catalog (memoized per binary — one probe
    /// spawn per launch; spec §4.1). Feeds pickers only.
    func availableModels() async -> CodexCatalog? {
        await CodexModelCatalog.shared.catalog(executableOverride: executableOverride)
    }
```

(d) Same file, in `CodexAppServerConnection.startTurn` — surface the resolved model from BOTH thread paths. Replace the thread-resolution block (the `do {` body starting `let threadID: String` through `continuation.yield(.sessionStarted(sessionID: threadID))`, lines ~305-336) with:

```swift
            let threadID: String
            var resolvedModel: String?
            if let resume = request.resumeSessionID, !resume.isEmpty {
                if srv.activeThreadID == resume {
                    threadID = resume   // already live in this server — just turn/start
                } else {
                    let result = try await sendRequest(srv, method: "thread/resume") { id in
                        CodexAppServerProtocol.threadResume(requestID: id, threadId: resume)
                    }
                    threadID = Self.threadID(fromThreadResponse: result) ?? resume
                    resolvedModel = CodexAppServerProtocol.resolvedModel(fromThreadResponse: result)
                }
            } else {
                let result = try await sendRequest(srv, method: "thread/start") { id in
                    CodexAppServerProtocol.threadStart(
                        requestID: id,
                        cwd: request.workspaceURL.path,
                        sandbox: CodexInvocation.sandboxWire(request.codexSandbox),
                        approvalPolicy: "on-request",
                        developerInstructions: request.seed,
                        model: request.modelOverride)
                }
                guard let id = Self.threadID(fromThreadResponse: result) else {
                    failTurn(active, .serverError(message: "thread/start returned no thread id."))
                    return
                }
                threadID = id
                resolvedModel = CodexAppServerProtocol.resolvedModel(fromThreadResponse: result)
            }
            guard stillCurrent(active) else { return }
            srv.activeThreadID = threadID
            active.threadID = threadID
            // The controller re-captures the session id from every turn (D5); codex's
            // thread id is stable, so re-emitting is an idempotent no-op there.
            continuation.yield(.sessionStarted(sessionID: threadID))
            // The RESOLVED model (spec §2.2): what this thread actually runs —
            // codex's own config resolution when the request omitted `model`.
            if let resolvedModel {
                continuation.yield(.modelResolved(model: resolvedModel))
            }
```

(e) `Sources/Rubien/Assistant/ChatSessionController.swift` — minimal handling so the exhaustive switch compiles. Add the published property after `composerFocusRequest` (line ~96):

```swift
    /// The model codex reports the live thread actually runs (`.modelResolved`,
    /// spec §4.5) — meaningful when `modelOverride == nil` ("Codex default"): the
    /// picker shows what the default resolved to. Cleared with the conversation.
    @Published private(set) var resolvedModel: String?
```

Add to `handle(_:gen:)`'s switch after the `.sessionStarted` case (line ~502):

```swift
        case .modelResolved(let model):
            resolvedModel = model
```

And clear it in `resetConversationState()` (after `stagedSelection = nil`, line ~350):

```swift
        resolvedModel = nil
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RubienTests.CodexProviderTests 2>&1 | tail -5`
Expected: PASS (existing + 2 new).
Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` (proves every `AgentEvent` switch handles the new case).

- [ ] **Step 6: Commit**

```bash
git add Sources/Rubien/Assistant/AgentProvider.swift Sources/Rubien/Assistant/CodexProvider.swift Sources/Rubien/Assistant/ChatSessionController.swift Tests/RubienTests/CodexProviderTests.swift
git commit -m "feat(assistant): availableModels seam + modelResolved event from thread responses"
```

---

### Task 4: Preferences — raw semantics, nil = Codex default

**Files:**
- Modify: `Sources/Rubien/RubienPreferences.swift:257-280`
- Modify: `Sources/Rubien/Views/RubienSettingsView.swift:279-280` (compile fix only)
- Test: `Tests/RubienTests/RubienPreferencesTests.swift:182-219`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  static var RubienPreferences.assistantCodexModel: String?   // raw; nil/absent = "Codex default" (omit on wire)
  static var RubienPreferences.assistantCodexEffort: String   // raw; unset/empty ⇒ "medium"; NO static normalization
  ```
  (`assistantModel`/`assistantEffort` — the Claude prefs — keep their existing normalizing getters.)

- [ ] **Step 1: Update the tests to the new contract**

In `Tests/RubienTests/RubienPreferencesTests.swift`, replace `testAssistantBackendDefaultsWhenUnset` (lines 184-191), the model/effort lines of `testAssistantBackendPrefsRoundTrip` (lines 196-199), and all of `testAssistantModelEffortPrefsNormalizeAgainstBackendList` (lines 206-219) with:

```swift
    func testAssistantBackendDefaultsWhenUnset() {
        XCTAssertEqual(RubienPreferences.assistantProvider, .claude, "unset ⇒ Claude")
        XCTAssertNil(RubienPreferences.assistantCodexModel,
                     "unset ⇒ Codex default (no model sent; codex resolves its own config)")
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "medium",
                       "Codex effort defaults to medium (dodges the xhigh stall), not high")
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .readOnly)
        XCTAssertNil(RubienPreferences.assistantCodexBinaryPath)
    }

    func testAssistantBackendPrefsRoundTrip() {
        RubienPreferences.assistantProvider = .codex
        XCTAssertEqual(RubienPreferences.assistantProvider, .codex)
        RubienPreferences.assistantCodexModel = "gpt-5.6-terra"
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-5.6-terra")
        RubienPreferences.assistantCodexModel = nil
        XCTAssertNil(RubienPreferences.assistantCodexModel, "nil clears back to Codex default")
        RubienPreferences.assistantCodexEffort = "xhigh"
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "xhigh")
        RubienPreferences.assistantCodexSandbox = .workspaceWrite
        XCTAssertEqual(RubienPreferences.assistantCodexSandbox, .workspaceWrite)
        RubienPreferences.assistantCodexBinaryPath = "/opt/bin/codex"
        XCTAssertEqual(RubienPreferences.assistantCodexBinaryPath, "/opt/bin/codex")
    }

    /// The Codex prefs are RAW (spec §4.4): no static normalization — the old clamp
    /// would silently rewrite a chosen `max`/`ultra` (absent from the static four)
    /// back to `medium`, and a pinned model unknown to a static list must survive
    /// for the catalog-aware picker to handle visibly. Claude prefs still normalize.
    func testCodexPrefsAreRawClaudePrefsStillNormalize() {
        RubienPreferences.assistantCodexModel = "gpt-9-future"
        XCTAssertEqual(RubienPreferences.assistantCodexModel, "gpt-9-future")
        RubienPreferences.assistantCodexEffort = "ultra"
        XCTAssertEqual(RubienPreferences.assistantCodexEffort, "ultra", "ultra survives the round-trip")
        // A Codex slug is not a Claude model → the CLAUDE pref still snaps to its default.
        RubienPreferences.assistantModel = "gpt-5.5"
        XCTAssertEqual(RubienPreferences.assistantModel, "opus")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RubienTests.RubienPreferencesTests 2>&1 | tail -10`
Expected: compile FAILURE (`assistantCodexModel = nil` — type is non-optional `String` today).

- [ ] **Step 3: Implement the pref rewrite**

In `Sources/Rubien/RubienPreferences.swift`, replace lines 257-280 (both codex model + effort accessors and their doc comments) with:

```swift
    /// Default Codex model slug for new conversations — RAW (spec §4.4).
    /// nil/absent = "Codex default": no `model` is sent on `thread/start`; the
    /// installed codex resolves its own config chain (profile → config.toml →
    /// builtin). A stored slug is a user pin, sent verbatim; validity is the
    /// catalog-aware picker's job, never a silent rewrite here.
    static let assistantCodexModelKey = "Rubien.assistant.codex.model"

    static var assistantCodexModel: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantCodexModelKey) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            if let value = newValue, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: assistantCodexModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: assistantCodexModelKey)
            }
        }
    }

    /// Default Codex reasoning effort for new conversations — RAW except the unset
    /// fallback `medium` (universal since codex 0.142; deliberately not the
    /// `~/.codex` default, which is often `xhigh` and stalls). No list clamp: the
    /// per-model effort lists come from the live catalog (a static clamp would
    /// silently rewrite a chosen `max`/`ultra` back to `medium`).
    static let assistantCodexEffortKey = "Rubien.assistant.codex.effort"

    static var assistantCodexEffort: String {
        get {
            let raw = UserDefaults.standard.string(forKey: assistantCodexEffortKey) ?? ""
            return raw.isEmpty ? "medium" : raw
        }
        set { UserDefaults.standard.set(newValue, forKey: assistantCodexEffortKey) }
    }
```

- [ ] **Step 4: Fix the one non-optional consumer (Settings mirror seed)**

In `Sources/Rubien/Views/RubienSettingsView.swift`, `seedModelEffortMirrors` (line 279):

```swift
        case .codex:
            defaultModel = RubienPreferences.assistantCodexModel ?? ""
            defaultEffort = RubienPreferences.assistantCodexEffort
```

(`""` is the Settings mirror's "Codex default" sentinel — UI-layer only; Task 8 makes the setter map it back to nil. `ReaderChatSession.defaultsProvider` already passes `String?` into `AssistantConversationDefaults.model: String?` — no change needed there.)

- [ ] **Step 5: Run tests + build**

Run: `swift test --filter RubienTests.RubienPreferencesTests 2>&1 | tail -5`
Expected: PASS.
Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Rubien/RubienPreferences.swift Sources/Rubien/Views/RubienSettingsView.swift Tests/RubienTests/RubienPreferencesTests.swift
git commit -m "feat(assistant): raw codex model/effort prefs; nil model = Codex default"
```

---

### Task 5: `AssistantModelOptions` — slim the Codex descriptor, add shared row builders

**Files:**
- Modify: `Sources/Rubien/Assistant/AssistantModelOptions.swift`
- Test: `Tests/RubienTests/AssistantModelOptionsTests.swift`

**Interfaces:**
- Consumes: Task 1's `CodexModelInfo`.
- Produces (Tasks 7+8 consume these exact signatures):
  ```swift
  // AgentBackendDescriptor.defaultModel becomes String? (Claude "opus", Codex nil).
  // Codex descriptor: models = [] (discovery-fed), efforts = universal four (fallback only).
  static func AssistantModelOptions.codexModelRows(
      models: [CodexModelInfo], pinned: String?, resolvedModel: String?
  ) -> [(label: String, value: String?)]          // row 0 is always ("Codex default…", nil)
  static func AssistantModelOptions.codexEffortRows(
      governing: CodexModelInfo?
  ) -> [(label: String, value: String)]
  static func AssistantModelOptions.defaultModel(for kind: AgentProviderKind) -> String?  // now optional
  ```

- [ ] **Step 1: Rewrite the tests to the new contract**

Replace the whole body of `Tests/RubienTests/AssistantModelOptionsTests.swift` (keep the `#if os(macOS)` wrapper, imports, and class declaration) with:

```swift
    /// Claude keeps the static co-location invariant. Codex's static model list is
    /// GONE (discovery-fed, spec §4.8) — only its fallback efforts remain static.
    func testClaudeDefaultsAreInItsOwnLists() {
        let models = AssistantModelOptions.models(for: .claude).map(\.value)
        let efforts = AssistantModelOptions.efforts(for: .claude).map(\.value)
        XCTAssertEqual(AssistantModelOptions.defaultModel(for: .claude), "opus")
        XCTAssertTrue(models.contains("opus"))
        XCTAssertTrue(efforts.contains(AssistantModelOptions.defaultEffort(for: .claude)))
    }

    func testCodexDescriptorIsDiscoveryFed() {
        XCTAssertEqual(AssistantModelOptions.models(for: .claude).map(\.value), ["fable", "opus", "sonnet"])
        XCTAssertTrue(AssistantModelOptions.models(for: .codex).isEmpty,
                      "Codex models come from the live catalog, never a baked list (spec §4.6/§4.7)")
        XCTAssertNil(AssistantModelOptions.defaultModel(for: .codex),
                     "no static default — nil pick means 'send no model' (Codex default)")
        // The universal fallback four (catalog-less effort picker only).
        XCTAssertEqual(AssistantModelOptions.efforts(for: .codex).map(\.value),
                       ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(AssistantModelOptions.defaultEffort(for: .codex), "medium")
    }

    /// Claude normalization is unchanged; Codex values PASS THROUGH (no static list
    /// to normalize against — validity is the catalog-aware picker's job).
    func testNormalizationClaudeOnlyCodexPassesThrough() {
        XCTAssertEqual(AssistantModelOptions.normalizedModel("sonnet", for: .claude), "sonnet")
        XCTAssertEqual(AssistantModelOptions.normalizedModel("gpt-5.5", for: .claude), "opus")
        XCTAssertEqual(AssistantModelOptions.normalizedModel("anything", for: .codex), "anything")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("bogus", for: .claude), "high")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("ultra", for: .codex), "ultra",
                       "no static clamp — ultra is valid on 5.6 models")
    }

    func testDescriptorMetadata() {
        XCTAssertEqual(AgentProviderKind.claude.displayName, "Claude")
        XCTAssertEqual(AgentProviderKind.codex.displayName, "Codex")
        XCTAssertFalse(AgentProviderKind.claude.descriptor.supportsSandbox)
        XCTAssertTrue(AgentProviderKind.codex.descriptor.supportsSandbox)
    }

    // MARK: Shared picker row builders (sidebar + Settings consume the same logic)

    private let terra = CodexModelInfo(
        id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", description: "Balanced.",
        efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                  CodexEffortInfo(value: "ultra", label: "Ultra", description: nil)],
        defaultEffort: "medium", isDefault: false, hidden: false)
    private let sol = CodexModelInfo(
        id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", description: nil,
        efforts: [], defaultEffort: "low", isDefault: true, hidden: false)

    func testCodexModelRowsDefaultFirstThenCatalog() {
        let rows = AssistantModelOptions.codexModelRows(models: [terra, sol], pinned: nil, resolvedModel: nil)
        XCTAssertEqual(rows.map(\.value), [nil, "gpt-5.6-terra", "gpt-5.6-sol"])
        XCTAssertEqual(rows[0].label, "Codex default")
        XCTAssertEqual(rows[1].label, "GPT-5.6-Terra")
    }

    func testCodexModelRowsShowResolvedModelOnDefaultRow() {
        let rows = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: nil, resolvedModel: "gpt-5.6-terra")
        XCTAssertEqual(rows[0].label, "Codex default (GPT-5.6-Terra)")
        // Resolved slug not in the catalog → raw slug in the label (honest fallback).
        let raw = AssistantModelOptions.codexModelRows(models: [], pinned: nil, resolvedModel: "gpt-7")
        XCTAssertEqual(raw[0].label, "Codex default (gpt-7)")
        // A PIN suppresses the resolved suffix (the default row isn't selected).
        let pinnedRows = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: "gpt-5.6-terra", resolvedModel: "gpt-5.6-terra")
        XCTAssertEqual(pinnedRows[0].label, "Codex default")
    }

    /// A pinned slug stays visible/selectable even when absent from the catalog
    /// (spec finding #6: never strand or silently rewrite a pin).
    func testCodexModelRowsKeepUnknownPinVisible() {
        let loaded = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: "gpt-5.5-pro", resolvedModel: nil)
        XCTAssertEqual(loaded.last?.value, "gpt-5.5-pro")
        XCTAssertEqual(loaded.last?.label, "gpt-5.5-pro — not offered by this codex")
        // Catalog not loaded yet (empty): keep the pin WITHOUT the warning suffix.
        let pending = AssistantModelOptions.codexModelRows(
            models: [], pinned: "gpt-5.5-pro", resolvedModel: nil)
        XCTAssertEqual(pending.map(\.value), [nil, "gpt-5.5-pro"])
        XCTAssertEqual(pending.last?.label, "gpt-5.5-pro")
        // A pinned slug IN the catalog is not duplicated.
        let known = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: "gpt-5.6-terra", resolvedModel: nil)
        XCTAssertEqual(known.map(\.value), [nil, "gpt-5.6-terra"])
    }

    func testCodexEffortRowsFollowGoverningModelElseUniversal() {
        XCTAssertEqual(AssistantModelOptions.codexEffortRows(governing: terra).map(\.value),
                       ["low", "ultra"])
        // No governing model, or one with no effort data → the universal four.
        XCTAssertEqual(AssistantModelOptions.codexEffortRows(governing: nil).map(\.value),
                       ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(AssistantModelOptions.codexEffortRows(governing: sol).map(\.value),
                       ["low", "medium", "high", "xhigh"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RubienTests.AssistantModelOptionsTests 2>&1 | tail -10`
Expected: compile FAILURE (`defaultModel(for:)` non-optional; `codexModelRows` undefined).

- [ ] **Step 3: Implement**

In `Sources/Rubien/Assistant/AssistantModelOptions.swift`:

(a) Change the descriptor field (line 21):

```swift
    /// Seed model for a fresh conversation (must be one of `models`), or nil for a
    /// backend whose models are DISCOVERED live (Codex): a nil pick means "send no
    /// model" and the runtime resolves its own default.
    let defaultModel: String?
```

(b) Replace the `.codex` descriptor case (lines 45-52) and update the extension doc comment (lines 29-33):

```swift
    /// The static capabilities for this backend. Claude verified against
    /// `--model`/`--effort` (claude 2.1.206 documents exactly these aliases —
    /// spec §2.4; no discovery API exists, so Claude stays curated-static).
    /// Codex models are DISCOVERED live via `CodexModelCatalog` (`model/list`,
    /// spec §4.1) — the descriptor deliberately has NO baked model list (a
    /// discovery-failed old codex is exactly the one that would reject baked
    /// current-generation slugs; finding #1). Its efforts here are the universal
    /// catalog-less fallback four only, never a normalization gate.
    var descriptor: AgentBackendDescriptor {
        switch self {
        case .claude:
            return AgentBackendDescriptor(
                displayName: "Claude",
                models: [("Fable", "fable"), ("Opus", "opus"), ("Sonnet", "sonnet")],
                efforts: [("Low", "low"), ("Medium", "medium"), ("High", "high"),
                          ("xHigh", "xhigh"), ("Max", "max")],
                defaultModel: "opus",
                defaultEffort: "high",
                supportsSandbox: false)
        case .codex:
            return AgentBackendDescriptor(
                displayName: "Codex",
                models: [],
                efforts: [("Low", "low"), ("Medium", "medium"), ("High", "high"), ("xHigh", "xhigh")],
                defaultModel: nil,
                defaultEffort: "medium",
                supportsSandbox: true)
        }
    }
```

(c) Update the facades — `defaultModel(for:)` return type and the normalizers (lines 76-109):

```swift
    static func defaultModel(for kind: AgentProviderKind) -> String? {
        kind.descriptor.defaultModel
    }

    static func defaultEffort(for kind: AgentProviderKind) -> String {
        kind.descriptor.defaultEffort
    }

    /// Snap a persisted model to one this backend's STATIC list offers, else its
    /// default. Only meaningful for statically-listed backends (Claude); a
    /// discovery-fed backend (Codex) passes values through — validity there is the
    /// catalog-aware picker's job (spec §4.4), never a silent rewrite.
    static func normalizedModel(_ value: String, for kind: AgentProviderKind) -> String {
        guard let fallback = defaultModel(for: kind) else { return value }
        return models(for: kind).contains { $0.value == value } ? value : fallback
    }

    /// Snap a persisted effort to the static list — Claude only, same rule as
    /// `normalizedModel` (Codex efforts are per-model, from the catalog).
    static func normalizedEffort(_ value: String, for kind: AgentProviderKind) -> String {
        guard kind.descriptor.defaultModel != nil else { return value }
        return efforts(for: kind).contains { $0.value == value } ? value : defaultEffort(for: kind)
    }
```

(d) Add the shared row builders at the end of `AssistantModelOptions` (before the closing brace):

```swift
    // MARK: Codex dynamic picker rows (shared by the sidebar and Settings — spec §4.6)

    /// The Codex model picker's rows. Row 0 is always "Codex default" (`value: nil`
    /// — send no model; codex resolves its own config), suffixed with the resolved
    /// model's name when known AND the default is the active pick. A `pinned` slug
    /// absent from the catalog stays visible/selectable (finding #6) — with a
    /// warning suffix once the catalog has actually loaded, bare while it's pending.
    static func codexModelRows(
        models: [CodexModelInfo], pinned: String?, resolvedModel: String?
    ) -> [(label: String, value: String?)] {
        var rows: [(label: String, value: String?)] = []
        if pinned == nil, let resolvedModel {
            let name = models.first { $0.id == resolvedModel }?.displayName ?? resolvedModel
            rows.append((label: "Codex default (\(name))", value: nil))
        } else {
            rows.append((label: "Codex default", value: nil))
        }
        rows += models.map { (label: $0.displayName, value: Optional($0.id)) }
        if let pinned, !models.contains(where: { $0.id == pinned }) {
            let label = models.isEmpty ? pinned : "\(pinned) — not offered by this codex"
            rows.append((label: label, value: pinned))
        }
        return rows
    }

    /// The Codex effort picker's rows: the governing model's own effort list
    /// (per-model — 5.6 models add max/ultra), else the universal fallback four.
    static func codexEffortRows(governing: CodexModelInfo?) -> [(label: String, value: String)] {
        if let efforts = governing?.efforts, !efforts.isEmpty {
            return efforts.map { (label: $0.label, value: $0.value) }
        }
        return AgentProviderKind.codex.descriptor.efforts
    }
```

- [ ] **Step 4: Run tests + build**

Run: `swift test --filter RubienTests.AssistantModelOptionsTests 2>&1 | tail -5`
Expected: PASS.
Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` — `modelLabel(for:)`/`effortLabel(for:)` still compile (they tolerate empty lists via the `.capitalized` fallback), and no production code still calls `normalizedModel(_, for: .codex)` (the Task 4 pref rewrite removed the only caller; verify with `grep -rn "normalizedModel\|normalizedEffort" Sources/` — expected hits: `AssistantModelOptions.swift` definitions + `RubienPreferences.swift` Claude getters only).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/AssistantModelOptions.swift Tests/RubienTests/AssistantModelOptionsTests.swift
git commit -m "feat(assistant): slim codex descriptor to discovery-fed; shared dynamic picker row builders"
```

---

### Task 6: Controller — catalog lifecycle, model selection, thread-scoped model changes

**Files:**
- Modify: `Sources/Rubien/Assistant/ChatSessionController.swift`
- Test: `Tests/RubienTests/ChatSessionControllerTests.swift` (+ `MockAgentProvider` in the same file)

**Interfaces:**
- Consumes: Tasks 1/3/5.
- Produces (Task 7 consumes these exact names):
  ```swift
  @Published private(set) var codexModels: [CodexModelInfo]   // non-hidden, discovery result; [] until loaded/failed
  var governingCodexModel: CodexModelInfo?                    // pinned model, else resolved-default model, in codexModels
  func refreshCodexCatalog()                                  // kick/refresh the async fetch (no-op → clears for Claude)
  func selectModel(_ id: String?)                             // the picker's setter; nil = Codex default
  ```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RubienTests/ChatSessionControllerTests.swift` (inside the class, before the `MARK: - Test doubles` section if one exists):

```swift
    // MARK: Model auto-discovery (catalog + selection)

    private func makeCodexController(
        catalog: CodexCatalog?,
        provider: MockAgentProvider? = nil
    ) -> (ChatSessionController, MockAgentProvider) {
        let codex = provider ?? MockAgentProvider(
            kind: .codex, availability: .installed(version: "t", path: "/fake/codex"))
        codex.setCatalog(catalog)
        let controller = ChatSessionController(
            provider: codex, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: nil, effortOverride: "medium",
            autoApprove: false, codexSandbox: .readOnly)
        return (controller, codex)
    }

    func testRefreshCodexCatalogPopulatesVisibleModels() async {
        let terra = CodexModelInfo(
            id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                      CodexEffortInfo(value: "ultra", label: "Ultra", description: nil)],
            defaultEffort: "medium", isDefault: false, hidden: false)
        let ghost = CodexModelInfo(
            id: "ghost", displayName: "Ghost", description: nil,
            efforts: [], defaultEffort: nil, isDefault: false, hidden: true)
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [terra, ghost], fetchedOK: true))

        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }

        XCTAssertEqual(controller.codexModels.map(\.id), ["gpt-5.6-terra"], "hidden models dropped")
        XCTAssertNil(controller.governingCodexModel, "no pin, no resolved model yet")
        controller.handle(.modelResolved(model: "gpt-5.6-terra"), gen: controller.generation)
        XCTAssertEqual(controller.governingCodexModel?.id, "gpt-5.6-terra",
                       "the resolved default governs the effort list")
    }

    func testCatalogFailureLeavesModelsEmpty() async {
        let (controller, _) = makeCodexController(catalog: .unavailable)
        controller.refreshCodexCatalog()
        // Degrades to the empty list — the picker then shows only "Codex default"
        // (+ any pin), which works on ANY codex (spec §4.7).
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.codexModels.isEmpty)
    }

    func testSelectModelSnapsEffortToModelDefault() async {
        let sol = CodexModelInfo(
            id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", description: nil,
            efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil)],
            defaultEffort: "low", isDefault: false, hidden: false)
        let (controller, _) = makeCodexController(
            catalog: CodexCatalog(models: [sol], fetchedOK: true))
        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }
        controller.effortOverride = "xhigh"

        controller.selectModel("gpt-5.6-sol")

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-sol")
        XCTAssertEqual(controller.effortOverride, "low",
                       "an explicit pick snaps effort to the model's defaultReasoningEffort (spec §3)")
        // Picking Codex default (nil) leaves effort alone.
        controller.selectModel(nil)
        XCTAssertNil(controller.modelOverride)
        XCTAssertEqual(controller.effortOverride, "low")
    }

    /// The Codex model is THREAD-scoped (spec §2.3): changing it once the
    /// conversation has content starts a fresh conversation, preserving the pick.
    func testCodexModelChangeMidConversationStartsNewConversation() async {
        let (controller, codex) = makeCodexController(catalog: .unavailable)
        await waitUntil { controller.canSendWithCurrentAvailability }
        controller.send("hi")
        await codex.waitUntilStreaming()
        codex.emit(.sessionStarted(sessionID: "TH-1"))
        codex.finishStream()
        await controller.turnTask?.value
        XCTAssertTrue(controller.hasMessages)
        XCTAssertEqual(controller.liveSessionID, "TH-1")
        let genBefore = controller.generation

        controller.selectModel("gpt-5.6-sol")

        XCTAssertEqual(controller.modelOverride, "gpt-5.6-sol", "the pick survives the reset")
        XCTAssertNil(controller.liveSessionID, "a fresh conversation — the old thread's model was fixed")
        XCTAssertFalse(controller.hasMessages)
        XCTAssertGreaterThan(controller.generation, genBefore)
        // Re-selecting the SAME model is a no-op (no gratuitous reset).
        let genAfter = controller.generation
        controller.selectModel("gpt-5.6-sol")
        XCTAssertEqual(controller.generation, genAfter)
    }

    func testClaudeModelChangeMidConversationKeepsConversation() async {
        let claude = MockAgentProvider(kind: .claude)
        let controller = ChatSessionController(
            provider: claude, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: "opus", effortOverride: "high",
            autoApprove: false, codexSandbox: .readOnly)
        await waitUntil { controller.canSendWithCurrentAvailability }
        controller.send("hi")
        await claude.waitUntilStreaming()
        claude.emit(.sessionStarted(sessionID: "S-1"))
        claude.finishStream()
        await controller.turnTask?.value

        controller.selectModel("sonnet")

        XCTAssertEqual(controller.modelOverride, "sonnet")
        XCTAssertEqual(controller.liveSessionID, "S-1", "Claude models switch per turn — same conversation")
        XCTAssertTrue(controller.hasMessages)
    }

    func testResolvedModelClearedOnNewConversationAndCatalogClearedOnSwitchToClaude() async {
        let claude = MockAgentProvider(kind: .claude)
        let (controller, _) = makeCodexControllerWithFactory(claude: claude)
        controller.handle(.modelResolved(model: "gpt-5.6-terra"), gen: controller.generation)
        XCTAssertEqual(controller.resolvedModel, "gpt-5.6-terra")

        controller.newConversation()
        XCTAssertNil(controller.resolvedModel, "a fresh thread's resolution is unknown until thread/start")

        controller.refreshCodexCatalog()
        await waitUntil { !controller.codexModels.isEmpty }
        controller.switchProvider(to: .claude)
        XCTAssertTrue(controller.codexModels.isEmpty, "the catalog is Codex state; cleared on switch")
    }

    /// Controller wired with a factory so switchProvider works (mirrors the
    /// existing switch test's shape at line ~392).
    private func makeCodexControllerWithFactory(
        claude: MockAgentProvider
    ) -> (ChatSessionController, MockAgentProvider) {
        let codex = MockAgentProvider(kind: .codex)
        codex.setCatalog(CodexCatalog(
            models: [CodexModelInfo(id: "m", displayName: "M", description: nil,
                                    efforts: [], defaultEffort: nil, isDefault: false, hidden: false)],
            fetchedOK: true))
        let controller = ChatSessionController(
            provider: codex, transcript: SpyTranscriptSink(),
            reference: ChatReference(id: 1, title: "T", authors: ""),
            workspaceURL: URL(fileURLWithPath: "/tmp/ws"), gate: AssistantTurnGate(),
            webAccess: true, modelOverride: nil, effortOverride: "medium",
            autoApprove: false, codexSandbox: .readOnly,
            providerFactory: { kind in kind == .claude ? claude : codex })
        return (controller, codex)
    }
```

NOTE: this file already defines `waitUntil(_:ticks:)` (line 44), `SpyTranscriptSink`, and `MockAgentProvider.emit(_:)` (line 1170) / `finishStream()` (line 1173) / `waitUntilStreaming()` (line 1179). Also add to `MockAgentProvider` (line ~1030, alongside `_searchResults`):

```swift
    private var _catalog: CodexCatalog?

    func setCatalog(_ catalog: CodexCatalog?) {
        lock.lock(); defer { lock.unlock() }; _catalog = catalog
    }

    func availableModels() async -> CodexCatalog? {
        lock.lock(); defer { lock.unlock() }; return _catalog
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RubienTests.ChatSessionControllerTests 2>&1 | tail -10`
Expected: compile FAILURE — `codexModels`/`refreshCodexCatalog`/`selectModel` not defined.

- [ ] **Step 3: Implement the controller changes**

In `Sources/Rubien/Assistant/ChatSessionController.swift`:

(a) Published state — after the `resolvedModel` property added in Task 3:

```swift
    /// The installed codex's discovered models (non-hidden), feeding the model
    /// picker. Empty until `refreshCodexCatalog()` resolves — the picker then
    /// shows "Codex default" (+ any pin), which is always valid (spec §4.7).
    /// Claude conversations keep this empty (static lists).
    @Published private(set) var codexModels: [CodexModelInfo] = []
```

(b) Private token — next to `availabilityProbeToken` (line ~173):

```swift
    /// Supersession token for `refreshCodexCatalog` (same pattern as
    /// `availabilityProbeToken`): a slow fetch kicked before a provider switch
    /// must not repopulate the new backend's (cleared) model list.
    private var catalogFetchToken = 0
```

(c) The governing model + refresh + selection API — add after `recheckAvailability()` (line ~493):

```swift
    /// The model whose effort list governs the picker (spec §4.6): the pinned
    /// model, else the resolved codex-default model once a thread reported it.
    var governingCodexModel: CodexModelInfo? {
        guard let id = modelOverride ?? resolvedModel else { return nil }
        return codexModels.first { $0.id == id }
    }

    /// Kick (or re-kick) the model-catalog fetch for the live backend. Codex only —
    /// for Claude this clears the list. Never blocks a turn (spec §4.1); a result
    /// arriving after a provider switch is dropped by the token.
    func refreshCodexCatalog() {
        catalogFetchToken += 1
        let token = catalogFetchToken
        guard providerKind == .codex else {
            codexModels = []
            return
        }
        let catalogProvider = provider
        Task { [weak self] in
            let catalog = await catalogProvider.availableModels()
            guard let self, token == self.catalogFetchToken else { return }
            self.codexModels = catalog?.visibleModels ?? []
        }
    }

    /// The model picker's setter. nil = "Codex default" (no model sent; codex
    /// resolves its own config — spec §3). On Codex, the model is THREAD-scoped
    /// (`thread/start` only — spec §2.3), so changing it once the conversation has
    /// content starts a fresh conversation, preserving the pick; Claude switches
    /// live (per-turn `--model`). An explicit pick snaps the effort control to the
    /// model's own default (spec §3); "Codex default" leaves effort alone.
    func selectModel(_ id: String?) {
        guard id != modelOverride else { return }
        if providerKind == .codex, hasMessages {
            newConversation()
        }
        modelOverride = id
        if providerKind == .codex, let id,
           let model = codexModels.first(where: { $0.id == id }),
           let defaultEffort = model.defaultEffort {
            effortOverride = defaultEffort
        }
    }
```

(d) `switchProvider(to:)` — refresh the catalog for the incoming backend. After `newConversation()` (line ~397):

```swift
        newConversation()
        refreshCodexCatalog()
        Task { await recheckAvailability() }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RubienTests.ChatSessionControllerTests 2>&1 | tail -5`
Expected: PASS (existing + 6 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Assistant/ChatSessionController.swift Tests/RubienTests/ChatSessionControllerTests.swift
git commit -m "feat(assistant): controller catalog lifecycle + selectModel with thread-scoped codex semantics"
```

---

### Task 7: Sidebar pickers go dynamic

**Files:**
- Modify: `Sources/Rubien/Assistant/ChatSidebarView.swift:529-604` (model/effort picker section) + the view's mount hook

**Interfaces:**
- Consumes: Task 5 row builders, Task 6 controller API. No new exports.

- [ ] **Step 1: Rewrite the choice sources and labels**

In `Sources/Rubien/Assistant/ChatSidebarView.swift`, replace `modelChoices`/`effortChoices` (lines 531-544) with:

```swift
    // Claude: the static descriptor lists (verified CLI aliases — spec §2.4).
    // Codex: DISCOVERED rows — "Codex default" first (nil ⇒ send no model; codex
    // resolves its own config), then the installed codex's own models, with any
    // unknown pin kept visible (spec §4.6). The picker tags are `String?` because
    // nil is a real, selectable value on Codex.
    private var modelChoices: [(label: String, value: String?)] {
        switch session.providerKind {
        case .claude:
            return AssistantModelOptions.models(for: .claude)
                .map { (label: $0.label, value: Optional($0.value)) }
        case .codex:
            return AssistantModelOptions.codexModelRows(
                models: session.codexModels,
                pinned: session.modelOverride,
                resolvedModel: session.resolvedModel)
        }
    }
    private var effortChoices: [(label: String, value: String?)] {
        switch session.providerKind {
        case .claude:
            return AssistantModelOptions.efforts(for: .claude)
                .map { (label: $0.label, value: Optional($0.value)) }
        case .codex:
            return AssistantModelOptions.codexEffortRows(governing: session.governingCodexModel)
                .map { (label: $0.label, value: Optional($0.value)) }
        }
    }
```

- [ ] **Step 2: Route the model picker through `selectModel`**

In `modelPicker` (line 548), the model `Picker`'s selection becomes a proxy binding (Codex model changes are thread-scoped — the controller may start a fresh conversation):

```swift
            Picker("Model", selection: Binding(
                get: { session.modelOverride },
                set: { session.selectModel($0) })) {
                ForEach(modelChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.inline)
```

(The effort picker keeps `$session.effortOverride` unchanged.)

Update the menu's `.help` (line 581):

```swift
        .help("Model and reasoning effort for this conversation — on Codex, changing the model starts a new conversation")
```

- [ ] **Step 3: Collapsed label shows the pin, the resolved default, or "Codex default"**

Replace `modelLabel` (lines 584-586) with:

```swift
    private var modelLabel: String {
        if session.providerKind == .codex {
            let display = { (id: String) in
                session.codexModels.first { $0.id == id }?.displayName ?? id
            }
            if let pinned = session.modelOverride { return display(pinned) }
            if let resolved = session.resolvedModel { return display(resolved) }
            return "Codex default"
        }
        return AssistantModelOptions.modelLabel(for: session.modelOverride, kind: session.providerKind)
    }
```

(`effortLabel` is unchanged — its `.capitalized` fallback renders `max`/`ultra` as "Max"/"Ultra".)

- [ ] **Step 4: Kick the catalog fetch at mount**

The sidebar's mount hooks are at `ChatSidebarView.swift:41-50`. Add the catalog kick as the first line of the existing `.onAppear` (line 42):

```swift
        .task { await session.recheckAvailability() }
        .onAppear {
            session.refreshCodexCatalog()
            renderer.setTheme(colorScheme == .dark ? .dark : .light)
            // Re-mounting the pane created a fresh (empty) WebView — restore the
            // conversation from the controller's in-memory render log.
            session.replayTranscript()
            // Opened via Selection→Ask (a selection was staged before the pane
            // mounted): drop the caret into the composer so the user can type.
            if session.stagedSelection != nil { focusComposerSoon() }
        }
```

(`refreshCodexCatalog()` is cheap and token-guarded; re-running it on every pane remount just re-reads the actor's memo.)

- [ ] **Step 5: Build + full assistant test filter + visual harness check**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test --filter RubienTests 2>&1 | tail -5` → all PASS.
Optional visual: `swift run Rubien`, Debug ▸ Assistant Sidebar Harness — the harness uses a scripted provider (`availableModels` → nil default), so the Codex picker there shows just "Codex default"; real rows need Task 9's live E2E.

- [ ] **Step 6: Commit**

```bash
git add Sources/Rubien/Assistant/ChatSidebarView.swift
git commit -m "feat(assistant): dynamic codex model/effort pickers in the sidebar composer"
```

---

### Task 8: Settings ▸ Assistant goes dynamic

**Files:**
- Modify: `Sources/Rubien/Views/RubienSettingsView.swift` (assistant pane, lines ~236-378, + the codex recheck helper ~line 520)

**Interfaces:**
- Consumes: Task 5 row builders, Task 2 `CodexModelCatalog.shared`. No new exports.
- The Settings model mirror keeps its `String` type; `""` is its UI-layer "Codex default" sentinel, mapped to `nil` at the pref boundary (never persisted as a slug).

- [ ] **Step 1: Add catalog state + load**

In the settings view's state block (near `@State private var defaultProvider`, line ~37):

```swift
    /// The installed codex's discovered models for the Settings pickers (visible
    /// entries only). Loaded on appear; Recheck force-reloads. Empty while pending
    /// or when discovery failed — the pickers then degrade per spec §4.7.
    @State private var codexCatalogModels: [CodexModelInfo] = []
```

In `assistantPane`'s `.task` (after the `recheckCodex()` line, ~line 255):

```swift
            loadCodexCatalog()
```

Add the loader beside `recheckCodex()` (~line 520):

```swift
    /// Fetch the codex model catalog for the Settings pickers. `forceReload`
    /// (Recheck / binary-path change) drops the shared memo first.
    private func loadCodexCatalog(forceReload: Bool = false) {
        let override = RubienPreferences.assistantCodexBinaryPath
        Task { @MainActor in
            codexCatalogModels = await CodexModelCatalog.shared
                .catalog(executableOverride: override, forceReload: forceReload)
                .visibleModels
        }
    }
```

And make the existing codex Recheck path also refresh the catalog — inside `recheckCodex()`, add as its first line:

```swift
        loadCodexCatalog(forceReload: true)
```

- [ ] **Step 2: Dynamic rows in `assistantDefaultsSection`**

Replace the model and effort `Picker`s (lines 337-351) with:

```swift
            // Model/effort are the SELECTED backend's. Claude: static verified
            // aliases. Codex: discovered rows — "" is the mirror's "Codex default"
            // sentinel (UI-layer only; the pref stores nil — spec §4.4).
            Picker(selection: $defaultModel) {
                if defaultProvider == .codex {
                    ForEach(settingsCodexModelRows, id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                } else {
                    ForEach(AssistantModelOptions.models(for: .claude), id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                }
            } label: {
                Text(String(localized: "Model", bundle: .module))
            }

            Picker(selection: $defaultEffort) {
                if defaultProvider == .codex {
                    ForEach(settingsCodexEffortRows, id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                } else {
                    ForEach(AssistantModelOptions.efforts(for: .claude), id: \.value) {
                        Text($0.label).tag($0.value)
                    }
                }
            } label: {
                Text(String(localized: "Reasoning effort", bundle: .module))
            }
```

Add the row helpers near `seedModelEffortMirrors` (~line 273):

```swift
    /// Codex model rows for the Settings picker: the shared builder's rows with the
    /// nil ("Codex default") tag mapped to the mirror's "" sentinel. The current
    /// raw selection stays visible while the catalog loads (spec finding #6) —
    /// the builder's keep-pin row guarantees the Picker never loses its selection,
    /// so no phantom `.onChange` write can fire during load.
    private var settingsCodexModelRows: [(label: String, value: String)] {
        AssistantModelOptions.codexModelRows(
            models: codexCatalogModels,
            pinned: defaultModel.isEmpty ? nil : defaultModel,
            resolvedModel: nil)
            .map { (label: $0.label, value: $0.value ?? "") }
    }

    /// Effort rows follow the pinned default model when it's in the catalog, else
    /// the universal four. Includes the current selection even if unlisted (an
    /// unlisted stored effort must not blank the control or trigger a write).
    private var settingsCodexEffortRows: [(label: String, value: String)] {
        let governing = codexCatalogModels.first { $0.id == defaultModel }
        var rows = AssistantModelOptions.codexEffortRows(governing: governing)
        if !defaultEffort.isEmpty, !rows.contains(where: { $0.value == defaultEffort }) {
            rows.append((label: CodexEffortInfo.label(for: defaultEffort), value: defaultEffort))
        }
        return rows
    }
```

- [ ] **Step 3: Map the mirror's "" sentinel to nil at the pref boundary**

Replace `setDefaultModel` (lines 285-290) with:

```swift
    /// Route a model-mirror change back to the CURRENTLY-selected backend's pref.
    /// For Codex, "" is the "Codex default" sentinel → nil (the pref key is
    /// removed; no slug is ever persisted for the default — spec §4.4).
    private func setDefaultModel(_ value: String) {
        switch defaultProvider {
        case .claude: RubienPreferences.assistantModel = value
        case .codex: RubienPreferences.assistantCodexModel = value.isEmpty ? nil : value
        }
    }
```

(Task 4 already made `seedModelEffortMirrors` read `?? ""`. `setDefaultEffort` is unchanged — the effort pref stores whatever the picker offers.)

- [ ] **Step 4: Build + tests + manual check**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test --filter RubienTests 2>&1 | tail -5` → all PASS.
Manual: `swift run Rubien` → Settings ▸ Assistant → Backend "Codex": Model shows "Codex default" + the real installed models (5.6 trio on codex ≥0.144); picking "GPT-5.6-Sol" flips the effort rows to include Max/Ultra; Recheck repopulates.

- [ ] **Step 5: Commit**

```bash
git add Sources/Rubien/Views/RubienSettingsView.swift
git commit -m "feat(assistant): dynamic codex model/effort defaults in Settings with Codex-default sentinel"
```

---

### Task 9: Full-suite gate + live E2E verification

**Files:**
- No planned source changes (fixes only if verification finds issues).

- [ ] **Step 1: Full test gate**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test --filter RubienTests 2>&1 | tail -8` → 0 failures (expect ~395+ tests: 370 base + ~25 new).

- [ ] **Step 2: Live E2E against the real codex**

Quit the signed Rubien.app first (two processes on one SQLite corrupts), then:

```bash
RUBIEN_LIBRARY_ROOT="$HOME/Library/Group Containers/9TXK4V3SS8.group.com.rubien.shared/Rubien" swift run Rubien
```

Verify, in a PDF or web reader with the chat panel open and backend = Codex:

1. **Discovery:** the model picker lists "Codex default" + the real installed models (GPT-5.5, GPT-5.6-Sol/Terra/Luna on codex 0.144.x) — not the old hardcoded pair.
2. **Codex default resolution:** with "Codex default" selected, send a turn; after the first response the picker/collapsed label shows the resolved model (this machine's `~/.codex` says `gpt-5.6-terra`).
3. **Per-model efforts:** pick GPT-5.6-Sol → effort menu offers Low…Ultra and snaps to Low (Sol's `defaultReasoningEffort`); pick GPT-5.5 → back to the four, snapped to Medium.
4. **Thread-scoped switch:** after a turn, change the model → the pane starts a fresh conversation (quick-start page), the pick survives; History can resume the old thread.
5. **Q&A still works end-to-end:** a pinned 5.6 model answers a document question through the rubien MCP tools.
6. **Settings:** Settings ▸ Assistant shows the same dynamic rows; Recheck re-fetches; picking a default + "New conversation" (✎) in an open reader adopts it.
7. **Claude regression:** switch backend to Claude Code — static Fable/Opus/Sonnet picker, a turn streams normally.

- [ ] **Step 3: Update the spec's status line**

In `Docs/superpowers/specs/2026-07-10-codex-model-autodiscovery-design.md`, change the `- **Status:**` line to `Implemented (see Docs/superpowers/plans/2026-07-10-codex-model-autodiscovery.md)`.

- [ ] **Step 4: Commit**

```bash
git add Docs/superpowers/specs/2026-07-10-codex-model-autodiscovery-design.md
git commit -m "docs(assistant): mark codex model auto-discovery spec implemented"
```

- [ ] **Step 5: Repo review convention (before merge)**

Per CLAUDE.md's workflow + the user's standing convention: run a `codex-rescue` review of the full branch diff (backgrounded, `--effort medium`, findings inline) and a `/simplify` sweep; fix what warrants fixing; re-run the Task 9 Step 1 gate before merging to main.

---

## Post-plan notes (not tasks)

- **Deliberately untouched:** `ClaudeCodeProvider`, `ClaudeStreamParser`, `MCPContentChannel`, History code paths, `AgentTurnRequest` (a nil `modelOverride` already omits the wire key on both providers — that was true before this plan).
- **Deferred (spec §8/§10):** `turn/start` model-override probe (would allow live mid-conversation model switching on Codex later); `thread/resume`-reports-model probe (the readback is optional-tolerant either way); service-tier/personality surfacing.
- **Known transient:** between Tasks 5 and 7 the running app's Codex picker is empty (tests stay green). Don't ship mid-branch.
