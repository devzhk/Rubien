# Codex and Claude Code installation and updates

- **Date:** 2026-10-02; revised 2026-10-03 after independent review.
- **Status:** Phase 1 is implemented; both real installers passed through the setup model in temporary homes. The user deferred fresh sign-in credential persistence to developer testing after publication. Phase 2 release checks and advisory notices are being validated; see the [update notice plan](../plans/2026-10-03-provider-update-notices.md). Native manual updates still require ownership, channel/policy, and retention tests. Phase 3 remains separately gated. No native updater has been tested yet.
- **Area:** macOS Assistant setup, provider lifecycle, and Settings.
- **Scope:** Install, sign in, discover updates, and update shared Codex and Claude Code installations. Native automatic updates remain provider-owned. Rubien-managed package updates and their opt-in automation are a later gated phase.


## Implementation scope (2026-10-03)

The current implementation includes setup/sign-in, automatic release checks, update notices, manual native updates, and manual/opt-in automatic updates for verified Codex npm installations. Homebrew, Claude npm, custom registries and unrecognized ownership remain instructions-only. Native automatic updates remain vendor owned.

The package coordinator uses a held intent flock as its live-owner authority, with the shared/exclusive usage flock described below. Children explicitly inherit both descriptors. Journals retain progress and interrupted-operation recovery, but do not authorize admission or replay after owner death. This avoids a PID-reuse recovery protocol; a one-second watcher handles cross-process idle-server retirement, and waiting callers preserve their work. See [implementation and validation](../plans/2026-10-03-provider-update-actions.md) for adapter contracts and evidence.


## 1. Product decisions

Users should be able to start using either Assistant provider without entering commands in Terminal. Rubien shows the official installation command and the exact download-then-execute procedure it will use. After the user clicks Install, it downloads the full official script, runs it noninteractively, verifies the installation, and offers Sign in. The same settings subsequently show versions and update controls.

The user has explicitly chosen shared installations: an update made through Rubien should also be available to Terminal and other applications using that installation. Do not create a private Rubien distribution, duplicate a working installation, or add a second confirmation solely because an installation is shared.

Decisions:

1. Offer both providers independently. Installing one does not install the other or change the selected provider automatically.
2. Use official native installers for a genuinely missing provider. Preserve the installation method of existing providers.
3. Show the official one-liner and the actual execution procedure before installation, including noninteractive environment settings. The Install click authorizes that operation; no second approval dialog is needed.
4. Check for updates automatically by default while Rubien is running. Offer a per-provider opt-out.
5. Use the existing vendor updater for native installations. Do not add a second native auto-install loop. Later, offer Rubien-initiated automatic updates for verified package-manager installations, opt-in and off by default per installation.
6. Preserve the existing release channel and version policy. Do not downgrade or switch channels as part of an ordinary update.
7. Run verified native updates without draining chats or pausing new starts; the validated versioned-installation contract protects active processes. Move subsequent work to the new generation through external-change handling. Phase 3 requires installation-wide usage exclusion for package mutations. Never interrupt an active turn to update it.
8. Use the same provider cards during first-use setup and in Settings → Assistant.
9. Keep library browsing and reading available without installing or signing in to either provider.

Recommended delivery is a separate feature after the current 0.8.0 release candidate. The release version remains a separate decision.

## 2. Existing code and integration points

The current code already provides useful foundations:

| Existing component | Current responsibility | Design impact |
| --- | --- | --- |
| `Views/RubienSettingsView.swift` | Provider status, Recheck, executable overrides, model refresh | Replace the status rows with reusable setup/update cards; preserve advanced path controls |
| `Assistant/SpawnedAgentProcess.swift` / `AgentBinaryProbe` | Executable discovery, bounded version/auth probes, process groups | Reuse process ownership; add discovery and a streaming runner in Phase 1; enforce cross-process usage leases here in Phase 3 |
| `Assistant/ClaudeCodeProvider.swift` | Claude executable resolution, availability cache, per-turn processes | Refresh resolution after native changes from Phase 1; usage admission is added in Phase 3 |
| `Assistant/CodexProvider.swift` | Shared long-lived app-server, availability and metadata work | Refresh stale generations when active work finishes; native updates do not drain the server beforehand |
| `Assistant/CodexWorkScheduler.swift` | Codex work admission and queueing | Add maintenance admission only in Phase 3; native invalidation uses existing lifecycle/scheduling behavior |
| `Assistant/ClaudeSessionLeaseCoordinator.swift` | Claude conversation leases | Preserve existing semantics in Phases 1–2; installation-wide usage is added in Phase 3 |
| `Assistant/AssistantExecutionOwnership.swift` | Assistant execution ownership across Rubien processes | Coordinate with maintenance, but do not treat library ownership as an installation lock |
| `Assistant/CodexModelCatalog.swift` | Catalog cache and generation checks | Invalidate affected entries after a binary change and reload when signed in |
| `Assistant/AgentProvider.swift` / `AgentAvailability` | Installed/authenticated status | Add maintenance status and snapshot freshness so callers do not queue probes or claim absence during an update |
| `RubienPreferences.swift` | Provider preferences | Keep presentation preferences here; store installation-wide management policy in the shared ProviderManagement directory |

Existing details requiring deliberate changes:

- `AgentBinaryProbe.parseVersionString` strips prerelease information. Update comparisons need a separate strict version parser that retains prerelease identifiers and raw output.
- Current availability can classify an executable that fails `--version` as not found. Setup must distinguish absent, broken, inaccessible, and explicitly configured but missing installations. A failed probe must not offer to install a competing copy by default.
- `SpawnedAgentProcess.spawn` currently creates a process group, which does not itself remove an inherited controlling terminal. Installer launches need a separate no-controlling-TTY session path.
- Native binary replacement is routine for both vendors. External-update detection and cache/runtime invalidation ship in Phase 1.

## 3. User experience

### 3.1 Entry points

On first Assistant use, show “Choose an assistant” with a Codex card and a Claude Code card. Provide “Set up later.” Reopening a reader should not repeatedly reopen setup.

Settings → Assistant shows the setup card for the selected Provider. Switching Provider replaces that card; each provider retains its own setup state. The first-use chooser presents both options. A missing-provider message in Home or a reader opens the corresponding setup flow. Updates use a compact in-app notice; no system notification permission is required.

The cards use the existing Settings action button style, including hover, pressed, disabled, and keyboard-focus states. Status is expressed in text, not color alone. Commands are selectable, monospaced, and accessible to VoiceOver.

### 3.2 Card states

| State | Main content | Actions |
| --- | --- | --- |
| Discovering | Checking installation… | No duplicate probe action |
| Missing | Provider not installed; official command visible | Install, Copy command, Official instructions |
| Configured path missing | The selected executable cannot be found | Choose…, Use automatic discovery, Recheck |
| Installed but unhealthy | Found at a path, but verification failed | Retry check, View details, Official instructions |
| Signed out | Installed version; Sign in to use this provider | Sign in, Recheck; update controls remain available |
| Signing in | Complete sign-in in your browser; elapsed time | Cancel; repeated Sign in is disabled |
| Authentication unknown | Installed; sign-in status could not be confirmed | Check sign-in, View details; preserve existing provider availability behavior |
| Ready | Installed version; last successful update check | Check for updates; automatic-check setting (Phase 2); package auto-install setting only in Phase 3 |
| Update available | Installed version → available version | Update, Release notes; Later on the notice |
| New public release (advisory) | Installed and published versions; named publication source and last-check time | Update instructions; Later on the notice. Does not claim the selected installation is eligible for automatic replacement |
| Waiting for package use to finish (Phase 3) | Package update will start when this installation is idle | Cancel pending update |
| Another setup action is running (Phases 1–3) | Install/update in progress in this or another Rubien process; last known version | Observe current action; no duplicate launch; validated native usage can continue (§5.3) |
| Installing/updating | Named stage, elapsed time, expandable output | Cancellation only where supported safely |
| Native updater | Updates managed by Codex/Claude Code; enabled/disabled/unknown only when established | Check for updates, Update where supported, Official settings instructions |
| Action failed | Short cause and current installation health | Retry, Copy details, Official instructions |
| Unsupported management | Installed and usable, but Rubien cannot update this installation | Copy verified instructions or open official setup docs |

Do not show invented download percentages. Use stages such as Preparing, Downloading, Installing, and Verifying only when the runner can establish them; otherwise show Installing with elapsed time.

Advanced details contain the selected executable, installation method, channel if known, package manager identity, last check, and latest operation result. Keep these out of the primary flow except the installation command the user requested.

### 3.3 Installation

For a missing provider, display the official macOS command:

**Codex** ([official instructions](https://learn.chatgpt.com/docs/codex/cli)):

```sh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

**Claude Code** ([official instructions](https://code.claude.com/docs/en/overview)):

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

These are the copyable official terminal one-liners, verified against documentation on 2026-10-02 and inspected scripts on 2026-10-03. Rubien does not pipe a live download into a shell. Directly below the one-liner, show “Rubien downloads this official script completely before running it” and the exact staged command/environment from §6.1.

Codex installation must use `CODEX_NON_INTERACTIVE=1`, closed stdin, and no controlling terminal. The inspected script otherwise prompts through `/dev/tty` to remove a competing package-manager installation or launch Codex. Noninteractive mode declines those prompts, but can still create a duplicate installation; it does not replace the discovery/preflight requirement. Recheck all known candidates before installing and stop if another managed installation is found. Never set force/migration options to bypass this check.

Flow:

1. Discover the provider and any configured override.
2. Show the official command, actual staged execution procedure, Install, and Copy command.
3. On Install, take the exclusive per-provider/default-destination install lock and recheck absence. If another process installed it meanwhile, adopt and verify it instead. A broken executable, inaccessible configured path, or unclassified existing installation is not absence and must not enter this flow.
4. Download and validate completion of the official script, record its SHA-256, then execute it through the operation runner. Keep the card responsive and make detailed output available.
5. Discover the resulting executable and verify its version with a fresh process. Check the intended installation, not whichever unrelated binary happens to appear first on PATH.
6. Show Installed, then Sign in if needed.

An installer may modify the user's shell setup as part of its official behavior. Rubien does not independently edit shell startup files. Refresh discovery without requiring a Rubien restart.

If the user copies the command and runs it elsewhere, Recheck and a throttled app-activation probe discover the result. Rubien must not claim it performed that installation.

### 3.4 Sign-in

Sign in launches the selected CLI's official authentication flow, using the exact resolved executable. Initial adapters use `codex login` and `claude auth login`, subject to capability verification for the installed version.

- Show the explicit Signing in state. Deduplicate clicks by installation identity across windows and Rubien processes; a second request opens the current status instead of launching another login.
- Let the provider open its browser authentication page. Rubien shows “Complete sign-in in your browser.”
- Provide Cancel and a 10-minute overall deadline. Cancel/timeout terminates and reaps only the owned login process group and invalidates late callbacks. A fresh auth probe reconciles credentials if the browser completed concurrently; cancellation does not sign the user out or revoke credentials.
- Login holds a per-installation authentication-operation lock to deduplicate login attempts. Phase 1 starts login only after installation verification. In Phase 2, validated native retention permits login alongside a native update; completion still uses a fresh auth result. Phase 3 additionally requires a shared usage lease before login. Never block the UI thread waiting for a lock.
- Use a dedicated authentication runner, with a PTY only when the supported CLI requires it. Do not send authentication commands through an Assistant chat.
- Keep tokens, device codes, and authorization URLs out of retained operation logs and telemetry. Temporary instructions required to complete sign-in may be displayed in the active flow.
- After the command completes, run the existing provider auth probe; command exit alone is insufficient.
- A timeout or ambiguous auth response produces “Could not confirm sign-in,” not a false success or a claim that the provider is absent.
- If in-app authentication is unsupported, offer the exact command through Copy command and explain that sign-in must finish in Terminal. This fallback does not make installation fail.

Do not change existing API-key or enterprise authentication configuration. Do not collect passwords in Rubien. A usable provider with unknown auth status retains the current ability to attempt a turn; setup must not introduce a new hard authentication gate.

### 3.5 Updates and preferences

Each installed provider has **Check for updates automatically** (on by default), **Check for updates**, and an accurate last-check timestamp. A verified native installation can offer **Update** when an eligible update is established. Initial Homebrew/npm support compares against the official public package's latest release and offers **Update instructions**, labeled as general guidance. It does not claim that a generic command targets the executable selected in Rubien; verified package/prefix-specific commands wait for Phase 3 ownership detection.

For native installations, show **Updates managed by Codex** or **Updates managed by Claude Code**. Display enabled/disabled only when supported diagnostics establish effective policy. There is no Rubien auto-install toggle for a vendor-owned updater. If its settings cannot be read, say “Automatic-update status unknown.” Rubien does not silently edit the vendor's update policy, release channel, or version pins.

After the package-manager adapters pass Phase 3 gates, eligible Homebrew/npm installations gain **Update** and **Automatically install updates through Rubien**, off by default. Enabling automatic installation enables automatic checking. Disabling automatic checking cancels pending automatic work and disables that consent. The policy is shared across Rubien builds on this Mac for the same installation (§7).

Settings always displays the last successfully established available version and its freshness, regardless of updater policy. Native installations get a proactive update notice **only when their vendor updater is established as disabled** and an eligible newer version is known. Enabled, supported-but-unknown, stale, or unavailable updater status produces no proactive native notice. A manually requested check still shows its result inline in Settings. Unknown is never treated as disabled; check policy again before showing a delayed notice.

An eligible notice names the provider and offers Update (or Update instructions) and Later. Later suppresses that installation/version notice for seven days; a newer eligible version may produce a new notice only if the notice policy still permits it. Deduplicate per installation/version per app session and persist suppression. Following the user's 2026-10-03 clarification, Phase 2 also shows **New public release** advisory notices for likely npm/Homebrew installations. These compare installed and published versions and lead to general official instructions; they do not establish registry, prefix, pins, updater policy, or mutation eligibility. Phase 3 is still required for targeted package updates and automatic-install consent.

The first Phase 2 step may show native **latest published** metadata inline before channel/policy verification, clearly labeled as a public release comparison. It must not call that version an eligible native update or show a proactive native notice while updater/channel policy is unknown. Keep release-check status separate from installed/authenticated readiness.

Manual updates show their actual command in expandable details. Phase 2 native Update starts after action-lock/eligibility checks, even during a chat, with no “Update when idle” state. Only Phase 3 package updates wait for usage to end; the click authorizes that queued operation. Turning off future automatic installation does not cancel a manually queued package update or interrupt a running mutation. Turning off Rubien's checks has no effect on vendor-owned updates.

### 3.6 Provider-managed updates

Both native distributions have vendor update machinery. The inspected [Codex installer](https://chatgpt.com/codex/install.sh) maintains `~/.codex/packages/standalone/auto-update-version`, honors updater-parent guards, and owns an `install.lock`. The marker and guards establish support, not proof that a particular user's current launch mode will schedule updates. Never create, delete, or rewrite these private files as a Rubien update setting.

Claude documents native background updates and the manual `claude update` path. Preserve its effective channel and policy; see [Claude's update documentation](https://code.claude.com/docs/en/setup#update-claude-code).

Use provider-owned updates as the native default. Offer a manual Update for a verified eligible installation, re-probe just before action, let the official installer/updater manage its own lock, and treat an already-current installation as a no-op. Never take the vendor lock ourselves and then invoke an updater that needs the same lock.

Phases 1–2 serialize Rubien install/update actions but do not acquire shared usage leases for native processes. Phase 1 requires genuine absence; Phase 2 update safety depends on Phase 0 validating the vendor's versioned installation behavior. Phase 3 adds leases for package mutations; vendors and external terminals do not honor them. External-update detection, preserving active process generations, and refreshing before the next use are required from Phase 1. Do not promise that a vendor update waits for a Rubien conversation to finish.

## 4. Installation identity and supported adapters

### 4.1 Discovery

Use the existing provider resolution order for the executable Rubien runs. Collect additional candidates to identify ambiguity; do not silently change the chosen executable because another candidate is newer.

Record the launcher path and canonical target. In Phases 1–2, allow **likely native**, **likely Homebrew**, **likely npm**, and **unknown** labels using path/layout hints. Keep confidence/evidence with the label. For example, a target below Homebrew's Cellar/Caskroom suggests Homebrew; a wrapper below a global `node_modules` tree suggests npm; a provider's versioned native tree suggests native. A `.local/bin` launcher alone is insufficient to distinguish them. Contradictory hints stay unknown.

These labels explain discovery and select general documentation only. Presence of any candidate prevents the missing-provider installation path regardless of classification. A likely label grants no mutation, channel, prefix, or auto-update capability. Phases 1–2 do not need full Homebrew/npm ownership verification.

Phase 2 manual native Update separately requires verified native ownership/layout or a Rubien installation receipt (the retained verified successful-install journal record defined in §7) reconciled with the current launcher, plus the updater retention contract. A likely-native label alone must not enable Update. Phase 3 adds authoritative package-manager ownership/prefix/policy checks for targeted package instructions and mutations. Following a symlink alone does not establish ownership in either mutation path.

An installation identity contains:

```text
provider
launcherPath, canonicalExecutablePath
methodHint: likelyNative | likelyHomebrew | likelyNpm | custom | unknown
classificationEvidence: paths/layout hints (Phases 1–2)
verifiedOwnership: optional native proof (Phase 2) or package-manager proof (Phase 3)
ownerIdentity: verified native root or package manager path + prefix + package name
discoveryIdentity: canonical candidate path until ownership is established
installedVersionRaw, parsedVersion
channel: known value or unknown
updatePolicy: known constraints or unknown
fileFingerprint: file identity + size + modification time
capabilities: check, install, update, rubienAutoUpdate, authenticate
vendorUpdaterState: enabled | disabled | supportedButUnknown | unsupported
managementLimitation: optional user-facing reason
generation
```

Keep the stable ownership identity separate from a versioned symlink target that changes on update. A path override is a user selection, not proof of an unsupported install: recognize it if ownership can be established. A custom wrapper or app-bundled binary is never overwritten by guessing an installation method.

### 4.2 Adapter matrix

| Installation | Check source | Mutation route | Eligibility |
| --- | --- | --- | --- |
| Missing Codex | Not required to install | Official native install command above | Supported platform and verified installer contract |
| Missing Claude Code | Not required to install | Official native install command above | Supported platform and verified installer contract |
| Codex native | Official metadata matching the native release channel | Official standalone updater/installer route | Requires verified ownership, version source, and no-downgrade behavior |
| Claude native | Official metadata matching its configured channel/policy | Resolved `claude update` | Requires verified diagnostics and channel behavior |
| Homebrew | Phase 2: public Homebrew cask metadata and advisory release notices with general instructions | Phase 3: verified package/prefix metadata and targeted `brew upgrade` | Full ownership, prefix, pin, and policy detection is a Phase 3 requirement |
| npm global | Phase 2: public npm latest metadata and advisory release notices with general instructions | Phase 3: verified registry metadata and explicit version in the same prefix | Full package root, Node, npm prefix, registry, and updater detection is a Phase 3 requirement |
| Custom, app-bundled, unknown, or managed restrictions | Only when a trustworthy matching source exists | Instructions | No automatic mutation |

Expected npm package names are `@openai/codex` and `@anthropic-ai/claude-code`. Phases 1–2 may use path-based likely labels from §4.1 and general instructions; they do not claim ownership or a prefix-specific command. The full package-manager ownership, policy, and interpreter checks below belong to Phase 3. A directory name alone may inform a hint, but cannot authorize a package mutation.

For Homebrew, never run an unqualified `brew upgrade` or unrelated cleanup. A targeted upgrade may still update package dependencies according to Homebrew's rules; do not promise that only one file or package changes. Avoid global metadata refresh on every periodic check; use supported read-only metadata or a bounded cached query. Validate freshness before advertising an available version.

For npm, bind npm and Node to the installation being updated. Do not use the GUI app's first npm on PATH. Preserve the existing prefix and registry; do not rewrite `.npmrc`. Unrecognized registries and version-manager shims get instructions until a matching adapter is explicitly supported.

Fresh installs use official native installers without requiring Rubien to install Node or Homebrew. Existing installations are not migrated between package managers by an Update button.

### 4.3 Version discovery and comparison

Each adapter owns a typed `checkLatest` operation and its response decoder. A check must not invoke an installer or an update command that might mutate the installation.

- Use metadata from the installation's actual distribution/channel. An npm release is not proof that Homebrew or a native channel has the same release available.
- Before full ownership/channel verification, label public latest metadata as an advisory comparison and name its source. It never authorizes a mutation. Unknown/custom installations and prereleases get instructions instead of an assumed matching stable channel.
- Never scrape a human release-notes page to decide whether to execute an update.
- Parse semantic versions numerically, preserving prerelease identifiers. Ignore build metadata for precedence. Keep provider-specific normalization narrow and tested.
- Treat unknown versions as unknown; do not compare arbitrary strings lexicographically.
- Do not offer a downgrade when the installed version is newer than the channel's available version.
- Honor pins and managed restrictions. If effective policy cannot be established, automatic mutation is unavailable with an explanation.
- Package managers may advance between check and execution. Verification records the actual installed version; the UI does not insist that it equal a stale preview if it is a newer eligible release.

Candidate sources observed on 2026-10-03:

| Distribution | Candidate source | Observed response | Remaining validation |
| --- | --- | --- | --- |
| Codex native latest | `https://releases.openai.com/codex/channels/latest` | JSON release metadata with version/tag information, assets, download URLs, and SHA-256 digests; observed release 0.160.0 | Schema longevity, missing fields, policy/channel matching, supported architecture, and installer race behavior |
| Claude native latest | `https://downloads.claude.ai/claude-code-releases/latest` | Plain version text; observed 2.1.288 | Policy/channel matching, version validation, endpoint longevity, and behavior of the selected updater |

Versions here are evidence snapshots, never constants used to decide whether an installation is current. Both sources are used by the inspected vendor installers. `latest` is not a substitute for a configured stable channel or explicit pin; validate the matching source or report unavailable.

Phase 0 must capture decoder fixtures and verify these contracts, redirects, size limits, architecture coverage, and no-downgrade behavior. If no reliable matching source exists, show “Update check unavailable”; do not fabricate an available version. A reachable endpoint does not establish a permanently supported public API.

## 5. Scheduling and runtime coordination

### 5.1 Check schedule

- First background check: 30 seconds after app launch, for installed providers only.
- Normal cadence: once every 24 hours of wall-clock time while the app is open, with up to 30 minutes of jitter.
- Wake/activation: run one overdue check, not all missed intervals.
- Manual Check: bypass successful-cache age; deduplicate an already-running check and respect service Retry-After.
- Network timeout: 15 seconds per request, maximum 30 seconds per provider check.
- Transient failure: back off 1 hour, 6 hours, then 24 hours; a manual retry remains available subject to rate limits.
- Offline failures remain quiet outside Settings. Preserve last successful information with its timestamp; never call stale data current.

No launch agent, daemon, or updater remains running after Rubien exits. Provider-owned update behavior is independent.

### 5.2 Admission and locks, by phase

Separate first installation, versioned native updates, and package-manager mutation. Shared usage leases are a Phase 3 requirement, not a prerequisite for installing a missing provider.

| Phase | Protection | What it does not require |
| --- | --- | --- |
| 1: genuinely missing provider | Exclusive per-provider/default-destination install lock, absence recheck, local operation state | Shared usage flock, distributed idle-drain requests, provider parent-death supervisor |
| 2: verified versioned native update | Exclusive per-installation action lock, vendor update lock, external-change invalidation | Draining any chats, pausing starts, or integrating maintenance into CodexWorkScheduler |
| 3: package-manager mutation | Shared/exclusive usage flock, distributed intent and idle-drain protocol, inherited lease lifetime | Assuming that a package manager preserves old files just because native installers do |

#### Phases 1–2: action serialization

Use an exclusive nonblocking action lock under `~/Library/Application Support/Rubien/ProviderManagement/`, independent of library and app bundle ID. The initial key is provider plus canonical default destination; the resulting native installation must resolve to the same key. This prevents two Rubien processes starting the same install. Never unlink or replace an active lock file. On contention, discard the duplicate request and observe the existing action; do not queue another operation or block a UI thread.

Status checks briefly take shared locks on these action files, so readers cannot block one another. An action may retry briefly and asynchronously when only status readers hold the lock; contention with another action still opens its status without queuing a duplicate. A missing journal is not evidence of interruption. After the action lock becomes available, reconcile an unfinished record once under an exclusive lock and check actual installation/auth state; do not replay the action or create an installation receipt from recovery.

Phase 1 takes this lock, rechecks genuine absence across known candidates, then installs and verifies. If an installation is discovered, release the install action and show its actual status. Missing, broken, inaccessible, and unclassified are distinct outcomes. Once a provider exists, it cannot accidentally take this missing-provider fast path.

Phase 2 invokes the verified native updater under the installation action lock without waiting for local or remote chats, pausing starts, or retiring the server first. Let the vendor updater acquire its own lock internally. Other setup/update clicks deduplicate against Rubien's action lock; ordinary usage and login may continue on a retained native generation. No maintenance integration into CodexWorkScheduler is required. After a binary change, §6.3 invalidation preserves active work and moves subsequent work onto a fresh generation.

Keep a basic operation journal for progress, result, and interrupted-operation recovery from Phase 1. This is not the Phase 3 distributed intent/drain protocol. Readers can refresh status on Settings activation or bounded status polling; no cross-process usage notifications or shared leases are needed yet. Installer/updater-owned locking still matters if Rubien dies while its maintenance child continues: a new operation must reconcile that child/vendor state before retrying, never infer completion from loss of the app's action lock alone. Do not add a provider-usage supervisor for this recovery case.

**Phase 2 safety gate:** for each native updater separately, prove with installed-version tests that the old process's executable, dependent resources, and release directory remain usable across the update and its cleanup. Include a long-lived app-server, helpers launched after the version switch, and a second Rubien process. A surviving memory mapping alone is insufficient. Existing self-update support is evidence to investigate, not proof of this contract.

The inspected Codex script stages a version directory and switches symlinks; normal cleanup removes staging leftovers. It also has a branch that replaces an incomplete destination directory. Native repair/reinstall of the same version is therefore outside the Phase 2 safe-update path. Only eligible forward updates with validated retention behavior are supported. Claude's actual installed updater must pass the same tests; its bootstrap source alone cannot establish retention.

If an adapter fails the retention gate, keep native manual updates instructions-only for that adapter. Do not silently bring the Phase 3 usage protocol into Phase 1 or call an unverified mutation safe. Revalidate when supported updater behavior changes.

#### Phase 3: installation-wide usage exclusion

Add a coordinator shared by Home, readers, history, scheduled work, metadata, auth, and setup. Enforce typed usage/maintenance admission at `SpawnedAgentProcess.spawn` and all `AgentBinaryProbe` paths, including the synchronous `Process` path and Codex's metadata MCP listing. Audit actual call sites instead of assuming a fixed count. Discovery must avoid recursively acquiring a provider lease; revalidate identity after admission.

Usage takes `flock(LOCK_SH)`; maintenance takes `flock(LOCK_EX)` on the same stable per-installation usage file. Use canonical ownership, not versioned paths, for the key. Shared usage covers the process lifetime, including idle app-servers and cleanup. An exclusive action lock alone cannot protect a package being modified while another Rubien process uses it.

Protocol:

1. Publish one pending intent under a short control lock and release that lock before waiting. Use a unique owner token and verified process identity.
2. Notify other processes as a hint; the journal is authoritative. Stop new starts, finish active work, retire idle roots, and preserve queues. A journal watcher handles missed notifications.
3. Close the requester's shared-lease references after local cleanup. Do not convert a held shared lock to exclusive; such conversion is not an atomic reservation.
4. Acquire the exclusive usage lock asynchronously, then revalidate installation, policy, version, and intent before mutation.
5. Execute and verify using the maintenance owner's capability. Its verification children must not deadlock by reacquiring shared ownership against its own exclusive lock.
6. Record the result, clear only this owner's intent, close exclusive references after cleanup, and notify waiting processes to invalidate snapshots and resume.

A new usage request checks intent, obtains a shared lock, and rechecks intent/identity before spawn. If maintenance appeared, close its reference without launching. Automatic requests require a 30-second quiet period and yield to queued user turns/due scheduled work before exclusive acquisition. All lock waits use cancellable nonblocking retries, not UI-thread blocking calls.

**Lease lifetime after parent death:** prefer explicit inheritance of the locked descriptor into the provider child through spawn file actions. This avoids a new supervisor when the actual launch chain preserves that descriptor. Keep it out of unrelated child processes. Verify survival through exec, wrappers, helper launches, and parent death. Close local references rather than issuing `LOCK_UN` while inherited references may still be in use: duplicated descriptors refer to the same advisory lock ([Apple flock documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)).

Descriptor inheritance does not guarantee that arbitrary descendants preserve it. If a supported launch chain closes unknown descriptors early, establish an equivalent tested lifecycle mechanism or leave that adapter's mutation capability disabled. A supervisor is a fallback only if tests demonstrate it is needed, not a requirement imposed on early phases.

A daemonizing descendant can retain a descriptor after the visible turn ends. Stop an exclusive-lock wait after two minutes and report the verified holder's process name/PID when discoverable; otherwise say the holder could not be identified. Keep the update pending for explicit Retry/Cancel, and back off automatic attempts. Timeout never authorizes forced unlock, deletion of the lock file, or killing unrelated processes. An advisory owner record is diagnostic, not proof of current ownership.

Older Rubien builds, external terminals, and vendors do not participate. Their locks and observable use must still be respected; defer automatic package mutation when use cannot be assessed. Native version-switch safety and Phase 3 file-mutation safety are separate guarantees.

### 5.3 Availability during maintenance

From Phase 1, add operation state and snapshot freshness alongside installation/auth availability. Operation progress is not itself a reason to make an existing provider unavailable. Return promptly with known state rather than queuing redundant probes behind a running setup action. A missing snapshot stays unknown; it is not a false notFound result.

Phase 1 cannot mark a newly installed provider ready until verification completes. Duplicate install actions observe the existing action status. In Phase 2, an update-progress badge blocks duplicate updates but leaves readiness, active chats, new starts, and scheduled work unchanged for the verified native installation. Do not add a local usage gate or an auth-probe queue behind the native updater. Recheck can show the cached snapshot with progress and refresh after completion through existing probe scheduling.

Only Phase 3 pending usage exclusion/exclusive ownership defers new starts across cooperating processes. Availability then renders Waiting/Updating from the shared snapshot, and process admission independently enforces it. An active turn never appears signed out merely because an update is pending.

Scheduled work delayed by Phase 3 admission retains its existing queue/missed-run policy. Phase 2 does not introduce an update-related queue delay.

## 6. Operation execution and verification

### 6.1 Command representation and bootstrap download

An immutable operation plan contains provider, installation identity/generation, action, source URL, downloader arguments, interpreter/arguments, environment policy, working directory, expected channel, and verification steps. Display and execution are generated from this structure. The copyable vendor one-liner is labeled **Official terminal command**; the download-then-execute plan is labeled **Rubien will run**. Do not claim they are byte-for-byte the same command.

Never execute `curl | sh` or `curl | bash` in Rubien. `pipefail` only reports failure after some downloaded code may have executed. Instead:

1. Create a private unpredictable temporary directory (0700), with a non-symlink script file accessible only to the user (0600).
2. Fetch the official HTTPS script using `/usr/bin/curl` with failure reporting, bounded time, HTTPS-only redirects, and the private output path. Validate supported redirect hosts from adapter fixtures. Cap the download at 2 MiB and reject empty or clearly non-script responses. Only continue after the entire fetch succeeds; transport failure or incomplete declared length must not launch a shell.
3. Record the final source URL, byte count, and SHA-256 in the operation journal. A digest is an audit identifier, not a vendor signature or proof that the bootstrap is trusted. Compare file identity/digest immediately before execution; abort if it changed. Keep it inside the private directory until the interpreter finishes.
4. Execute the saved script directly via `/bin/sh` for Codex or `/bin/bash` for Claude, passing arguments as an array. Pin exact interpreter paths; never interpolate paths, remote text, versions, or logs into shell code.
5. Delete the temporary script on completion. Retain its digest and source in the bounded journal; clean only Rubien-owned abandoned temporary directories during recovery.

For example, show the explicit downloader/interpreter commands with a labeled `<temporary directory>/install.sh` placeholder and `CODEX_NON_INTERACTIVE=1` for Codex. Opening Settings must not create a temporary directory or fetch a script. On Install, acquire the action lock, recheck eligibility, then create the private directory and substitute its path in the same structured plan. Show the concrete commands in running-operation details and journal the path; this implementation-only substitution needs no second approval. Copy official command remains available separately. Relevant environment names are shown; secret proxy credentials are masked.

Codex installer execution always sets `CODEX_NON_INTERACTIVE=1`. Both installers use stdin `/dev/null`, pipes for output, and **no controlling terminal** (new session, no PTY). Merely assigning a process group or closing stdin does not prevent `/dev/tty` access. Authentication uses its separate runner and may require a PTY. Do not pass daemon, force, migration, custom-root, or updater-parent guard variables inherited from the host to the installer.

The inspected scripts verify their binary payload digests. That does not authenticate the downloaded bootstrap independently of HTTPS, nor does download completion prove every future vendor script is safe or semantically complete. Rubien relies on the official source, bounded transport, inspected adapter contracts, and fresh post-install checks. It does not claim reproducible or pinned bootstrap execution.

Use a dedicated maintenance environment. Preserve normal home/configuration ownership and required locale/temp values. Set `SHELL` to the user's verified login shell (account record preferred, validated environment fallback), since the Codex installer uses it to choose a shell profile. Do not execute the value as a command. Include a minimal system PATH sufficient for the vendor script; existing npm/Homebrew adapters add the verified interpreter/manager directories explicitly.

Support explicit allowlisted proxy and certificate variables such as `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY` and relevant lowercase counterparts, `SSL_CERT_FILE`, `SSL_CERT_DIR`, and `CURL_CA_BUNDLE` where the adapter supports them. These may contain secrets: never log their values. GUI apps may not inherit terminal proxy settings; use supported system-proxy resolution or provide an actionable configuration message rather than sourcing arbitrary shell profiles. Do not copy the entire environment, API keys, SSH credentials, or unrelated installer controls. Do not redirect provider configuration homes to a private Rubien installation.

Use a neutral working directory outside the repository and library. Installation and maintenance run as deterministic application code, never as an Assistant instruction.

### 6.2 Runner lifecycle

Create a streaming maintenance runner rather than using `AgentBinaryProbe.runSpawnedCommand` unchanged: its five-second version-probe use and unbounded read-to-end buffers are unsuitable for installation.

- Stream stdout and stderr concurrently; bound retained output to 1 MiB per operation and mark truncation.
- Limit retained history to the last 10 operations per provider, expiring after 30 days. Store no credentials.
- Set a 15-minute overall deadline and report prolonged inactivity after two minutes without assuming a quiet installer is hung.
- Before mutation starts, cancellation is immediate. During package-manager mutation, disable cancellation unless the adapter has verified a safe interruption contract; show “Finishing installation…” on a requested quit.
- On forced termination or timeout, reap Rubien-owned subprocesses, mark the result interrupted, and verify installation health. Never report rollback or successful cancellation of partial filesystem changes.
- Use graceful termination followed by bounded escalation only for the owned process group. Do not signal unrelated processes.
- A network or metadata check must never require administrator access. If installation requires an interactive password or privilege escalation, stop with actionable instructions; do not collect a sudo password in the app.

Redact credentials and authentication material before retaining or copying output. URLs with secret query parameters, environment values, and terminal control sequences are not safe diagnostic text. Auth logs use stricter ephemeral handling than install logs.

### 6.3 Verification

After an install/update, including failed or interrupted commands:

1. Re-discover the intended installation and compare stable ownership identity.
2. Run the selected executable's `--version` in a fresh process with a bounded timeout.
3. Confirm the result is parseable, does not downgrade the prior version, and satisfies known channel/policy constraints. A zero exit with an unchanged version is “No update applied,” unless it is demonstrably already current.
4. Mark availability/version/catalog entries stale only for the affected provider/installation. Preserve the identity and runtime of an active generation; recreate stale Claude wrappers and retire stale Codex servers only when their active work finishes. Disk version and the running generation's version may temporarily differ and must not be conflated.
5. Probe authentication without changing credentials. Phase 2 verification must respect existing runtime scheduling: if an auth/protocol/catalog probe would disturb active work, defer that probe and retain a stale-marked snapshot; do not delay the native update itself. Version verification can use a fresh standalone process under the validated retention contract. Phase 3 verification uses the exclusive usage owner's capability without reacquiring a conflicting shared lease. Release action/admission ownership after applicable checks; refresh runtime/model state when safe. No paid model turn is required, and a deferred connection check is not reported as completed.
6. Publish the actual installed version and health. Keep installation success separate from sign-in or service-network failures.

External-update handling ships in Phase 1. Compare the launcher target and binary fingerprint on activation/recheck and before new work, including work sent to a still-running shared server. Preserve any active generation until its turn completes; then retire stale idle servers, invalidate version/catalog state, and start a fresh generation before the next turn. Never kill a turn because the on-disk binary changed. Rebuild environment and resolution if ownership changes. A vendor can still update between checks; handle launch failure with one fresh discovery/retry, not an unbounded restart loop.

Do not automatically downgrade after failure. Generic rollback cannot be guaranteed for shared package-manager installations. Offer Retry, Recheck, and appropriate official recovery instructions while preserving chats and the library.

## 7. State and persistence

Represent installation, authentication, update information, and operation progress separately. A signed-out installation can still be current or updating; a failed update check must not make the provider unavailable for chat.

Proposed types:

```text
ProviderInstallationSnapshot
ProviderAuthenticationState
ProviderUpdateInfo
ProviderCheckPreferences          // Phase 2: automatic checking and notice policy
ProviderAutoInstallConsent        // Phase 3 only: package update authorization
ProviderMaintenancePlan
ProviderMaintenanceOperation
ProviderManagementError
```

Operation transitions:

```text
idle → planning → preparing → running → verifying
     → succeeded | noChange | failed | interrupted

planning → waitingForUsage → preparing (Phase 3 only)
planning/waitingForUsage/preparing → cancelled (before mutation)
```

Action-lock contention creates no new operation state: the UI observes the existing action and does not automatically launch a follow-up when it finishes.

Every async completion carries a provider and generation token. A path change, newer check, or external installation replacement invalidates older results. Keep the full operation plan stable after execution starts; disable path edits for that provider until it finishes.

Persist per installation under `~/Library/Application Support/Rubien/ProviderManagement/`:

- Automatic checking policy and, when Phase 3 is supported, explicit Rubien auto-install consent.
- Last successful check, eligible version, source/channel, and metadata freshness.
- Phase 2 notice suppression and provider-owned updater observations with timestamps; Phase 3 adds shared pending-maintenance intent. Pending local actions in Phases 1–2 do not drive cross-process usage admission.
- Operation journal: owner token, action, old/new versions, timestamps, identity, stage, script source/digest where applicable, result, and sanitized diagnostics.
- Phase 1 installation receipt: retain the compact successful-install journal record after fresh executable/version and destination verification, including provider, native root, launcher/target, verified version, source/digest, and completion time. Keep it beyond diagnostic-log expiry; failed, interrupted, or merely discovered installations create no receipt. Phase 2 must reconcile it with the current installation before using it as ownership evidence.

Dev and release builds must read the same management policy for the same installation. Use a versioned file schema, owner-only permissions, a short separate policy lock, and atomic replacement for policy/journal data. Never atomically replace a lock file. Phases 1–2 reload on activation or bounded status polling; Phase 3 adds notification-assisted intent watching. Observable UI state refreshes from the persisted source. Unsupported schema versions disable mutations instead of overwriting newer policy.

Persist before mutation. After a crash, reconcile the operation owner/lease and actual installation, mark interrupted work accurately, and never replay a mutation blindly. Pending manual intents require the same identity and a fresh eligibility check. Future automatic intent derives from the shared consent after recovery. A missing policy file means no automatic-install consent.

Keep purely visual preferences, such as collapsed details, in normal local defaults with observable bindings. Installation consent must not live only in app-bundle UserDefaults because dev and release builds may differ. All management state remains outside the library and iCloud; no database or sync schema changes are needed.

Selecting a different installation never transfers consent from the old one. Read any existing consent for that exact destination identity; otherwise default off. A normal versioned symlink change within the same installation preserves consent. Unrecognized identity changes suspend mutations pending rediscovery.

## 8. Error behavior

| Phase | Condition | User-facing result | Recovery |
| --- | --- | --- | --- |
| 2–3 | Offline or rate limited during a check | Could not check; last checked time retained | Retry later; respect Retry-After |
| 1–2 | Installer download fails | Installation/update failed to download | Retry; official instructions |
| 1+ | Executable exists but probe fails | Installation needs attention | Recheck or repair instructions; no duplicate install |
| 3 | npm/Node/prefix mismatch | Rubien cannot safely update this installation | Explain verified mismatch; official instructions |
| 3 | Package manager busy | Another package update is running | Retry later; no lock deletion |
| 1–2 | Native installer/updater busy | Another setup action is running | Observe/retry; no vendor lock deletion |
| 1+ | Permissions/admin prompt | Additional setup is required | Official instructions; no automatic escalation |
| 1–2 | Installer exits zero without usable executable | Could not verify installation | Diagnostics and Retry |
| 2–3 | New version installs but auth expired | Updated; sign-in required | Sign in |
| 2–3 | Version advances but protocol check fails | Updated; Rubien could not connect to this version | Retry connection; diagnostics |
| 1+ | App crashes or user forces quit | Previous operation was interrupted | Reconcile process and installation before mutation |
| 1+ | Multiple installations | Show the one Rubien uses | Advanced Choose control; no update-all operation |
| 2 | Native ownership/channel/retention not verified | Update through Rubien unavailable | Official instructions; keep working provider |
| 3 | Package policy/updater ownership unsupported | Automatic update unavailable | Explain restriction; preserve working provider |

Phase 3 automatic-install failures produce one dismissible notice per failed attempt, then back off. Permissions, ownership, or compatibility failures suspend those automatic attempts until the user retries or identity/configuration changes. Phase 2 background-check failures follow §5.1 and do not launch an installer or imply a vendor updater failed.

## 9. Implementation structure

Suggested new files under `Sources/Rubien/Assistant/ProviderManagement/`:

- `ProviderInstallation.swift`: identities, versions, capabilities, and discovery results.
- `ProviderInstallationDetector.swift`: executable discovery and likely labels first; native update proof in Phase 2, full package ownership in Phase 3.
- `ProviderMaintenanceAdapter.swift`: typed adapter protocol and native/Homebrew/npm implementations.
- `ProviderUpdateService.swift`: metadata checks, cache, version eligibility, and schedule.
- `ProviderMaintenanceCoordinator.swift`: Phases 1–2 setup-action deduplication, exclusive action lock, and recovery journal; Phase 3 adds usage admission and distributed intent.
- `ProviderMaintenanceRunner.swift`: subprocess lifecycle, streaming output, redaction, deadlines.
- `ProviderAuthenticationCoordinator.swift`: interactive login lifecycle and fresh auth verification.
- `ProviderManagementModel.swift`: observable UI state and persisted preferences.

Suggested views:

- `Views/Assistant/ProviderSetupCard.swift`: reusable provider card.
- `Views/Assistant/ProviderOperationDetailsView.swift`: command, stage, output, recovery actions.
- `Views/Assistant/AssistantSetupView.swift`: first-use presentation using the cards.

These names are proposed; integrate with existing project naming rather than forcing a large view refactor. Phase 3 usage admission belongs at actual process boundaries, not just Settings actions. Phases 1–2 use setup-action state and native generation invalidation without a scheduler maintenance gate.

Keep macOS UI and process management behind the appropriate platform guards. This feature manages local desktop prerequisites; it does not add library data or mutations and therefore does not require new Rubien CLI/MCP tools. The Linux graph must still compile.

## 10. Delivery phases

### Phase 0 — validate provider contracts

In a disposable test account or environment, verify official installers, paths, permissions, Apple Silicon/Intel support, and authentication flows for Phase 1. For Phase 2, validate the two candidate metadata endpoints, effective channel/policy, and each native updater's retention contract from §5.2. Exercise a running old release across the update, including resources/helper launches after the symlink switch, and verify old release directories survive relevant cleanup. Test Codex and Claude separately; do not infer one vendor's behavior from the other. Record exact commands and fixtures. Full npm/Homebrew ownership detection is a Phase 3 gate. Do not experiment against a developer's shared working CLI.

An adapter is released only for capabilities verified here. Native install/sign-in delivery can proceed after its Phase 1 contracts pass even if a metadata endpoint remains unresolved. Phase 2 version notices require a validated metadata contract; manual updates additionally require retention tests. Unsupported mutation routes remain instructions-only. Phase 3 has additional ownership and lifecycle gates.

### Phase 1 — installation, sign-in, and native update awareness

Implement discovery, cards, staged script download/execution, one exclusive per-provider/default-destination install lock, local operation state, official Install/Copy command, Sign in lifecycle, maintenance-aware availability, vendor updater status, and external-update invalidation. Distinguish missing, broken, and overridden paths. Complete clean-machine setup and concurrent-install tests. Shared usage leases, distributed idle draining, and provider parent-death lease tests are not Phase 1 gates.

The Phase 1 runner passes its action lock to installer and login children. The clean-account gate must confirm that both vendors' real process trees release this descriptor after success, cancellation, timeout, and Rubien exit, with no lingering descendant holding setup unavailable. If that check fails, fix action-lock ownership or process cleanup before delivery. A finished journal alone must not override a held lock. These checks cover setup actions, separate from Phase 3 provider-usage leases.

### Phase 2 — update checks and manual updates

First validate public metadata contracts and deliver version comparison, daily checks, Settings results, and npm/Homebrew advisory notices with general update instructions. This addresses the user's requirement that a new package release should not go unnoticed. Checks do not depend on authentication or start a provider chat.

Then validate native ownership, channel/policy, and retention contracts before enabling native manual Update, native notices for established disabled updaters, action serialization, and recovery. Updates do not drain local chats or integrate maintenance into CodexWorkScheduler. Full package ownership checks remain in Phase 3. No second native background installer or shared usage lease is required.

### Phase 3 — optional package-manager updates and automation

Preserve the requested capability as a separately gated extension: first implement full Homebrew/npm ownership detection and targeted instructions, then manual updates, then opt-in automation through the same executor. Shared/exclusive usage leases, distributed maintenance intents, and inherited-descriptor parent-death tests belong here. Enable mutations only after prefix ownership, pins, vendor updater interactions, policy sharing, safe failure behavior, and multi-process tests pass. Do not migrate existing installs or override package-manager policy to make a button work.

If the same installation already has a vendor/package-manager automatic updater enabled, display it and avoid a competing Rubien loop. Unknown updater ownership blocks automatic mutation. Shared consent, quiet-period scheduling, external-use deferral, crash recovery, and backoff are required. This phase does not add a native auto-install loop and is not required to ship Phases 1–2.

Each phase should build and pass focused tests. Follow the repository's review-before-commit workflow; this document itself does not authorize publication or running real installers on the user's machine.

## 11. Verification and acceptance criteria

### Automated tests

Use fake executables, local fixture responses, isolated homes/prefixes, a fake clock, and injected process/network clients. Normal tests must not download installers, update real tools, open real authentication sessions, or require provider accounts.

Tests are scoped by delivery phase; later-phase cases are not prerequisites for Phase 1.

| Phase | Required coverage |
| --- | --- |
| 1 | Missing vs broken executable vs invalid override; any discovered candidate blocks a duplicate native install even when its method is unknown |
| 1 | Likely native/Homebrew/npm labels from path hints, ambiguous hints staying unknown, and no mutation authority from a likely label |
| 1 | Displayed structured plan matches execution; paths/metacharacters remain arguments; opening Settings creates no installer temp directory |
| 1 | Partial/failed/oversized/redirected script download never executes; temporary-file substitution rejected; actual path/source/digest journaled |
| 1 | Nonzero exit, exit-zero/no-binary, bounded output, timeout, orphaned pipes, cancellation, and crash recovery without blind replay |
| 1 | Concurrent installs use one exclusive action lock; absence is rechecked after acquisition; second process observes the result |
| 1 | Codex has CODEX_NON_INTERACTIVE=1, closed stdin, no controlling TTY even from Terminal; no uninstall/TUI-launch branch |
| 1 | Login Cancel/deadline and window/process deduplication; late callbacks cannot restore stale UI state |
| 1 | External updates invalidate disk/cached state while preserving active runtime generations; no unconditional enabled-updater claim |
| 1 | Observable status, auth-unknown handling, secret redaction, SHELL/proxy/certificate propagation, and Linux compilation |
| 2 | Numeric/prerelease version ordering, unknown output, newer-than-channel, pins, channel matching, and no downgrades |
| 2 | Native ownership proof is separate from likely labels; unproven native ownership or retention never enables Update |
| 2 | Daily checks, wake, offline, Retry-After, opt-out, Later suppression, and notice deduplication |
| 2 | Native notice shown only with freshly established disabled updater; enabled/unknown/stale status stays quiet; Settings still shows known available version |
| 2 | Native update starts during active local/remote work; no idle wait or scheduler pause; update-progress badge preserves readiness |
| 2 | Existing generation finishes normally; next work uses new binary; deferred auth/catalog probes do not kill or reset active work |
| 2 | Metadata/retention contract tests cover old executable, resources, and late helpers; repair/reinstall stays outside safe native update |
| 2 | Public package release notices name installed/published versions and lead to general instructions without claiming prefix, registry, pins, or mutation eligibility |
| 1–2 | Stale completion/path changes cannot overwrite newer state; installed/version status is distinct from auth/service failures |
| 2–3 | Check policy (2) and auto-install consent (3) agree across dev/release identities and stay outside library/iCloud |
| 3 | Full Homebrew/npm ownership, Node/npm prefix, registry, pins, updater policy, targeted command, and unsupported shim cases |
| 3 | Shared usage in Rubien B excludes package mutation in A across libraries/builds; alias identity, idle-root drain, cancellation, inherited descriptors, and parent death |
| 3 | Usage-admission race tests across Home, readers, history, scheduled jobs, metadata, auth, and synchronous probes |
| 3 | Pending queues resume after every terminal outcome; retained daemon descriptor causes bounded wait with verified-holder/unknown diagnostics, never forced unlock |
| 3 | Auto-install consent, quiet periods, external-use deferral, repeated failure suspension, cross-process intent recovery, and vendor updater deduplication |

### Manual smoke matrix

| Phase | Scenario | Required result |
| --- | --- | --- |
| 1 | Clean Mac account, each provider | Install from displayed plan, verify, sign in, complete a user-authorized turn |
| 1 | Two Rubien instances install missing provider | One installation; both observe its verified result |
| 1 | Provider updated externally | Active work survives; subsequent work sees current binary/models |
| 1+ | Offline, permissions, forced quit | Accurate status/recovery; library and chats preserved |
| 1+ | VoiceOver, keyboard, appearance | Readable states, accessible commands, visible feedback |
| 2 | Native update during long-running local and remote chats | Update proceeds; old executable/resources remain usable; no chat drain; subsequent work uses fresh runtime |
| 2 | Scheduled work due during native update | Normal scheduling continues; no maintenance-related pause |
| 2 | Self-updating native installation | Settings shows eligible version; no proactive notice unless updater is established disabled |
| 2 | Existing Homebrew/npm installation | Likely label and general official guidance, no verified-prefix claim |
| 3 | Existing Homebrew/npm installation | Verified targeted command and update after usage drains |
| 3 | Two libraries/processes using same package installation | Active usage blocks mutation; queued work resumes after maintenance |

Shipping criteria:

- Users can install either supported native CLI and reach sign-in through Rubien without opening Terminal in the normal supported flow.
- Users see an accurate eligible update and can apply it with one click on verified native routes; package-manager instructions are explicit until their adapters ship.
- Native automatic updates are provider-owned and accurately represented. Future Rubien package automation is opt-in, shared per installation on this Mac, and uses the verified manual pipeline.
- Rubien updates the shared installation and does not silently change channels, package managers, selected executable, or authentication configuration.
- Active Rubien work is not interrupted, and failures cannot be presented as success.

## 12. References and verification boundaries

Official documentation consulted on 2026-10-02; installer scripts and metadata inspected without execution on 2026-10-03:

- [Codex CLI installation and update instructions](https://learn.chatgpt.com/docs/codex/cli).
- [Claude Code installation](https://code.claude.com/docs/en/overview).
- [Claude Code setup and update behavior](https://code.claude.com/docs/en/setup).
- [npm metadata queries](https://docs.npmjs.com/cli/v11/commands/npm-view/).
- [Homebrew command reference](https://docs.brew.sh/Manpage).
- [Codex installer source](https://chatgpt.com/codex/install.sh), observed SHA-256 `150e3cf675682efeaac115aa3747add3f27887896d04ce6d0b56478d8b428bf6`.
- [Claude installer source](https://claude.ai/install.sh), observed SHA-256 `3a68d3406cf674e17bed1733a4dcf37805e2e47d87417700007d7e1aa766a944`.
- [Codex latest channel metadata](https://releases.openai.com/codex/channels/latest).
- [Claude latest version metadata](https://downloads.claude.ai/claude-code-releases/latest).

Phase 0 script hashes identify inspected snapshots, not provider-version pins. The native Codex mutation adapter additionally requires the bootstrap whose old-resource retention was validated. If its bytes change, in-app mutation falls back to instructions until that contract is revalidated. First installation uses the complete current official script: there is no prior installation or running generation whose resources it must preserve. Both flows use the same official source and download validation; the extra update check is a compatibility gate, not proof of script authenticity. The Codex script directly establishes prompt suppression, shell-profile selection, update markers/guards, vendor locks, and payload checks. The Claude script directly establishes its version source and payload checks. Runtime scheduling and effective update settings still need installed-version tests.

The UI, cadence, state machine, locks, recovery policy, and file structure are Rubien design decisions. Official sources establish entry points; Phase 0 tests establish supported adapter contracts before mutation capabilities are enabled.

**Revision note — 2026-10-03:** refined installer execution, native-update validation, phased locking, discovery confidence, notice policy, and phase-specific acceptance checks.
