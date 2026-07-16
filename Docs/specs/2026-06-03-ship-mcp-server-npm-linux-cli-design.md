# Ship `rubien-mcp-server` via npm + a public Linux CLI — Design

**Date:** 2026-06-03
**Status:** Approved design, two Codex passes incorporated; pending implementation plan (writing-plans next).
**Supersedes:** `Docs/plans/2026-06-01-bundle-mcp-server-in-app.md` (the "bundle the server inside Rubien.app via esbuild" approach — rejected during brainstorming because it couples server releases to signed-DMG cadence and does nothing for Linux).
**Reviewed:** Two Codex (gpt-5.5) passes. (1) Design review of the verbal design — verdict PROCEED-WITH-CHANGES; its five findings are folded in and marked **[Codex #N]**. (2) Review of this written spec — verdict REVISE-SPEC; its additional findings are folded in and marked **[Codex spec-rev]**.

---

## 1. Problem

The Rubien source repo is **private**. Signed/notarized DMGs ship from the **public** `devzhk/Rubien-releases` repo. The `mcp-server/` (Node/TypeScript MCP server that wraps `rubien-cli`) has **no public install path** — today it's clone-from-private-source only (`mcp-server/README.md` §Install & build). Separately, there is **no public Linux `rubien-cli` binary** at all; Linux is build-from-private-source only (`README.md` Linux CLI section).

So a non-maintainer cannot install the MCP server, and a Linux user cannot get the CLI it depends on. The MCP server is useless without `rubien-cli` at runtime — it spawns it (`mcp-server/src/cli.ts:resolveCliPath`).

## 2. Goal

End users install the MCP server on **Mac and Linux** without the private repo, and an auto-updating npm server **cannot silently outrun** the CLI it wraps.

## 3. Locked decisions (from brainstorming)

| Decision | Choice | Why |
|---|---|---|
| Distribution channel | **npm publish** (`rubien-mcp-server`, name confirmed free) | Native home for a Node package; `npx -y` gives independent-update cadence + a cross-platform channel — the two drivers the user picked. |
| License | **Apache-2.0** | Repo currently has *no* license; npm publish forces one. Permissive + patent grant. |
| Linux | **Folded in**: ship a public Linux `rubien-cli` binary | Closes the cross-platform loop so the npm package is actually usable on Linux. |
| Linux packaging | **`-static-stdlib` release binary + documented apt runtime deps**, built by CI, hosted on `devzhk/Rubien-releases` | The CLI links poppler/cairo/gdk-pixbuf (Package.swift:50-58, 99), so a single fully-static binary is not realistic; `-static-stdlib` removes the Swift-toolchain requirement, leaving a small set of system C libs. |
| Drift defense | **Version guard** keyed on the **monotonic `build` integer** (BUILD.txt) | The CLI's marketing version is the placeholder `"1.0.0"` (RubienCLI.swift:16), which is semver-*greater* than the real `0.1.6` — a semver guard would pass on exactly the old builds we want to reject. |
| npm publish mechanics | **Manual `npm publish`** from the maintainer's Mac (v1) | Avoids an `NPM_TOKEN` secret in the private repo. |
| Arch | **x86_64 Linux only** (v1) | arm64 deferred. |

## 4. Non-goals / out of scope

- arm64 Linux binary.
- AppImage / `.deb` packaging (chose plain binary + apt deps).
- Linux CloudKit sync — architecturally Mac-only (`RubienSync` is `.when(platforms: [.macOS])`, Package.swift:100). A Linux library is a *standalone local* library; there is no path to pull a Mac library to Linux.
- CI-automated npm publish (manual for v1).
- `.dxt` Desktop Extension (still future work per `mcp-server/README.md`).
- **Runtime *output-schema* validation of CLI responses** — see threat model §5; the guard + dev-time `schemas.test.ts` remain the contract mechanism. (zod *is* used for tool **input** schemas; what's out of scope is validating CLI **output** shapes at runtime — a separate, larger change.)
- Bundling the server inside Rubien.app (the rejected approach this supersedes).

## 5. Threat model: version drift **[Codex #3 — corrected]**

The brainstorming rationale wrongly assumed "zod validates every CLI response, so drift surfaces as an error." **This is false and was verified against the code:**

- `runCliAsTool` (the path nearly every tool uses) does `JSON.stringify(result)` and returns it as text — **no `.parse()`/`.safeParse()`** (`mcp-server/src/toolHelpers.ts:13-30`).
- zod **is** used — but only for tool **input** schemas (`mcp-server/src/tools/pdf.ts:1` etc.). `schemas.ts` (the CLI **output** DTO shapes) is **not imported on the runtime path** (grep for `schemas` usage in `src/` is empty); it backs the contract-pinning *tests* only. The precise gap is **no runtime output-schema validation**.
- `invokeCli` does `JSON.parse(stdout)` (`cli.ts:105`), so only **gross non-JSON** output throws. Field-level drift (renamed/missing/changed fields) parses fine and flows straight to Claude.

**Consequence:** the version guard is the **primary** defense against an auto-updated server meeting an incompatible CLI, not a backstop. This raises its priority but does not change its design.

## 6. End-state install stories

**Mac** — install the DMG. The entitled `rubien-cli` already rides in `Rubien.app/Contents/Helpers/` (build-app.sh `embed_helpers` ~:211, signed ~:276) and is the first non-env candidate in `resolveCliPath` (`cli.ts:42`). Then:
```
claude mcp add rubien -- npx -y rubien-mcp-server
```

**Linux** — once:
```
sudo apt install <runtime deps — exact list derived in Phase D>   # see §7.D
```
download the `rubien-cli` tarball from the public releases repo and extract it, keeping `rubien-cli` and its `*.resources` bundle together (point `RUBIEN_CLI` at the extracted binary); then the same `npx` line. Update in place later with **`rubien-cli self-update`** (§7.F — ed25519-signature-verified; no Mac app needed). `rubien_sync_status` errors on Linux (no CloudKit); PDF tools work (poppler backend is live).

## 7. Components

### A — npm package (`mcp-server/`)

Changes to `package.json`:
- Remove `"private": true`.
- Add `"license": "Apache-2.0"` + an Apache-2.0 `LICENSE` file in `mcp-server/`, shipped via `files`.
- `"homepage"` / `"bugs"` → the **public** `devzhk/Rubien-releases` repo (the source repo is private and would 404). `"repository"` → same public repo (it is not the source, but it is the only public home; acceptable).
- `"keywords"`: `mcp`, `model-context-protocol`, `rubien`, `reference-manager`, `citations`.
- `"prepublishOnly": "npm run build && npm test"`. Safe: the e2e test **skips** (does not fail) when `dist/` or `.build/debug/rubien-cli` is absent (`test/e2e-stdio.test.ts:20-26`) **[Codex confirmed]**.
- Keep `"bin": { "rubien-mcp-server": "./dist/index.js" }`, `"files": ["dist", "README.md", "LICENSE"]`, `"engines": { "node": ">=20" }`.

**Publish hygiene** (decide + verify at implementation):
- `npm pack --dry-run` confirms the tarball is `dist/` + README + LICENSE only.
- Decide whether `package-lock.json` is published or excluded.
- 2FA / npm provenance expectations for the maintainer account.
- Re-confirm name availability immediately before first publish.

**Mechanics:** manual `npm publish` from the maintainer's Mac, documented in the runbook.

**Acceptance:** `npm pack --dry-run` shows the expected file set; a fresh machine can `npx -y rubien-mcp-server@<ver> --help`; `claude mcp add rubien -- npx -y rubien-mcp-server` connects against a bundled-helper CLI.

### B — CLI version surface (Swift) **[Codex #5 — a genuine new build mechanism, not a tweak]**

Today the CLI binary has **no** version surface: `version:` is the hardcoded placeholder `"1.0.0"` (`RubienCLI.swift:16`), and `VERSION`/`BUILD.txt` only feed app-bundle metadata in shell scripts (build-app.sh ~:47, ~:166). This component adds one.

1. **SPM build-tool plugin** that reads package-root `VERSION` + `BUILD.txt` and generates `GeneratedVersion.swift` (e.g. `enum RubienVersion { static let marketing = "0.1.7"; static let build = 8 }`), compiled into the CLI binary so it survives `-static-stdlib` with no sidecar resource.
   - **Must nail down** (spike, see §9): build-tool plugin vs prebuild-command plugin; declaring package-root `VERSION`/`BUILD.txt` as plugin inputs under the **sandbox** (SwiftPM plugins are sandboxed); generated-output path; and that it works under `swift build`, CI, **and** the `build-app.sh` build path. **[Codex spec-rev]** `build-app.sh` builds the app + CLI via **`xcodebuild`**, not plain `swift build` (`scripts/build-app.sh:77-95`, invoked `:417-418`) — so the plugin must be proven under xcodebuild specifically, including any package-plugin trust/validation flags (e.g. `-skipPackagePluginValidation`). Treat xcodebuild as the make-or-break path.
   - **Likely-primary fallback** (given the xcodebuild risk): a checked-in generated `Version.swift` regenerated by a script, with a CI check that it stays in sync with `VERSION`/`BUILD.txt`. Prefer this if the plugin doesn't cleanly clear xcodebuild.
2. **`rubien-cli version` subcommand** emitting JSON `{"version":"0.1.7","build":8}` (machine-parseable; additive to the JSON contract).
3. Wire the arg-parser `version:` field to `RubienVersion.marketing` so `--version` is truthful too.
4. Per the CLAUDE.md CLI↔data-layer lockstep rule: update `Docs/CLI-Reference.md` and add a `RubienCLITests` case asserting the **exact `version` JSON shape** — the existing version test only checks that `--version` is non-empty (`Tests/RubienCLITests/SwiftLibCLITests.swift:113-119`), so a new assertion is required, in the same change.

**Acceptance:** `rubien-cli version` prints the real `{version, build}` (exact-shape test, not just non-empty); `--version` matches; doc updated; binary built via `build-app.sh` (xcodebuild) reports the same values as a plain `swift build`.

### C — MCP server version guard (Node) **[Codex #4 — needs its own timeout + clean error]**

1. `cli.ts` gains `getCliVersion(): Promise<{version: string, build: number} | null>` — runs `rubien-cli version` with a **short dedicated timeout (~5s)**, *not* the default 60s (`cli.ts:9`); returns `null` on parse failure / non-zero exit / missing subcommand (old CLI).
2. A `MIN_CLI_BUILD` constant in the server.
3. **Probe ordering [Codex spec-rev]:** parse args first; let `--help` print and exit **without** probing (`index.ts:50-52` already exits on `--help` before startup — the guard must not move ahead of it, or `npx … --help` breaks on a machine with no `rubien-cli`). Then, **after** `--help`/arg handling and **before** connecting the transport, in both stdio and http paths (`index.ts:116-128`), probe once. If `getCliVersion()` is `null` **or** `build < MIN_CLI_BUILD`, write a **clean remediation line to stderr** and exit non-zero. Do **not** let it fall through the generic `main().catch` `fatal: <stack>` handler (`index.ts:125`).
   - Exact messages (final wording at implementation):
     - too old: `rubien-mcp-server: installed rubien-cli is build <N>, but this server needs build ≥ <MIN>. Update Rubien.app (Mac) or download a newer rubien-cli from <releases URL> (Linux).`
     - no version surface: `rubien-mcp-server: cannot determine rubien-cli version (your rubien-cli predates the 'version' command). Update Rubien.app / download a newer rubien-cli.`
4. `MIN_CLI_BUILD` = the build that first ships component B's `version` subcommand (finalize to the actual release number at implementation). Bootstrapping **[Codex #7]**: the first npm publish ships with this floor; pre-B CLIs return `null` and fail loudly with a clear path. No wedge — every failure names the fix.

**Acceptance [strengthened, Codex spec-rev]:** non-skipped unit tests using **stub CLIs** (not a real `rubien-cli`): (a) stub printing a too-low build → server refuses to start with the exact remediation line, in **both** stdio and http modes; (b) stub with no `version` subcommand → the `null`-path remediation line; (c) a B-bearing stub → server starts; (d) `--help` exits 0 **with no CLI present at all**; (e) a hanging stub → probe aborts in ~5s, not 60s. None of these may rely on the skippable e2e.

### D — Linux binary (CI) **[Codex #1 + #2 — deps incomplete + release race]**

1. **Build:** CI on `ubuntu-22.04` (container `swift:6.3-jammy`, which already apt-installs the build deps and builds `rubien-cli` — `.github/workflows/ci.yml:34,41`) runs `swift build -c release --product rubien-cli -Xswiftc -static-stdlib`.
2. **Derive runtime deps, don't guess [Codex #1]:** run `ldd` on the release binary, map each `.so` → its apt runtime package, and document the **complete** list. The brainstorming list (poppler/cairo/gdk-pixbuf) was incomplete; expect to also need at least **`libsqlite3-0`** (GRDB uses system SQLite — CI installs `libsqlite3-dev`, Package.swift:22 / ci.yml:34), and the Foundation networking/XML paths used by metadata fetch + PDF download (`MetadataFetcher.swift`, `PDFDownloadService.swift:49`) pull **`libcurl4`, `libxml2`, and the jammy ICU soname** — `-static-stdlib` does not statically link these C libs.
3. **Clean-container smoke [Codex #1]:** in a fresh `ubuntu:22.04` with **only** the derived runtime packages installed (not the build tree), run: `rubien-cli version`; a DB-only command (e.g. `list`); a network/metadata command (e.g. `add --identifier`); and `pdf info`. This is the gate that proves the dep list is correct.
4. **Package:** `rubien-cli-<version>-linux-x86_64.tar.gz` containing the binary **+ its `*.resources` bundle** (required by `Bundle.module`; see plan D1) + a short install note (runtime deps + glibc ≥ 2.35 / Ubuntu 22.04+ floor from the jammy build). CI also signs the tarball with the dedicated Linux-CLI ed25519 key and uploads a detached `<tarball>.sig` beside it, for `self-update` verification (§7.F).
5. **Release ordering [Codex #2] — chosen:** `release.sh` stays the orchestrator. It currently pushes the private source tag, then `gh release create` on the releases repo with the DMG (release.sh ~:178, ~:187, ~:191). **After** creating the public release, `release.sh` dispatches the Linux workflow (`gh workflow run <linux-cli>.yml -f tag=$TAG`); the CI job builds + smoke-tests, then `gh release upload <TAG> <tarball> --repo devzhk/Rubien-releases` to the **already-existing** release. This removes the race (release exists before upload) and the no-upload-path gap (CI never assumed a release into being). CI currently triggers on push/PR only (ci.yml:3) — add `workflow_dispatch` with a `tag` input.
6. **Secret:** the Linux job needs a token with write access to `devzhk/Rubien-releases`.
7. **Split-release failure policy [Codex spec-rev — top risk]:** the Mac DMG + appcast go live the instant `release.sh` runs `gh release create` (Sparkle then offers the update to existing Mac users); the Linux tarball arrives **asynchronously** via the dispatched CI job. A Linux build/upload failure therefore **does not affect Mac** — but it can leave the release without a Linux asset. Policy: (a) `gh release upload` is **idempotent/retryable** (`--clobber`); (b) `release.sh` prints the dispatched workflow run URL and does **not** block the Mac release on it; (c) on CI failure, the fix is to **re-run the workflow** (re-builds + re-uploads to the same release) — no Mac rollback needed; (d) the Linux install docs (§E) and the GitHub release notes state the Linux asset may lag the DMG by a few minutes and link the workflow; (e) the upload token/permission scope is documented in the runbook. `Docs/Release-Runbook.md` rollback today covers only pulling a bad **Mac** release (`:93-106`) — add this Linux-asset policy beside it.

**Acceptance:** the clean-container smoke (step 3) passes; the tarball appears on the same release as the DMG, same version/build; re-running the workflow re-uploads idempotently (`--clobber`); a Linux user can install per §6 and `npx` connects.

### E — Docs

- `mcp-server/README.md`: lead install with `claude mcp add rubien -- npx -y rubien-mcp-server`; keep Mac (bundled helper) + Linux (download binary + the derived apt deps) prerequisites; document the guard's remediation behavior.
- top-level `README.md`: add an "MCP server" pointer section; repoint the Linux CLI section from build-from-source to the public binary **only once the Linux tarball actually exists on a release** (gate G2, §8) — until then the Linux instructions must not reference a binary that 404s.
- `Docs/Release-Runbook.md`: add the `npm publish` step, the Linux-binary CI dispatch/upload step, and the split-release failure policy (§7.D step 7).
- `Docs/CLI-Reference.md`: document `rubien-cli version` (done as part of B, per lockstep).

**Acceptance [Codex spec-rev]:** the Mac and Linux install commands in the READMEs are copy-paste runnable and verified end-to-end (Mac against the bundled helper; Linux against the published tarball); no doc references an artifact that doesn't yet exist.

### F — Linux CLI self-update **[added: Sparkle parity for the standalone binary]**

`rubien-cli self-update [--check]` gives the standalone Linux binary the auto-update affordance the Mac CLI gets from Sparkle — with **no Mac-app / Sparkle dependency** (verification is self-contained in the binary).

- **Discovery:** anonymous GET of the GitHub Releases API for `devzhk/Rubien-releases` "latest"; compare the tag against `RubienCLIVersion.marketing` — only act on **plain-numeric** tags (`X.Y.Z`); never downgrade. Staging happens under the install dir (same filesystem + exec-allowed) so the final rename can't cross filesystems and the staged-binary version check works even when `/tmp` is `noexec`.
- **Verification — ed25519 signature, separate key:** a dedicated Linux-CLI keypair (NOT the Sparkle key). The **private** key is a CI secret that signs the tarball in the release workflow → `<tarball>.sig`; the **public** key is compiled into `rubien-cli` and verifies the downloaded tarball via `swift-crypto`'s `Curve25519.Signing` *before anything is written*. Protects against a tampered/compromised release; the user side needs nothing but the binary it already has.
- **Apply:** download tarball + `.sig` to a temp dir, verify the signature, extract, confirm the tree contains the binary + its `*.resources`, and replace both in the directory of `/proc/self/exe` **transactionally** (back up existing bundles + roll back on any failure; binary swapped last via `rename(2)`). Requires write access (verified with a real create-probe, not just a path check).
- **Rollback defense:** the mutable release tag is only a discovery hint. Before replacing, trust the *signed binary's own attested build* — run `version` on the staged, already-signature-verified binary and replace **only if strictly newer**. This stops an old, validly-signed binary being served under a higher tag.
- **Platform gate:** Linux performs the update; **macOS** prints "rubien-cli updates with Rubien.app (Sparkle); self-update is Linux-only" and exits without touching the bundled, code-signed binary.
- **`--check`:** prints a JSON report (`{current, latest, updateAvailable}`) and changes nothing.

**Acceptance:** `--check` reports correctly against a real release; on Linux a stale binary updates itself and the replaced binary reports the new `version`; a tampered tarball (bad `.sig`) is **rejected without writing**; a validly-signed but **older** binary served under a higher tag is refused (build-not-newer); a mid-replace failure **rolls back**; on macOS it's a no-op with the explanation; insufficient write permission yields a clear error.

## 8. Phasing

The plan should sequence the two **de-risk spikes first** (§10), then:

1. **Phase B** — CLI version surface (plugin + `version` subcommand). Ships in the next release; prerequisite for the guard.
2. **Phase A + C** — npm package + version guard. The headline deliverable; unblocks Mac once a B-bearing CLI is released.
3. **Phase D** — Linux binary (CI build, dep derivation, clean-container smoke, release dispatch/upload + tarball signing).
4. **Phase F** — Linux CLI `self-update` (depends on B for the version constant and D for the signed release asset).
5. **Phase E** — docs, woven through each phase and finalized at the end.

**Hard ordering gates [Codex spec-rev]:**
- **G1:** A release whose CLI ships component B (the `version` subcommand) must exist **before** the first `npm publish` of A+C — otherwise the published server's `MIN_CLI_BUILD` floor rejects every released CLI and the package is uninstallable. (B precedes A+C above; this makes it a hard gate, not just an order.)
- **G2:** The Linux install docs (§E top-level README) publish **only after** Phase D has produced a Linux tarball on a real release. The npm package itself can ship earlier (it's platform-agnostic) documented Mac-first; Linux instructions are added when the tarball lands. Until then Linux is labeled *pending* — never point at a 404.

## 9. Must-nail-down details (the spec→plan checklist)

From the Codex review's under-specified list; the implementation plan must resolve each:

- [ ] Exact Linux runtime apt package list from **`ldd` + `readelf -d`** on the real release binary, including `libsqlite3-0` (GRDB system-links SQLite — `link "sqlite3"` in GRDB's `GRDBSQLite` module, confirmed), `libcurl4`, `libxml2`, and the **jammy ICU soname** — *plus* whether **ICU *data* files** (not just the `.so`) are needed at runtime and which package supplies them.
- [ ] Clean-container tarball smoke (not build-tree): `version` + DB-only + network + `pdf info`, runtime packages only.
- [ ] Release ordering wiring: `release.sh` dispatch + `workflow_dispatch(tag)` + `gh release upload` to the existing release.
- [ ] SPM plugin mechanics: build-tool vs prebuild-command; declared input files; generated output path; behavior under `swift build`, CI, and **`xcodebuild`** (the path `build-app.sh` actually uses — `:77-95`, `:417-418`), including package-plugin trust/validation flags. (SwiftPM plugins are sandboxed — confirm package-root reads are allowed.) If xcodebuild is fragile, the checked-in-generated-file fallback is primary.
- [ ] Exact `MIN_CLI_BUILD` (= the release build that ships B) and the exact two user-facing failure messages.
- [ ] Linux docs timing per gate **G2** — npm Linux instructions must not reference a tarball that doesn't yet exist.
- [ ] npm hygiene: `LICENSE` file present; `npm pack --dry-run` contents; `package-lock.json` publish/exclude; 2FA/provenance.
- [ ] Self-update: how the dedicated Linux-CLI ed25519 keypair is generated; where the private key lives (CI secret) and how the tarball is signed in the release workflow; the public key embedded as a constant; the detached-signature format `swift-crypto` verifies (raw ed25519 over the tarball bytes); `/proc/self/exe`-based replace + write-permission handling; tar extraction.

## 10. Risks + de-risk spikes (do these first)

1. **`-static-stdlib` runtime viability** — does the binary run on a *clean* Ubuntu 22.04 with only the derived deps? Spike: build in CI, run **`ldd` + `readelf -d`**, install the mapped runtime packages (incl. any **ICU data** package) in a fresh `ubuntu:22.04`, run the smoke commands. Record the exact dep list + glibc floor *from the artifact* (not assumed). *Fallback if intractable:* document a Swift-runtime install (worse UX) or revisit AppImage (out of scope today).
2. **SPM plugin under xcodebuild** — can a build-tool plugin read package-root `VERSION`/`BUILD.txt` **and** run cleanly under `build-app.sh`'s `xcodebuild` invocation (trust/validation flags)? Spike: minimal plugin emitting a constant, build via `swift build` **and** `build-app.sh`/`xcodebuild`. *Fallback (likely primary if xcodebuild balks):* checked-in generated file + CI sync check.

Lower risks: npm name taken at publish time (re-check; fall back to a scope); `release.sh` dispatch ordering bug (the chosen create-then-dispatch order avoids the race); **self-update key management** — generate the dedicated ed25519 keypair, store the private key as a CI secret, embed the public key; losing or rotating it breaks `self-update` verification for already-shipped binaries, so treat it like the Sparkle key.

## 11. Architecture summary

Two artifacts, two public channels, one npm package:

- **npm** (`rubien-mcp-server`): the cross-platform Node MCP server.
- **GitHub Releases on `devzhk/Rubien-releases`**: the binaries — DMG (Mac; CLI rides inside) **+ new Linux `rubien-cli` tarball + its ed25519 `.sig`**.

Both platforms converge on `npx -y rubien-mcp-server`; the version guard keeps the auto-updated server honest about the CLI it finds. The Mac CLI updates via Sparkle (with the app); the Linux CLI updates via **`rubien-cli self-update`** (signature-verified), so neither requires manual binary-swapping in steady state.
