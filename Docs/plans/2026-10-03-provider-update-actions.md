# Provider update actions

Complete the provider setup and release-check feature with executable update plans, progress and verification. Preserve the selected shared installation and existing chat sessions.

## Implementation

1. Verify ownership before enabling a mutation. Native adapters preserve vendor update policy. npm verifies package/bin, interpreter, prefix and registry. Homebrew verifies the installed official cask and its prefix; unsupported or pinned installations keep instructions.
2. Coordinate package changes across Rubien processes with an action intent and shared/exclusive usage locks. Provider children inherit usage descriptors. Wait for active work, retire idle Codex servers, and bound waits without killing unrelated processes.
3. Execute structured plans through the existing bounded runner. Revalidate before mutation, verify the actual version after completion, retain sanitized diagnostics, and refresh affected runtime/catalog state safely.
4. Show Update, progress and cancellation before mutation. Persist explicit automatic package-update consent by installation. Native automatic updates remain vendor managed. Automatic package actions require a quiet period and defer for external usage.
5. Add focused tests for ownership, lock contention/inheritance, stale plans, verification and shared consent. Exercise real updater contracts in disposable installations before enabling adapters.
6. Build the exact SDK-verified preview and inspect it. Preserve the installed application and library. Fresh sign-in credential saving remains the user's deferred post-publication check.

## Validation

### Approved review follow-up

1. Bind prepared actions to the selected executable and reject stale selection before mutation; cover manual and automatic actions.
2. Retain update progress independently of release notices, and preserve release state while a package updater owns the installation.
3. Share overlapping preparation probes, publish policy only when it changes, and reuse asynchronous cold-start executable resolution.
4. Reuse policy decoding and remove the unused wait helper. Keep the existing journal format; a typed-journal refactor is optional follow-up work.
5. Run focused provider regression tests after the fixes and rebuild the SDK-verified preview.

Results:

- Independent review found two correctness issues: a prepared action could retain the previously selected executable, and a release check could remove floating progress during launcher replacement. Both are fixed. Selection changes invalidate preparation immediately; mutation rechecks discovery without treating its own pending intent as the selected installation. An operation retains its presentation through completion until dismissed.
- The reuse, quality, and efficiency passes led to shared in-flight preparation, change-only policy publication, asynchronous runtime resolution reuse, one policy decode under the lock, and removal of an unused wait helper. The optional typed update-journal refactor is deferred; the existing JSON format remains unchanged.
- Baseline: 216 tests, zero failures, one opt-in network check skipped. Post-fix runtime/update run: 140 tests, zero failures, one opt-in network check skipped. Final setup/maintenance run after preparation cleanup: 46 tests, zero failures. Logs: `/private/tmp/rubien-provider-review-baseline.log`, `/private/tmp/rubien-provider-review-fixes.log`, and `/private/tmp/rubien-provider-review-final.log`.
- New regressions cover changed executable selections, final discovery before mutation, concurrent preparation, unchanged policy publication, progress during launcher removal, result retention after a failed release refresh, and cold-start resolution reuse.
- No live installer, updater, or sign-in ran during this review. Dependencies are unchanged.
- After unlock, rebuilt and opened the exact checkout preview through `scripts/preview-app.sh`. SDK 27.0 and deployment 14.4 checks passed. Coordinate clicks on Home and All References worked; Activity and Details remained at the far right and toggled correctly. The centered sample notice kept its muted icon/button colors and left Reading Activity unobstructed. Opening and closing Details preserved the notice. The preview remains open on Home with Reading Activity restored. Build log: `/private/tmp/rubien-provider-reviewed-preview.log`.

Implemented adapters and their validation evidence are listed below. An adapter is enabled only after its update contract and ownership checks are verified. Do not infer native resource retention merely from a surviving executable mapping.

## Implemented behavior

- Daily release checks and notices now lead to a structured Update dialog with the selected shared executable and the command Rubien will execute.
- The top-center floating notice is the update entry point outside Settings. Notices stack centrally so they do not cover the Reading Activity card. Its neutral background, fine gradient border and accent halo match the chat composer. macOS 26 adds a subtle neutral glass layer; older systems and Reduce Transparency use a solid surface. The accent icon and prominent Update now button identify the action. Verified installations can update directly; Details opens the command and version review. Unsupported installations offer Update instructions. Progress and cancellable waits stay visible in the notice. Closing Details preserves the notice; Later defers it. The duplicate composer action was removed. Settings retains automatic-update preferences.
- For visual checks, launch the Debug preview bundle with `--preview-provider-update-notice`. This switch requires the preview bundle identifier and is ignored in Release builds. It shows labeled sample versions; Update now displays a preview-only acknowledgment, Details opens an explanatory sheet, and Later dismisses the sample. None changes release records or runs an update.
- Codex npm: verify the package/bin mapping, Node/npm executables, global prefix and public registry. Update only the selected package to the checked version in the same prefix. Automatic updates are opt-in, shared by installation, require 30 seconds of quiet, and yield to new work before mutation. Repeated failures suspend automatic attempts.
- Native Codex: verify the default versioned installation and its `auto-update-version` marker. Use the reviewed complete official bootstrap without `--release`, preserving the latest-channel marker. Changed bootstrap bytes require adapter revalidation.
- Native Claude: verify the default launcher/version directory and call `claude update`, retaining its own channel, minimum/maximum version and managed settings. Native automatic updates remain vendor managed.
- Homebrew, custom wrappers/registries and Claude npm retain update instructions. In-app mutation is unavailable until those adapters can preserve their package and vendor policies; detecting a newer public release does not grant mutation eligibility.
- Codex npm usage takes a shared flock at spawn. The child inherits the descriptor, and the parent retains its reference through reaping. Provider metadata, version and authentication probes use the asynchronous spawn path with the same lease. Mutation holds an exclusive usage descriptor through version verification.
- A separate held intent flock is the admission authority. This replaces PID-based durable intent ownership: stale journal content cannot block new work after owner death, while inherited intent descriptors keep a surviving updater protected. Journals describe progress and recover interrupted operations; they never authorize replay. A ten-second watcher retires idle Codex servers in each cooperating app process. Existing active turns finish and queued callers wait.
- Package waits are cancellable and stop after two minutes. External sessions are checked by streaming the full process inventory and matching the selected installation root or launcher; command text is discarded after matching, and the early scan retains parent IDs to exclude this Rubien process’s children. Automatic preflight silently backs off for 1, 5, then 15 minutes when external sessions remain or inventory fails. The final scan after usage exclusion still checks all holders; a race found there defers for a minute without counting as a failure. Mutation has a 15-minute limit and cannot be cancelled through the UI. Quit returns AppKit’s deferred-termination result and replies after mutation and verification finish, including logout and updater relaunch requests. Pre-mutation waits are cancelled, and new actions are disabled during termination.
- Successful updates verify ownership and actual version, then refresh setup/release/model state. No sign-in credentials or library data are changed by the update flow.

## Validation evidence

- Initial focused run: 51 tests passed and one opt-in network test skipped.
- Runtime regression run: 211 tests, zero failures, one optional live-network test skipped. Classes: ClaudeCodeProviderTests, CodexProviderTests, CodexModelCatalogTests, ProviderSetupTests, ProviderUpdateTests, ProviderMaintenanceTests.
- Native Codex, disposable home: 0.159.1 → 0.160.0. Two live app-servers answered after the switch; all 43 old release files retained identical hashes; old executable and bundled helper remained runnable.
- Native Claude, disposable home: 2.1.287 → 2.1.288. Two live protocol processes returned successful control responses before and after the version switch. The old executable retained its digest and remained runnable. No authenticated/paid model turn was sent.
- Production npm action, disposable home/prefix: 0.153.4 → 0.160.0. The real Node launch chain retained an explicitly inherited descriptor. The action waited while an old app-server held usage, then updated and verified after it closed. No fake installer or update result was used. The first attempt exposed npm's redaction of UUID-shaped path components; the test fixture now uses a short non-secret directory name.
- Live logs and compact results: `build/ProviderUpdateValidation/retention/` and `build/ProviderUpdateValidation/live-npm-production/`. Tests require explicit environment opt-in; ordinary tests perform no downloads or shared installation changes.
- User's working Codex/Claude installations were not changed by these live tests.

Removed 2,147.9 MiB of disposable CLI binaries/caches after checking for live test processes. Compact logs, scripts, results and npm action journals remain. Fresh sign-in credential saving remains deferred by the user.

The preview build verified SDK 27.0 and deployment 14.4. After closing the old preview, `scripts/preview-app.sh` replaced and launched the exact checkout bundle. Live UI checks confirmed that coordinate clicks directly on Home and All References activate the correct view, the sidebar edge aligns with the toolbar, and Reading Activity stays at the far right. Assistant settings show Codex 0.153.4 → 0.160.0, Update…, and the unchecked automatic-install option. The Update dialog displays the verified shared npm prefix and exact command. It was closed without applying an update; the preview remains open in Assistant settings. Never copy an ordinary SPM-linked binary into the preview.

Final targeted runtime rerun: 188 tests passed after covering the temporary npm-launcher removal gap. The 13 maintenance tests include shared locks, real descriptor inheritance, cancellation before mutation, stale metadata, shared consent, automatic quiet-period gating and native Codex policy preservation.

## Final update-lifecycle review

Before committing:

1. Treat active external sessions and temporary coordination conflicts as deferrals, without increasing failure counts or suspending consent. Stream the process inventory and match only the selected installation.
2. Defer application termination until updates finish, cancel pre-mutation waits, and prevent new updates during termination.
3. Remove exclusive usage-lock status probes, restrict usage coordination to Codex npm, and reduce idle polling.
4. Make metadata probes asynchronous, cache release-store directory preparation, and clarify executable/package-manager names.
5. Cover deferral, large process inventories, termination, and directory recreation with focused tests. Keep the native Codex bootstrap compatibility gate: the recorded hash identifies the updater whose preservation of old release resources was tested, not a separate download-authenticity policy.

Completed:

- External-session and busy-lock deferrals preserve consent and failure counts, with a one-minute retry delay. Failed process inventories also defer. The inventory streams all output, keeps only one unfinished line plus matching PIDs, and uses full-width process commands. Bare `codex` and other installations no longer match.
- AppKit termination now returns `terminateLater` while operations settle, cancels pre-mutation waits, blocks new actions, and replies once after mutation/verification. No modal rejects quit.
- Automatic checks no longer acquire exclusive usage locks. Only Codex npm uses package coordination; Claude's unused pending-update checks were removed. The coordination tick runs every ten seconds.
- Metadata discovery awaits the existing asynchronous process runner. The synchronous-to-async semaphore bridge is removed. Release-store preparation is cached with directory-recreation recovery. Plans name the executable and optional package manager directly.
- Native Codex retains its documented bootstrap compatibility gate. Changing this gate requires repeating the old-resource retention check; a changed script offers instructions meanwhile.
- The first runtime run exposed a cancellation cleanup race: a cancelled task's sleep could abandon residual-group cleanup before reaping the leader. Cleanup now waits independently of cancellation within the existing deadline. A direct regression starts cleanup in an already-cancelled task with a residual child; the previous Codex overlap test also passes.
- Final validation: 237 tests, zero failures, one opt-in metadata-network test skipped. Classes: AgentAuthProbeTests, ClaudeCodeProviderTests, CodexModelCatalogTests, CodexProviderTests, ProviderMaintenanceTests, ProviderSetupTests, ProviderUpdateTests. Log: `/private/tmp/rubien-provider-lifecycle-final.log`. Eight added tests cover deferral/retry, failed inventory, large streamed inventories, adapter scope, termination, directory recreation, and cancelled cleanup.
- No live provider mutation or sign-in ran. Dependencies are unchanged. Changes remain uncommitted.


## Silent automatic preflight

The automatic scheduler now checks the process inventory after the quiet period and before presenting or starting an update. A blocked or failed scan changes only an in-memory retry deadline: it creates no action/intent/usage lock, writes no journal or policy, retires no server, and publishes no progress. Consecutive deferrals wait 1, 5, then at most 15 minutes. Manual Update remains available.

The early scan uses parent IDs to exclude descendants of this Rubien process, whose usage leases are coordinated during the actual action. The final scan still includes every matching holder after those leases drain, catching sessions opened between checks. Other processes remain conservative blockers during preflight. Concurrent ticks share the in-flight scan; consent, selection, plan, idle state, and pending intent are rechecked after it returns.

Validation: all 31 ProviderMaintenanceTests passed. Five new tests cover silent backoff and eventual retry, failed inventory, concurrent checks with consent changed by another model, ancestry filtering, and a session appearing after preflight. The silent-deferral test verifies unchanged policy bytes/directory contents, no usage directory, no progress state, and exactly one process scan per retry. Log: `/private/tmp/rubien-provider-silent-preflight-final.log`. No live provider mutation ran; changes remain uncommitted.
