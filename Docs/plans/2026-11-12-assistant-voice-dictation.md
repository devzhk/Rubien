# Assistant voice dictation

Add a microphone button to the Assistant composer that transcribes speech into
the draft, on-device, using Apple's Speech framework. No bundled model and no
new package dependency.

Revision 2 (2026-11-12). Revised after an independent Codex review
(`gpt-6.1-sol`, high effort; raw output in
`/tmp/rubien-voice-dictation-plan-review-2026-11-12.md`). The review's 13
findings were checked against the code and SDK headers and all are adopted;
see "Changes from revision 1" at the end.

## Scope

- Speech-to-text into the composer draft, in every place the composer appears:
  the reader sidebar (PDF, web, attachment readers) and Agent Home.
- The user reviews and edits the text, then sends it as usual. Dictation never
  sends a turn by itself.

Not in this plan: spoken replies (text-to-speech), a hands-free voice mode,
Whisper or any cloud transcription, a global keyboard shortcut, dictation in
the note editor or search fields, and any CLI or MCP surface (UI-only, so no
parity work is required).

## Verified facts

- **One composer.** Both surfaces render `ChatSurfaceView.composerBox`
  (`Sources/Rubien/Assistant/ChatSidebarView.swift:1053`). Home owns its draft
  externally and stays mounted while hidden
  (`ContentView.swift:1437`, `retainedDetailSurface`).
- **Typed edits already reconcile mentions.** Native edits flow
  `textDidChange` → draft binding → `.onChange(of: draft)` →
  `PaperMentions.reconciling`, which handles one contiguous edit. Text and
  selection publish as separate bindings and coalesce
  (`ComposerTextView.swift:441`, `ChatSidebarView.swift:156`).
- **Writing the draft from SwiftUI is the wrong path for streaming.**
  `updateNSView` replaces the whole string, resets selection bookkeeping, and
  clears undo on every external write (`ComposerTextView.swift:384`).
  `completeMention` only gets away with it because it reconciles mentions
  first and then sets `reconciledDraft` (`ChatSidebarView.swift:1851`).
- **The editor has no pre-mutation hook today.** The coordinator implements
  `textDidChange` and `textViewDidChangeSelection` only; there is no
  `shouldChangeTextIn` delegate and no marked-text check.
- **Build routes.** `build-app.sh` assembles the bundle two ways: copying an
  xcodebuild `.app`, or writing its own Info.plist (`assemble_app_bundle`,
  line 140). Common stamping runs after both. `sign_bundle` applies
  `--options runtime` for every signed build, debug included, and returns
  early when `CODESIGN_ENABLED=0`. `preview-app.sh` writes a separate
  Info.plist and ad-hoc signs without Hardened Runtime. `release.sh` signs,
  notarizes, and publishes in one invocation.
- **Speech SDK (installed macOS 27.0 SDK).** `SpeechAnalyzer`,
  `SpeechTranscriber` (with a separate `isAvailable`), `DictationTranscriber`,
  `AssetInventory`, and `AnalysisContext` are available from macOS 26.
  `AnalyzerInputConverter`, `CaptureInputSequenceProvider`, and the
  error-returning tap-install overload are macOS 27 only.
- **Audio SDK headers.** Input is unavailable unless the input node's hardware
  format has non-zero sample rate and channel count, and using it anyway can
  raise an exception. The engine must not be torn down inside its
  configuration-change notification handler (deadlock). The simple
  `AVAudioConverter` buffer-to-buffer call cannot change sample rate.
- **Legacy recognizer.** `SFSpeechRecognizer` documents error 201, "Siri or
  Dictation is disabled", and on-device recognition is only honored when
  `supportsOnDeviceRecognition` is true.

Reported by the reviewer, not checked by me: the CI `macos-26` image currently
defaults to Xcode 26.6 with the macOS 26.5 SDK, and Apple's documentation
limits the speech-recognition authorization prompt to `SFSpeechRecognizer`.

## Decisions (change any before Phase 2)

1. **On-device only.** No backend sends audio to Apple's servers. If a
   language has no on-device support, the button says so.
2. **Live streaming into the draft**, at the caret (replacing a selection, or
   appended when the editor has no selection).
3. **Click to start, click to stop.** Stop drains the last words for up to
   1.5 seconds. Sending with ⌘↩ while listening freezes the text first and
   sends exactly what is visible.
4. **Typing ends dictation.** Any user edit freezes dictation before the edit
   is applied, and the user's edit wins.
5. **One dictation at a time, app-wide.**
6. **Language defaults to the system language**, with a picker in Settings →
   Assistant. Apple's recognizers take one language per session.
7. **Mention suggestions are suppressed while listening.**

## Design

New folder `Sources/Rubien/Assistant/Dictation/`, every file `#if os(macOS)`.

### Editor bridge (replaces revision 1's SwiftUI splice)

Dictation edits are applied inside `ComposerNSTextView`, not through the draft
binding. `ComposerTextView` gains an optional `ComposerDictationBridge` that
its coordinator attaches to.

- `begin()` captures the insertion range from the text view and refuses to
  start while the input method has marked text.
- `update(transcript)` replaces the live dictation range with one range edit,
  using the text system's change notifications, so the result reaches the
  draft binding and the mention reconciler exactly like typing. A leading
  space is added when the preceding character is not whitespace. The whole
  session is one undo group.
- The coordinator adds `textView(_:shouldChangeTextIn:replacementString:)`.
  Any change not made by the bridge reports a foreign edit synchronously,
  before the mutation, which freezes dictation. Marked text appearing during
  dictation counts as a foreign edit.
- An external whole-string replacement (send clears the draft, conversation
  switch) also freezes dictation.

The range arithmetic lives in a pure helper so it can be unit-tested; the
bridge itself is tested by driving a real `ComposerNSTextView` offscreen.

### Stop semantics

Two distinct operations, implemented by every backend:

- **Freeze** — synchronous. Stops publishing at the current visible text,
  invalidates the session generation, cancels the engine. Used by send,
  foreign edits, handoff to another surface, surface teardown, and app
  termination. Late engine results are dropped.
- **Finish** — the user's Stop click. Stops capture, lets the engine finalize
  already-captured audio, applies final results until done or a 1.5 second
  deadline, then ends. A foreign edit during the drain freezes.

Cleanup is idempotent and also runs from stream termination.

### Ownership and lifecycle

`DictationController` is a shared `@MainActor` object. Each composer surface
has a stable id, and each start gets a fresh generation. The controller
re-checks owner and generation after every await (permission prompt, asset
download, engine preparation), so a cancelled start cannot come alive later.
Stops are owner-scoped, so a disappearing surface cannot stop its successor.

Freeze triggers: send, Home becoming inactive, pane removal, reader window
close, conversation change, another surface starting, and
`applicationShouldTerminate` before providers and readers shut down. A silence
timeout finishes the session after 30 seconds without new text.

### Audio capture

`MicrophoneCapture` wraps `AVAudioEngine`:

- Validates the hardware input format (sample rate and channel count both
  non-zero) before installing a tap; otherwise reports "no microphone".
- Uses the tap overload available on macOS 14.4 and the CI SDK.
- The tap callback runs off the main thread and only copies buffers into a
  bounded stream (newest kept) consumed by the backend.
- A configuration-change notification only signals the controller; teardown
  happens later on the controller's own path, never inside the handler.
- Sample-rate conversion uses the input-block `AVAudioConverter` API.
- Partial startup failures run the same cleanup as a normal stop.

Backends read from an `AudioSource` protocol. `MicrophoneCapture` is one
implementation; a file-backed source is the other, used by tests.

### Backends and selection

- **macOS 26+, first choice:** `SpeechAnalyzer` + `SpeechTranscriber`, when
  `SpeechTranscriber.isAvailable` and the locale has an equivalent supported
  locale.
- **macOS 26+, second choice:** `SpeechAnalyzer` + `DictationTranscriber`,
  for languages or devices the newer model does not cover. It does not depend
  on the Siri/Dictation system setting.
- **macOS 14.4–15, and last resort on 26+:** `SFSpeechRecognizer`, only when
  `supportsOnDeviceRecognition` is true.

Each backend has a small pure accumulator that turns its native results into
`DictationUpdate` (finalized text plus volatile tail): time-ranged segments
with `isFinal` for the analyzer, cumulative snapshots for the legacy
recognizer.

Asset states are distinct in the UI: language unsupported, model needs
download, downloading with progress, installed. Changing language releases
the previously reserved locale so reservations are not exhausted.

### Authorization

Decided per backend before prompting: microphone permission for every
backend; speech-recognition permission only for the legacy backend. The
controller takes an injected authorizer so tests cover denied microphone,
denied speech with an analyzer backend still usable, and cancellation while a
prompt is open. Callbacks are hopped to the main actor.

### UI

`ComposerDictationButton` sits in the `composerBox` control row before the
send button: `mic` idle, spinner while preparing, accent `mic.fill` while
listening. A popover explains failures and links to the matching System
Settings privacy pane when a permission is denied.

## Phases

Each phase is one commit that builds and passes its tests. Per the repository
workflow, ask before each non-trivial commit whether to run the independent
review and the simplify sweep.

Focused tests run as `swift test --filter RubienTests.<Class>`; the broader
app suite as `swift test --filter RubienTests --skip ActivityRecordTests`.
Linux compilation is covered by keeping every new file Mac-gated and by the
CI Linux job.

### Phase 1 — Bundle permissions and the microphone-inheritance gate

- Add a privacy-string stamping step in `build-app.sh` that runs after either
  assembly route and before signing: `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`. Add the same keys to the
  `preview-app.sh` Info.plist.
- Add `com.apple.security.device.audio-input` to `Rubien.entitlements`.
- Assertions: both strings non-empty in every build, signed or not; the
  entitlement's value true in the final signature when signing is enabled;
  the same check on the `dev-launch.sh` final signature.
- **Gate (uncommitted spike):** in a signed Hardened Runtime debug build,
  grant Rubien the microphone, then have a spawned Claude Code and a spawned
  Codex process each attempt a short recording, including a provider process
  that was already running before the grant. Record what happened here.
  Then decide: accept and document the capability, or move capture into a
  helper with its own permission identity. Responsibility disclaiming is not
  assumed to be a supported fix. The UI phases do not start until this is
  decided.

#### Phase 1 status (2026-11-12)

Plumbing is implemented and uncommitted, pending the gate decision below
(choosing a separate helper would move the entitlement out of the main app).

- `scripts/lib/privacy-usage.sh` holds the two usage strings and the stamp and
  check functions; `build-app.sh` and `preview-app.sh` source it.
  `scripts/lib/codesign.sh` gained the entitlement key constant and
  `rubien_require_true_entitlement`, used by `build-app.sh` and
  `dev-launch.sh`, because the existing grep-based check also passes a key
  signed as false.
- Reviewed before commit: Codex (one minor finding, fixed: the check now
  requires a Boolean, not the string "true") and a three-angle simplify sweep
  (four small cleanups applied, one rename skipped).
- Verified on real bundles: `./scripts/preview-app.sh --no-launch` and
  `./scripts/build-app.sh debug` both pass. Both bundles carry both strings;
  the debug app is signed `adhoc,runtime` with `audio-input` true. The helper
  functions were also exercised on missing, empty, false, and absent cases.
- `dev-launch.sh` and a release build were not run.

Gate result. Tested with a stand-in app rather than Rubien itself: ad-hoc
signed with Hardened Runtime and the `audio-input` entitlement, spawning
children the way `SpawnedAgentProcess` does (`posix_spawn`, own process group,
no responsibility disclaim). The probe is a plain unsigned-identity tool with
no usage string or entitlement of its own; it records only frame count and
peak level.

| Child of the granted app | Sees permission | Captured real audio |
|---|---|---|
| Direct child | authorized | yes |
| Child already running before the grant | authorized | yes |
| Command run by Claude Code (`claude -p`, Bash tool) | authorized | yes |
| Command run by Codex, `workspace-write` sandbox | denied | not attempted |
| Command run by Codex, `danger-full-access` | authorized | yes |

Before the grant every child saw "not determined" (Codex's sandbox: "denied").
The system's permission log attributes every request to the parent app.

Reading for Rubien: once a user grants Rubien the microphone, any command
Claude Code runs can record without a further prompt. Codex commands are
blocked by Codex's own sandbox; Rubien only offers the read-only and
workspace-write modes (read-only was not tested, and the test used
`codex exec` rather than the app-server). Rubien's default approval mode asks
before each shell command; Auto mode does not.

Not covered: Rubien's real bundle, a Developer ID signature, and Rubien's
actual provider invocations. Repeat the Claude Code row in Rubien during the
Phase 5 manual check.

**Decision (2026-11-13): accept and document.** Capture stays in the main app.
Reasons: exposure needs a user who has used dictation, the Claude Code
provider, and an approved command or Auto mode; macOS shows its microphone
indicator during any recording; and agents already run with the user's file
access. A helper app with its own permission identity remains the hardening
path if this is revisited. Phase 7 documents the behavior for users.

### Phase 2 — Editor bridge, no audio

- `ComposerDictationBridge`, the range helper, the `shouldChangeTextIn`
  delegate, marked-text handling, undo grouping.
- Tests on a real `ComposerNSTextView`: insert at caret, replace selection,
  repeated volatile rewrites, typing or paste between updates freezes and the
  user's edit survives, external replacement freezes, marked text blocks
  start, emoji and CJK ranges, undo removes the dictated text as a unit.
- Integration test through the surface's reconciler: a mention before the
  insertion survives, one after it shifts, and send immediately after an
  update carries matching text and mentions.

### Phase 3 — Controller and contracts, no audio

- `DictationEngine`, `DictationUpdate`, `AudioSource`, authorizer protocol,
  `DictationController` with freeze/finish, generations, owner scoping,
  silence timeout with an injected clock.
- Tests with fakes: state transitions, each permission outcome, cancellation
  during a pending prompt or download, handoff before the previous engine has
  finished cleanup, late results dropped after freeze, finish deadline.

### Phase 4 — Capture and the legacy backend

- `MicrophoneCapture`, file-backed `AudioSource`, legacy accumulator,
  `LegacySpeechDictationEngine`.
- Deterministic accumulator tests: revised partials, final result, error,
  duplicate completion.
- Opt-in live test (environment-gated like `RUBIEN_LIVE_TESTS`): a short
  checked-in WAV through the production adapter via the file source.
- Tests never open the microphone; CI has no audio hardware and a permission
  prompt would hang the suite.

### Phase 5 — Button and surface integration (first end-to-end build)

- `ComposerDictationButton`, the control-row line, freeze hooks in
  `sendDraft`, surface deactivation, and app termination, mention-suggestion
  suppression, `ChatSidebarHarness` support.
- Manual check in a signed Hardened Runtime debug build and in the preview:
  prompts, live text, stop, ⌘↩ while listening, typing while listening,
  Chinese input method composition, a mention before dictated text resolving
  on send, denied-permission popover, reader and Home, two windows, closing a
  window while listening, unplugging the microphone, Siri and Dictation
  turned off.

### Phase 6 — Analyzer backends on macOS 26+

- Analyzer accumulator, `AnalyzerDictationEngine` for `SpeechTranscriber` and
  `DictationTranscriber`, backend selection, asset states, locale reservation.
- Uses only macOS 26 symbols; confirm on CI's SDK.
- Deterministic accumulator tests: multiple finalized segments, volatile
  revision, error, duplicate completion.
- Opt-in live WAV test through the production adapter; the test must finish
  the analyzer explicitly, because the file initializer does not by default.

### Phase 7 — Language setting, docs, release gate

- `RubienPreferences.assistantDictationLocale` with a `@State` mirror in
  `RubienSettingsView`; picker lists "System language" plus supported locales.
- README feature list and release notes text. State plainly that after
  microphone access is granted to Rubien, commands run by Claude Code can use
  the microphone too, that the default Ask approval mode gates each command,
  and that Auto mode does not. Mention the same in the Settings text next to
  the dictation language picker.
- `Docs/Release-Runbook.md`: for the first release containing this feature,
  a human dictation check on a signed Hardened Runtime build before the
  release command is approved, since `release.sh` publishes in the same run
  that signs. The 2 MiB DMG guardrail is unchanged.

Optional experiment, separate from completion: recognition hints from the open
paper. Limit to short phrases (author surnames, key terms; at most 100), and
only for `DictationTranscriber` and the legacy backend, where hints are
documented. Keep only if a before/after check shows a benefit.

## Still unverified

- Agent microphone inheritance inside Rubien's real bundle and provider
  invocations (confirmed with a stand-in app in Phase 1; repeat in Phase 5).
- Codex's read-only sandbox mode (only workspace-write was tested).
- Legacy on-device recognition with Siri and Dictation off, per macOS version.
- Whether on-device legacy sessions are subject to the documented one-minute
  limit.
- Permission continuity across a Sparkle update.
- Device removal, Bluetooth profile switching, and model download behavior in
  practice.
- Compilation against the CI SDK; only SDK 27.0 is installed locally.

## Other risks

- **Preview builds may re-prompt after each rebuild** because they are ad-hoc
  signed.
- **Bluetooth headsets** switch to the lower-quality call profile while the
  microphone is open.
- **Recognition quality** on technical vocabulary and mixed-language speech.
  The engine protocol leaves room for a Whisper backend later.

## Deferred

- Whisper as an optional downloadable engine (mixed-language dictation).
- A keyboard shortcut and push-to-talk.
- Quick language switch from the button's context menu.

## Changes from revision 1

- Draft edits moved from SwiftUI binding splices to an in-editor range-edit
  bridge with a synchronous foreign-edit hook, marked-text handling, and undo
  grouping (review findings 1–3). Undo is now preserved.
- Stop split into freeze and finish with a defined contract (4).
- Agent microphone inheritance became a decision gate in Phase 1 (5).
- Owner id plus per-start generation, revalidated after every await, with an
  explicit list of freeze triggers (6).
- Capture wrapper specifies format validation, the compatible tap overload,
  teardown outside the notification handler, bounded buffering, and the
  correct converter API (7).
- Backend selection checks `SpeechTranscriber.isAvailable` and adds
  `DictationTranscriber` before the legacy recognizer (8).
- Authorization decided per backend and injected for tests (9).
- Privacy strings stamped after either bundle assembly route, with assertions
  in unsigned builds too. Revision 1 wrongly said only a release build uses
  Hardened Runtime; every signed build does (10).
- Live tests run through the production adapter via an injectable audio
  source, plus deterministic accumulator tests (11).
- Old Phase 3 split into three commits, review decision asked per commit,
  release human check moved into the runbook before publication (12).
- Recognition hints reduced to an optional, bounded experiment (13).
