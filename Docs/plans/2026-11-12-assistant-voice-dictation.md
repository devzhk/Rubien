# Assistant voice dictation

Add a microphone button to the Assistant composer that transcribes speech into
the draft, on-device, using Apple's Speech framework. No bundled model and no
new package dependency.

Revision 2 (2026-11-12). Revised after an independent Codex review
(`gpt-6.1-sol`, high effort; raw output in
`/tmp/rubien-voice-dictation-plan-review-2026-11-12.md`). The review's 13
findings were checked against the code and SDK headers and all are adopted;
see "Changes from revision 1" at the end.

## Status (2026-11-13)

Implemented on the branch `assistant-voice-dictation` and fast-forwarded into
local `main` on 2026-11-13. Not pushed and not released. The status
subsections under each phase below have the detail; this is the summary.

Works, verified by driving the real UI in the preview app with recorded audio
(`DictationSelfTest`, see "Orchestrator review and end-to-end check of
Phase 5"): the button in the reader sidebar surface and in Agent Home, live
text, Stop, undo and redo, typing while listening, Command-Return while
listening, hand-off between two windows, the failure popover, a first-time
model download, and Chinese as well as English. Unit tests cover the editor
bridge, the controller, the transcript accumulator, the audio sources, and the
mention handling; opt-in live tests run the real recognizer on a checked-in
recording. A Release configuration compiles and contains none of the
debug-only test hooks.

The real microphone works too. With microphone access granted to the preview
app, the self-test started dictation with a real click, played the checked-in
recording through the Mac's speakers, and the microphone path transcribed it
as "Compare the attention mechanism with recurrent networks." Stop, undo, and
redo passed on that text. That exercised `MicrophoneCapture`, the system
authorizer, and the permission prompt for the first time.

Not verified, in order of importance:

1. **Device changes during capture** (plugging in or switching a headset,
   Bluetooth profile switches). The recovery code follows the AVFAudio headers
   and is guarded against exceptions, but has never run.
2. **A Developer ID signed, Hardened Runtime build.** The release runbook now
   has a microphone gate for this; the provisioning profile's acceptance of
   the `audio-input` entitlement is only settled there.
3. The Settings picker on screen, real reader windows (the harness uses the
   same surface), and agent microphone inheritance in Rubien's own bundle
   (confirmed with a stand-in app in Phase 1).

Scope decisions taken along the way: macOS 26 or later only (the
`SFSpeechRecognizer` backend is deferred because it could not be verified
here); moving the caret does not end dictation, only a text change does; text
dictated between straight double quotes gains inner spaces (cosmetic, left
as is).

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

#### Phase 2 status (2026-11-13)

Implemented in `Sources/Rubien/Assistant/Dictation/ComposerDictationBridge.swift`
(the bridge plus the pure `DictationInsertion` rules), with hooks in
`ComposerTextView.swift`. Nothing calls the bridge yet; `ComposerTextView`
takes it as an optional parameter that defaults to nil.

Decisions made while building it:

- **A caret the user moves is left alone.** Moving the caret does not end
  dictation; only a text change does. The caret follows the dictated text
  while it sits at its end, and otherwise stays on the same character.
- **Spacing.** A space is added on either side only where words would run
  together. None is added beside whitespace, closing or opening punctuation,
  or Han, kana, and full-width characters.
- **Undo is owned by the bridge.** One action is registered with the first
  edit and reads the session's final range when it runs; undo and redo then
  register each other. The text view's automatic registration is switched off
  while a dictation edit is validated, because its inverse of a programmatic
  replacement raised a range exception on redo (caught by the tests). A
  session that ends with no net change withdraws its undo action.
- **The hook lives on the text view.** `ComposerNSTextView` overrides the
  multiple-range `shouldChangeText` and `setMarkedText`, and links itself to
  the bridge through a property observer. No delegate method was added.
- **External draft writes** moved into `Coordinator.syncExternalText`, which
  ends a session before replacing the text. Behavior is otherwise unchanged.
- **Interruptions carry no reason.** Every interruption is handled the same
  way, so `onInterruption` takes no argument.

Reviewed before commit. Codex (raw output in
`/tmp/rubien-voice-dictation-phase2-review-2026-11-13.md`) found two majors
and three minors, all fixed except one:

- Own-edit suppression now covers only the validation call, so an edit made
  while a dictation edit is being announced still interrupts and keeps its own
  undo step.
- Dictation at the end of a completed `@paper` mention could run Han
  characters into the title and silently drop the mention. `begin` takes
  `separatingFromPrecedingText`, which forces a space in any script.
- Moving a bridge to another editor now unlinks the first.
- A no-change session no longer leaves an empty undo step.
- Not fixed: text dictated between straight double quotes gains inner spaces.
  Telling an opening quote from a closing one needs more context than the
  neighbor characters, and the result is cosmetic.

The simplify sweep's cleanups were applied: a shared validate/apply pair for
dictation edits and undo swaps, the storage's own string instead of a full
copy per partial result, and tests that build the editor through
`ComposerTextView.makeTextView()`.

Carried into Phase 5:

- Pass `separatingFromPrecedingText: true` when the caret sits at the end of
  a selected mention.
- The surface reconciles mentions in a deferred `.onChange(of: draft)`. Send
  must not snapshot mentions that have not yet been reconciled against the
  latest dictated text; reconcile first, or the send-time check silently drops
  the mention.
- Check by hand, because tests cannot cover them: automatic spelling
  correction and text substitution (they arrive as text changes and would end
  a session), a real input method's composition sequence, paste, drag and
  drop of text, Services, and Writing Tools.

### Phase 3 — Controller and contracts, no audio

- `DictationEngine`, authorizer protocol, `DictationController` with
  freeze/finish, session identity as the generation, owner scoping, silence
  timeout with injected time.
- Tests with fakes: state transitions, each permission outcome, cancellation
  during a pending prompt or download, handoff before the previous engine has
  finished cleanup, late results dropped after freeze, finish deadline.

#### Phase 3 status (2026-11-13)

Implemented in `DictationEngine.swift` and `DictationController.swift` with 23
tests against fake engines, a fake authorizer, and manually fired sleeps.
Differences from the sketch above:

- The engine stream carries the whole transcript as a `String`; the controller
  has no use for a separate finalized/volatile split.
- A session object doubles as its own generation: asynchronous work continues
  only while its session is still the current one.
- The audio-source protocol moved to Phase 4, where it is first used.
- The editor is claimed before the microphone opens, so a composer that cannot
  take text never starts a recording.

#### Scope change (2026-11-13): macOS 26 or later for the first version

The developer handed over ownership of the feature at this point, with the
instruction to finish and verify it end to end without further check-ins.

The `SFSpeechRecognizer` backend is deferred, so dictation needs macOS 26.
On older systems the button is not shown. Reasons:

- It cannot be verified here. This Mac runs macOS 27, where the analyzer
  engines always win, and the older recognizer's behavior differs by OS
  version (how partial results restart after a pause, the Siri/Dictation
  dependency, the one-minute limit).
- Testing it at all needs a speech-recognition permission prompt, and its
  failure mode is duplicated or lost text in a user's draft.
- The engine protocol and factory leave a clean slot for it once it can be
  tested on macOS 14 or 15.

The speech-recognition usage string from Phase 1 stays in the bundle, unused
for now. Old Phases 4 and 6 merge into the new Phase 4; old Phase 7 becomes
Phase 6.

### Phase 4 — Capture and the analyzer engines

- `DictationAudioSource` with `MicrophoneCapture` and a file-backed source.
- `AnalyzerDictationEngine` for `SpeechTranscriber` and `DictationTranscriber`,
  engine selection, model download, the system authorizer.
- A pure accumulator that turns time-ranged analyzer results into a transcript,
  with deterministic tests: multiple finalized segments, volatile revision,
  out-of-order and duplicate results.
- Uses only macOS 26 symbols. Type-check against the macOS 26.5 SDK that the
  Command Line Tools install, which is what CI compiles with.
- Opt-in live test (environment-gated like `RUBIEN_LIVE_TESTS`): a short
  checked-in WAV through the production engine via the file source. The test
  must finish the analyzer explicitly.
- Tests never open the microphone; CI has no audio hardware and a permission
  prompt would hang the suite.

#### Phase 4 status (2026-11-13)

Implemented in `DictationAudioSource.swift` (the protocol and
`FileDictationAudioSource`), `MicrophoneCapture.swift`,
`AnalyzerTranscriptAccumulator.swift`, `AnalyzerDictationEngine.swift` (with
`AnalyzerAudioConverter`), `SystemDictationAuthorizer.swift`, and
`DictationEngines.swift`. Nothing in the UI uses them yet.

Decisions and findings:

- **`SpeechTranscriber` needs `fastResults`.** With `volatileResults` alone it
  held every result until the speaker paused: a paced test got no text at all
  while speech was still arriving, and a probe with trailing silence got the
  whole sentence in one burst after the pause. With `fastResults`, partial
  text arrives about once a second while speaking. `DictationTranscriber`
  streams with `volatileResults` alone.
- **Sources start synchronously** on the main actor and are used once. The
  configuration-change handler only ends the stream with `noMicrophone`; no
  new failure case was added.
- **The transcript stream keeps only the newest element**, since each element
  is the whole transcript. A finished stream still hands out what it had
  queued, so at most one transcript can arrive after `cancel`; the controller
  already drops it.
- **The accumulator follows Apple's sample**: final text appends, volatile
  text replaces the tail. Time ranges are not used, so out-of-order or
  duplicate results (listed above) are not handled; none were seen.
- **`prepare` also loads the model**: it reserves the locale, installs assets,
  asks for the audio format, then creates the analyzer and calls
  `prepareToAnalyze`.
- **Locale reservations.** If the locale is not reserved and all
  `maximumReservedLocales` slots are taken, the first reserved locale is
  released before reserving. Rubien dictates in one language at a time, so
  other reservations are left over from earlier settings.

Verified: deterministic tests for the accumulator, the file source, buffer
copying, and converter resampling (48 kHz stereo to 16 kHz mono with no lost
frames). Opt-in live tests (`RUBIEN_DICTATION_LIVE_TESTS=1`) ran on this Mac
with both transcribers on the checked-in fixture, and passed three times in a
row. Both transcribers produce the sentence; `DictationTranscriber` adds no
punctuation to the synthetic voice. Partial text arrives while the paced file
is still playing, and the stream ends well under a millisecond after `cancel`.
The new files compile with no diagnostics against the macOS 26.5 SDK in the
Command Line Tools. That check used `swift build --build-system native --sdk`
because the default build system ignored both `SDKROOT` and `--sdk`. The
product link did not finish: the `#Preview` macro plugin is missing with that
SDK (`AssistantRendererHarness.swift`).

Not verified: `MicrophoneCapture` and `SystemDictationAuthorizer` at run time
(left for the Phase 5 manual check), the model download and its progress (the
en_US model was already installed), release of a reserved locale, device
change during capture, and the test files against the 26.5 SDK. The live tests
reserve en_US for the test runner's identity.

Orchestrator review of Phase 4 (2026-11-13). The implementation was written by
an Opus implementer subagent, then read in full and re-run by the owning
session:

- Re-ran the unit tests (70 pass) and the live tests (4 pass). The engine
  files type-check with no diagnostics against the macOS 26.5 SDK directly
  (`swiftc -typecheck -sdk …/MacOSX26.5.sdk` on the seven engine files).
- Added a live test of the whole chain short of the UI: the controller picks
  and drives the real engine, and the fixture lands in a composer editor as
  "Note: Compare the attention mechanism with recurrent networks."
- Changed `MicrophoneCapture` to resume after a configuration change instead
  of ending the session: it reinstalls the tap on the new format and restarts
  the engine, at most three times, then fails with `noMicrophone`. A Bluetooth
  headset switching to its call profile as recording begins raises this
  notification, so ending on it would have made dictation unusable there. The
  hand-off leaves the notification handler before touching the engine. This
  path could not be exercised here and is still unverified.

Follow-up fixes to the Phase 3 controller, from one last Codex pass (raw
output in `/tmp/rubien-voice-dictation-phase3-review-2026-11-13.md`; reviews
after this point are done by the owning session or an Opus reviewer):

- The progress callback captured its session strongly, forming a cycle with
  an engine that keeps the callback. It is weak now and the session drops its
  engine when it ends; a test asserts the engine is released.
- A session ended from an editor callback while the editor was being claimed
  now gives the claim back instead of leaving it open.
- Timers check for cancellation after their sleep completes.
- Only a changed transcript postpones the silence timeout.
- The silence test now proves the timer is replaced by new words and left
  alone by repeated ones. Added cases: the engine completing by itself, a
  same-surface restart while preparing, and an engine that keeps sending after
  being cancelled.

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

#### Phase 5 status (2026-11-13)

Implemented by an Opus implementer subagent. The language setting and its
Settings text, listed under Phase 6 below, were moved into this phase; the
README, release notes, and runbook items stay in Phase 6.

- `SharedDictation.swift`: `DictationController.shared`, with the system
  authorizer and the microphone engine factory. Debug builds only: when
  `RUBIEN_DICTATION_AUDIO_FILE` names a file, the shared controller plays it
  through `FileDictationAudioSource(paced: true)` instead, so the real composer
  can be dictated into with no microphone and no permission prompt. Also
  `DictationLanguage` (the start locale and the Settings picker rows).
- `ComposerDictationButton.swift`: the button, absent below macOS 26. Idle
  starts; any other state calls `finish`. Glyphs: `mic`; a small spinner, or a
  determinate ring while a model downloads; accent `mic.fill` with a pulse
  (skipped under Reduce Motion) and a faint accent fill while listening; the
  same, dimmed and still, while finishing. 27 × 27 points with the "+" menu's
  corners and hover fill. Accessibility identifier
  `composer-dictation-button`. A failure popover above the button, with an
  "Open System Settings" button for the two permission failures. The failure
  text is `DictationFailure.title`, `message`, and `settingsURL`.
- `ChatSurfaceView`: one owner and one bridge per surface; the button sits
  before the send controls; starting requests editor focus. Freezes at the top
  of `sendDraft`, in `onDisappear`, and when `isActive` turns false.
  `applicationShouldTerminate` freezes first. Mention suggestions are
  dismissed and not opened while this surface's dictation is not idle.
- Send-time mentions. The surface now records the exact draft its mentions
  were last reconciled against (`mentionsReconciledDraft`, set by `onChange`,
  mention completion, and `resetDraft`). `sendDraft`, after freezing, and
  `completeMention` first apply any edit `onChange` has not handled yet
  (`PaperMentions.updating`). `onChange` reconciles from that recorded draft
  rather than its own `old` value, so an edit already applied is not applied
  again; the `reconciledDraft` guard still skips a completion's own change and
  is now cleared by the first `onChange` after it.
- A caret exactly at the end of a selected mention starts dictation with
  `separatingFromPrecedingText` (`PaperMentions.caretEndsMention`).
- `RubienPreferences.assistantDictationLocaleIdentifier` (BCP-47, nil for the
  system language), read at every start. `DictationEngines.supportedLocales()`
  unions both transcribers' locales on macOS 26. Settings → Assistant →
  Dictation has the picker and the on-device and agent-microphone disclosure.

Not changed: `ChatSidebarHarness` needed nothing, since it renders
`ChatSidebarView` and so gets the button and the debug audio-file override.

Verified by the implementer: build with no new warnings, unit tests for the
failure text, the language helpers, and the mention helpers, the dictation and
composer suites, the app suite, the opt-in live tests, and the macOS 26.5 SDK
type-check of the engine files. Not verified: anything in the running app (the
button, its states and popover, live text, freeze on send or window close,
mention suppression, the Settings picker), and every manual check listed
above.

Orchestrator review and end-to-end check of Phase 5 (2026-11-13). The diff was
read in full, and the running app was driven by `DictationSelfTest`
(`Sources/Rubien/Assistant/Dictation/DictationSelfTest.swift`, debug builds
only). Launching a debug build with `RUBIEN_DICTATION_SELFTEST=<directory>`
opens the Assistant Sidebar Harness, clicks the dictation button with real
mouse events at the position the button reports, and writes `report.json`
plus window snapshots. With `RUBIEN_DICTATION_AUDIO_FILE` set it dictates that
recording and needs no permission. To repeat it:

```bash
./scripts/preview-app.sh --no-launch
open --env RUBIEN_LIBRARY_ROOT="$PWD/build/ProviderSetupPreview/Library" \
     --env RUBIEN_DICTATION_SELFTEST=/tmp/rubien-dictation-selftest \
     --env RUBIEN_DICTATION_AUDIO_FILE="$PWD/Tests/RubienTests/Fixtures/dictation-attention.wav" \
     --env RUBIEN_DICTATION_SELFTEST_EXPECT="compare,attention,mechanism,recurrent,networks" \
     "build/ProviderSetupPreview/Rubien Setup Preview.app"
```

Result in the preview app, with the recorded fixture: all 14 checks passed.

- A real click starts dictation; listening is reached about a third of a
  second later, and text streams into the composer while listening.
- Stop returns to idle with "Compare the attention mechanism with recurrent
  networks." in the draft. One undo removes it and redo restores it.
- Typing while listening ends dictation at once, keeps the typed character,
  and nothing more is dictated.
- Command-Return while listening sends exactly the visible text, clears the
  draft, and nothing is dictated into the empty draft afterwards.
- The snapshots show the idle, listening, and after-send states laid out
  correctly at the sidebar's minimum width.

Two things learned while building the driver, recorded so they are not
rediscovered: SwiftUI does not build its accessibility tree for an in-process
query, so a button cannot be found or pressed that way; and a view's `.global`
frame is measured from the top-left of the window including the title bar. A
recording stops supplying audio at its end, so the recognizer holds the last
words until Stop; a microphone keeps supplying silence.

Changed in review: the Settings disclosure no longer says the Ask mode asks
before each command, because agent rules can allow a command without asking.
It now says that Approvals decide whether Rubien asks before a command runs.

Not yet verified by anyone: the failure popover, the Settings picker on
screen, Agent Home's composer, two windows at once, a model download, and the
real microphone.

One unrelated test, `CodexProviderTests/testHistoryTimeoutResetsTheServerAndRetrySucceeds`,
failed once in a full app-suite run and passed three times alone. It is
timing-sensitive and predates this work.

Second end-to-end round (2026-11-13), after extending the self-test to drive
two windows, a forced failure, and a second language. It found two bugs that
no unit test had:

- **Dictation in Agent Home stopped after the first words.** SwiftUI re-rendered
  the editor once with the draft from before the edit it had just published,
  then again with the new one. The editor took the stale value for an outside
  replacement, reverted the text, and ended the session. It shows in Agent
  Home because that draft is owned several views up, in the main window's root
  view; the reader sidebar's draft sits next to the editor. Reading the draft
  back to tell an echo from a real outside write did not work either: it
  returned the same stale value. `ComposerTextView.Coordinator` now remembers
  the texts it replaced with its own edits until a render confirms the
  current one. A render showing one of those is ignored unless nothing
  confirms the editor's text within half a second, in which case it is applied
  as an outside write after all. This also protects ordinary typing.
- **The failure popover opened empty.** Its content was built at presentation
  time from state that had not been recorded yet. It now reads the live
  failure.

The self-test's results after the fixes, in the preview app:

- English recording: 22 checks pass, including a hand-off from the harness
  window to Agent Home, where the whole sentence is dictated and the button
  draws the listening state.
- Forced failure (an unsupported language in the preference): the popover is
  on screen with "Language not available" and its explanation.
- Chinese (`zh-CN` preference, a recording made with the Tingting voice): 22
  checks pass with "请比较注意力机制和循环神经网络。". The first run downloaded the
  speech model, showed the progress ring, and continued to listening. A
  recording made with the Flo voice was transcribed with wrong opening words,
  which is recognition quality on that synthetic voice, not the pipeline.

Still not verified: the real microphone, the Settings picker on screen, the
reader windows themselves (the harness uses the same surface), and a device
change during capture.

#### Review fix batch (2026-11-13)

An independent review of the branch found these, now fixed:

- **Device changes.** `MicrophoneCapture` observes configuration changes before
  the engine starts, so a Bluetooth headset switching profile during start is
  handled once the start returns. Each resume builds a fresh `AVAudioEngine`
  (the old one is torn down on the main actor), because the old input node can
  keep its old format. Tap installation and start are wrapped in
  `ExceptionCatcher`, so an Objective-C exception becomes "No microphone"
  instead of a crash. A notification from an engine already replaced is
  ignored, and the restart limit counts only restarts within five seconds of
  each other.
- **Stale renders.** A repeated sighting of the same unconfirmed draft no
  longer postpones its deadline, so an outside write during streaming still
  lands within half a second. An edit made after the draft was seen cancels
  applying it. A programmatic replacement (send clearing the draft) now
  remembers the replaced text, so a stale render cannot bring the sent text
  back. A render ignored as stale no longer moves the selection.
- **Publishing during view updates.** An outside replacement and the editor
  going away end the bridge session at once but report the interruption on
  the next main-queue turn, to the receiver installed at that moment. Typing,
  paste, undo, and input-method changes still report synchronously.
- **Send.** The editor's text, not the draft binding, is what is checked,
  reconciled, and sent, since the binding can lag by an edit in Agent Home.
  The fresh-Home clearing checks compare the editor's text too. Command-Return
  with nothing to send no longer stops dictation.
- **Conversation changes.** New conversation, History resume (both surfaces),
  and opening a scheduled run freeze dictation explicitly.
- **Mention separation** is decided when the editor is claimed, after any
  permission prompt or model download, not when Start is clicked.
- **The "can't dictate here" message** now fits every cause, not only an
  input method composing.

Still not verified: a real device change during capture (the restart path has
only been compiled and reasoned against the AVFAudio headers), and none of
these fixes has been exercised in the running app.

Keyboard shortcut (2026-11-13, added after the merge at the developer's
request). ⌘D starts and stops dictation, the same action as the button.

- It is handled in `ComposerNSTextView.performKeyEquivalent`, which the window
  sweeps for key equivalents, so it works from anywhere in the window (while
  reading the PDF, say), not only with the caret in the composer. Starting
  moves focus to the composer.
- The surface declines when it is mounted but not showing (Agent Home behind
  the library), so the key falls through there.
- The key is matched by character, not key code, so it follows the keyboard
  layout. No existing Rubien shortcut used ⌘D.
- `DictationController.toggle` is the one action behind both the button and
  the shortcut. The button's tooltip and the composer's empty-state hints
  show the shortcut.
- Verified by unit tests for the key matching and the toggle, and by a
  self-test scenario that presses ⌘D in the real window without composer
  focus (start, focus moves to the composer, stop, and a plain "d" is ignored).

### Phase 6 — Language setting, docs, release gate

- (Done in Phase 5.) `RubienPreferences.assistantDictationLocaleIdentifier`
  with a `@State` mirror in `RubienSettingsView`; picker lists "System
  language" plus supported locales.
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
only for `DictationTranscriber`, where hints are documented. Keep only if a
before/after check shows a benefit.

## Still unverified

- Agent microphone inheritance inside Rubien's real bundle and provider
  invocations (confirmed with a stand-in app in Phase 1; repeat in Phase 5).
- Codex's read-only sandbox mode (only workspace-write was tested).
- Permission continuity across a Sparkle update.
- Device removal, Bluetooth profile switching, and model download behavior in
  practice.

## Other risks

- **Preview builds may re-prompt after each rebuild** because they are ad-hoc
  signed.
- **Bluetooth headsets** switch to the lower-quality call profile while the
  microphone is open.
- **Recognition quality** on technical vocabulary and mixed-language speech.
  The engine protocol leaves room for a Whisper backend later.

## Deferred

- An `SFSpeechRecognizer` backend for macOS 14.4 through 15 (see the scope
  change under Phase 3).
- Whisper as an optional downloadable engine (mixed-language dictation).
- Push-to-talk (hold a key to dictate).
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
