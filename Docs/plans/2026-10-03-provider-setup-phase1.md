# Provider setup — Phase 1 implementation

## Scope

Implement Phase 1 of [the provider installation design](../specs/2026-10-02-provider-installation-and-updates-design.md): discovery, official native installation, sign-in, reusable setup cards, and detection of changed provider binaries. Use the current checkout and preserve its existing attachment/release work. Do not alter the prepared release worktree or run installers against the user's working CLIs.

## Steps

1. Add typed provider discovery, path hints, file fingerprints, and strict missing/broken/override distinctions.
2. Add a bounded maintenance runner with a new-session launch, complete script download before execution, private temporary files, sanitized diagnostics, cancellation, and timeouts.
3. Add installation/auth operation locks, shared progress journals, and persistent verified-install receipts. Duplicate requests observe the existing operation.
4. Add observable setup state and reusable cards in Assistant settings and the missing-provider setup entry point. Include the official command, actual procedure, Install, Copy, Sign in, Cancel, and Recheck.
5. Refresh availability/catalog/runtime generations when a provider binary changes, preserving active turns.
6. Build and run focused tests with fake executables and isolated directories. Check UI without installing or updating real providers. Record actual coverage and any remaining clean-account contract tests.

## Verification

- Discovery distinguishes absent, invalid override, inaccessible/broken candidates, and ambiguous methods.
- No temp directory or installer download on Settings open.
- Download failures/limits prevent execution; installer children have no controlling terminal; Codex gets explicit noninteractive mode.
- Exclusive install lock and auth lock deduplicate across model instances; stale journal recovery never replays a mutation.
- Receipts require fresh successful executable verification and survive diagnostic pruning.
- Login cancellation/timeout cannot apply stale state; credentials are not retained in output.
- External changes retire stale idle runtime generations without cancelling active work.
- Existing provider tests remain green; macOS files remain gated for Linux.

## Status

- Phase 1 implementation complete in the current checkout; not committed or released.
- Phase 2 update detection/manual updates and Phase 3 package automation are outside this phase.
- Before committing, ask whether to run the repository-required independent review and simplify sweep.

## Results — 2026-10-03

- Added conservative discovery, shared setup cards in Assistant settings and chat setup, official installation plans, browser sign-in with cancellation, and bounded live diagnostics.
- Added per-provider action locks, shared progress records, verified native-install receipts, and cleanup of journaled abandoned downloads. Installer children inherit the action lock; no shared usage-lease protocol was added.
- Added executable fingerprints for Claude availability, Codex model catalogs, and idle Codex runtime replacement. Active conversations retain their current process. Selecting a different Codex path explicitly requires restarting Rubien because the existing shared registry pins its launch inputs.
- Preserved Settings model refresh after setup checks and corrected cancellation of a superseded catalog lookup so process cleanup can finish.
- Build succeeded. The final focused run passed **38 tests**, covering setup, model catalog behavior, availability, shared runtime reuse, replacement during active work, and sign-in cancellation. Test log: `/private/tmp/rubien-provider-setup-tests.log`.
- Visually checked the separately named `build/ProviderSetupPreview/Rubien Setup Preview.app`: both ready cards, Recheck, executable picker, selected-path restart notice, no duplicate Install action, and return to automatic discovery. The preview uses its own bundle identifier and `build/ProviderSetupPreview/Library`. Working CLI installations were not changed. UI inspection preceded the final catalog-cleanup fix; the Mac locked before the preview could be refreshed again.

## Remaining release checks

- **User decision — 2026-10-03:** defer fresh sign-in credential persistence to developer testing after publication. This check remains unverified but is no longer a prepublication gate for this feature. Existing-login chats through Rubien still need validation. This decision does not authorize publication or waive other release requirements.
- The initial temporary-home run passed real installer execution through `ProviderMaintenanceRunner` and login cancellation/deadline checks. It supplied pre-downloaded scripts; it did not exercise `ProviderSetupModel.performInstall`'s download, redirect checks, verification, or receipt with real commands. Both new binaries also passed authentication and minimal CLI conversations using existing account credentials. Fresh credential persistence, conversations through Rubien's UI, and full disposable-account coverage remain open. Do not treat temporary HOME as Keychain isolation or publish before the remaining release requirements are resolved.
- The follow-up below closes the real setup-model install gap for both providers, with discovery and health probes scoped to temporary homes. Complete provider integration and UI conversations remain to be checked; fresh sign-in saving follows the deferred developer check above.
- Real installer success and real login cancellation/timeout released action locks. A parent-exit harness also verified inherited login locks survive launcher exit and release after owned-child cleanup. Full Rubien crash recovery during an installer mutation was not exercised. A finished journal still does not authorize ignoring a held lock.
- Native updater status is displayed as unverified. Metadata checks, native manual updates, and package-manager automation belong to later phases.
- Independent review and the simplify sweep require the user's approval under `AGENTS.md`; neither has run for this implementation.

## Review fixes — 2026-10-03

- Shell discovery uses a framed result, ignoring profile banners and logout output. Known candidates avoid shell startup entirely; fallback runs off the actor with a 15-second deadline. A timeout or incomplete frame stays unknown and cannot authorize a duplicate install.
- Codex availability retains its resolved path while its executable fingerprint matches. Cache misses resolve asynchronously, with concurrent callers sharing that lookup.
- Status probes use shared action locks. Missing records produce no interruption warning; abandoned records are finalized once under an exclusive lock. Fresh checks clear old notices, and successful health checks suppress obsolete interruption warnings without manufacturing receipts.
- Automatic card checks reuse a snapshot for 60 seconds, with manual Recheck, executable changes, and maintenance activity bypassing the throttle. Failed catalog lookups back off for 30 seconds; explicit reload or binary replacement retries immediately.
- Provider availability accepts an injected setup store; the new Claude and Codex fingerprint tests use isolated directories.
- Keep this feature after the prepared 0.8.0 release candidate. No release worktree, installed provider, or account credentials were changed by these fixes.
- Selecting a different Codex path still requires restarting Rubien because the shared runtime pins its initial launch inputs. Existing wrappers keep their current executable. Sign-in output remains discarded to avoid retaining credentials; the card supplies the exact Terminal command when browser sign-in cannot complete in-app.
- Build succeeded; **48 focused tests passed** across setup, catalog caching, provider availability, authentication rechecks, runtime reuse, active-turn preservation, and login cancellation. New regressions cover noisy/slow shell profiles, shared status probes, missing journals, one-time interruption recovery, activation throttling, cached path invalidation, and failed-catalog backoff. Log: `/private/tmp/rubien-provider-review-tests-final.log`.

## Shell compatibility follow-up

- The login shell loads its environment and executes `/bin/sh -c` with the quoted lookup script. Both setup discovery and ordinary provider fallback resolution use this command.
- The shared synchronous resolver again has a five-second deadline. Asynchronous setup discovery retains its 15-second deadline.
- Install and Sign in retry status-reader contention at 20-millisecond intervals for up to 100 milliseconds. They do not queue behind a competing setup action. Cancellation aborts the retry before launching a child or writing a journal.
- Regression coverage includes a non-POSIX shell stub that accepts only the delegated invocation, inherited PATH, quoted binary names, found/missing results, both timeout policies, Install/Sign in clicks during status checks, and cancellation. Fish itself is not installed on this machine; the test uses the requested stub.
- The real-process descendant-lock gate remains open. No real installer, sign-in flow, or release operation was run.
- Build succeeded; **31 focused tests passed** (24 setup tests and seven Claude/Codex availability tests). Log: `/private/tmp/rubien-provider-shell-review-final.log`.

## Efficiency and simplicity follow-up

- Output revisions now skip unchanged snapshots, sanitization, and publications, including the completion callback. Unicode filtering constructs one scalar view. Retained buffers remain bounded, and truncation changes are tracked even when no more bytes fit.
- Directory preparation is cached behind a per-store lock. A missing-directory error invalidates that cache and recreates the private directory before retrying acquisition.
- Setup and runtime read one candidate-path list and use the same account login-shell selection. Setup actions and method hints use enums; action strings and journal filenames remain compatible with earlier records.
- Runner fakes receive a request with named fields. The output reader reuses `LockedBox`; unused `ownerPID` and `scriptBytes` journal fields were removed. Older journals with those fields still decode. The setup model's chained state changes are now separate statements.
- Kept strict installation version extraction separate from the legacy availability parser: installation verification must reject arbitrary output and preserve prerelease/build suffixes. Also retained both bounded script checks because they detect substitution during the discovery wait, and retained the verified receipt required by Phase 2.
- Added regressions for quiet output, Unicode sanitization, journal compatibility, directory recovery, and strict version verification. Existing fake-install/sign-in tests check named request fields and receipt behavior.
- Build succeeded; **47 focused tests passed** (28 setup, 12 catalog, seven provider availability). Log: `/private/tmp/rubien-provider-efficiency-final.log`. A stale test-bundle signing temporary file was removed after confirming no build/signing process was running; no release artifacts were changed.

## Authorized live validation

The user approved real installer testing with temporary homes and accepted that this does not fully isolate macOS Keychain. Inspect and hash each official bootstrap, run it through the production runner with system-only PATH and private HOME/TMPDIR values in the child environment, verify installed paths/versions and released action locks, and exercise login cancellation/deadlines without retaining authentication output. Compare working CLI/profile fingerprints afterward. Successful browser authentication and full disposable-account coverage remain distinct checks.

### Results — 2026-10-03

- Artifacts: `build/ProviderInstallValidation/live-dp1wltpe/`; sanitized XCTest log: `test-results.log`. The opt-in `ProviderInstallerLiveTests` skips ordinary test runs and requires the prepared test directory and inspected script hashes.
- Executed the complete official bootstrap scripts through `ProviderMaintenanceRunner`, with no controlling terminal and Codex's noninteractive setting. Both succeeded: **Codex 0.160.0**, **Claude Code 2.1.288**. Verified each launcher resolves inside the expected native installation directory under its test home and responds to `--version`.
- Both installer action locks were immediately available after success. Each real login process reached the five-second timeout and was started again, then cancelled after three seconds. All login locks released; authentication output was discarded.
- An additional OS-level harness let each real login process inherit the action lock, then exited the launching parent. Both children retained the lock. Terminating only the owned test process group released it within the bounded check. This validates native process descriptor behavior, not the full app crash/recovery UI.
- The live XCTest passed (one scenario covering both providers). No test processes remained after cleanup. All 11 tracked working CLI/profile paths retained the same presence, symlink target, and content hash.
- During this initial run, browser authentication was not completed and no provider chat was sent; see the follow-up below. Keychain/account isolation was not claimed. Test homes and evidence remain under the Rubien checkout; installed applications and release artifacts were not changed.

### Browser handoff follow-up

- The user completed Claude browser authorization. The browser reported success, but the isolated CLI exited with “Couldn't save your login” and remained signed out.
- Non-secret `security` queries confirmed the working environment has a default login Keychain, while the temporary-HOME environment has no default Keychain and an empty search list. This is a limitation of the temporary-home test, not evidence of a failed browser callback in Rubien.
- Automatic approval review rejected creating/configuring a private test Keychain because changing default/search-list settings could affect shared account state. That command did not execute. The user then explicitly approved using the existing Keychain without changing its default or search-list settings.
- With the normal account HOME and existing Keychain, the newly installed Claude Code 2.1.288 reported authenticated status. No additional browser login was needed. Evidence: `claude-shared-auth-result.json` in the live-validation directory.
- The same binary completed a minimal CLI chat and returned exactly `OK` with exit code zero. The check used an empty test workspace, disabled tools and customizations, and disabled session persistence. Evidence: `claude-shared-chat-result.json`. This verifies existing credential reuse and a real model response; fresh credential persistence and Rubien's complete UI-to-provider flow remain unverified.

### Codex authentication and chat follow-up

- The newly installed Codex 0.160.0 recognized the existing account login. Its minimal CLI chat returned exactly `OK` with exit code zero; the only completed item was an agent message, with no tool calls.
- The chat used an empty test workspace, read-only sandbox, ignored user configuration and policy rules, and ephemeral session mode. Evidence: `codex-shared-auth-result.json` and `codex-shared-chat-result.json` in the live-validation directory.
- This verifies existing credential reuse and a real model response from the new binary. Fresh browser sign-in credential persistence and a conversation through Rubien's UI remain separate checks.

### Recurring preview layout regression — 2026-10-03

- The refreshed preview copied an ordinary `.build/debug/Rubien` executable, bypassing the SDK linker fix already present in `scripts/build-app.sh`. Its `LC_BUILD_VERSION` reported SDK 14.4 and minimum OS 14.4; the installed app reported SDK 26.5 and minimum OS 14.4. This repeated the compatibility-mode layout problem documented in the attachment plan.
- Rebuilt the same source with the selected SDK passed through Clang's `-isysroot`. The executable now records SDK 27.0 and minimum OS 14.4. No toolbar placement, sidebar padding, or click-offset workaround was added.
- Added `scripts/preview-app.sh` to build, verify, bundle, and launch the isolated preview. It preserves the existing preview identity/library, embeds the library location for Finder launches, bundles resources and Sparkle, and disables release-update prompts. It refuses to replace a running preview. `scripts/verify-macos-sdk.py` rejects a mismatched SDK or minimum OS before packaging and checks the staged executable again. Updated `AGENTS.md` to use this path for UI checks.
- Verified the guard rejects the faulty SDK 14.4 preview, the corrected build passes both SDK checks and signature verification, and the launcher succeeds. Direct coordinate clicks on the visible Home and All References labels navigated correctly. Activity and Details appeared at the far right and toggled their panels. Reading Activity was restored after the check. The existing test library was preserved; the installed application was not launched or modified.

### Live-validation review follow-up

Plan:

1. Inject the setup model's child environment so its real install sequence can target a temporary home. Keep the production default unchanged.
2. Have the gated live test drive the model's Install action, including real curl download, redirect validation, native-target/version verification, and receipt persistence. Scope discovery and availability probes to the test installation and state the remaining isolation limits.
3. Keep explicit reviewed-script hashes. Generate a fresh run directory on each invocation; when downloaded bytes differ, stop before installer execution and require inspection. Record sanitized evidence separately from removable installed binaries.
4. Preserve the distinction between runner login-lifecycle checks, existing-credential CLI chats, and unverified fresh sign-in through Rubien.
5. Clarify that the preview is a UI harness with a separate library and shared provider credentials, without release signing, sync entitlements, or bundled CLI/browser helpers. It does not verify those integrations.

The shared resolver now chooses the account login shell instead of inherited `SHELL`; this is an intentional runtime change that aligns setup with ordinary provider discovery.

Results:

- Added an injectable child-environment factory to `ProviderSetupModel`, preserving its production default. Regression assertions cover the environment used for download, installer, verification, and login; login still prepends the selected executable directory to PATH.
- The live test now drives the model's Install action with real commands. It downloads the official script itself, runs production redirect/script checks, verifies the native target and version, persists a receipt, and compares that receipt with the successful operation record. Test discovery checks only the new home's launcher; final health checks use standalone version/auth commands. Host shell discovery, the shared app-server registry, and Rubien's UI are outside this test.
- Each invocation creates a fresh `model-run-<UUID>` directory. The pre-inspected bootstrap and the newly downloaded script must both match the reviewed hash. A vendor script change stops execution; inspect the new script before updating the bootstrap fixture and hash. This is an opt-in live contract check, not an unattended updater or ordinary CI test.
- Build passed; **28 setup tests passed**, and the live test skipped without its explicit opt-in. With opt-in, the single live scenario passed for both **Codex 0.160.0** and **Claude Code 2.1.288** in 37.9 seconds, including runner login timeout/cancellation and lock release. No fresh browser sign-in was completed.
- Evidence is under `build/ProviderInstallValidation/live-dp1wltpe/`: `model-test-results.log`, `model-focused-test-results.log`, and `model-run-DCE3E1EA-BDE7-4082-90CE-91C55FA6EED7/` receipts/version/install logs. All 11 working launcher/profile fingerprints matched the fresh pre-run baseline. No validation provider processes remained.
- Removed the four temporary provider homes after preserving the evidence, including both original runner-test installations and both new model-test installations. The reviewed bootstrap scripts, sanitized logs, receipts, and fingerprint records remain for inspection and reruns. No working provider installation or account Keychain setting was changed.
- Clarified preview limits in `AGENTS.md` and `scripts/preview-app.sh`. No preview packaging behavior changed in this follow-up.

### Preview for the user's Phase 1 chat check

- Extended `scripts/preview-app.sh` to build and bundle `rubien-cli`, sign the helper before the app, and verify both signatures. The preview can now use its bundled Assistant MCP helper. Sync entitlements and the browser host remain outside its scope; provider installations and credentials remain shared with the account.
- Rebuilt through the checked launcher and confirmed SDK 27.0/minimum OS 14.4. Opened the exact preview on Home with the existing separate test library for the user's Claude/Codex conversation checks. User acceptance results remain pending.

### Selected provider in Settings

- Changed Settings → Assistant → Connection to show only the selected provider's setup card. The first-use chooser still offers both providers, and each shared setup model retains its operation state when the selector changes. Updated the design to match.
- Rebuilt and reopened the preview through the SDK-verified launcher. Visually verified Claude Code shows only its card, Codex shows only its card, and switching back restores Claude Code. Left the user's Claude Code selection restored. No chat was sent during this UI check.
