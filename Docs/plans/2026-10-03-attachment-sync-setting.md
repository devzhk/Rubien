# Attachment sync setting

Expose the existing experimental attachment sync implementation in Settings →
iCloud Sync. Keep it opt-in and require a restart when the saved choice changes,
so an engine never changes transfer policy halfway through an operation.

- Persist the choice per app installation; explicit user choices take precedence
  over the legacy developer environment flag.
- Capture the effective choice once at coordinator creation and inject that
  immutable value into each SyncedLibrary for this app session.
- Show the saved choice, restart requirement, requirement to enable library sync,
  and instructions to enable this on both Macs. Turning off preserves files.
- Test default, persistence, explicit opt-out, environment fallback, and session
  snapshot behavior without CloudKit or real preferences.
- Build and run focused tests, then prepare a signed Production candidate for
  user verification. The user subsequently requested publication in 0.8.3 (build 54).

## Verification

- All 37 SyncCoordinatorTests passed, including default, saved choice, legacy
  environment precedence, and immutable session policy tests.
- Signed Production-entitled candidate built successfully; SDK 27.0 and minimum
  macOS 14.4 verified. Published 0.8.2 remains unchanged.
- Live Settings verification: toggle on shows restart reminder; reverting off
  removes it. Candidate left open in iCloud Sync with attachment opt-in off.
- Two-Mac transfers remain a user verification step.
