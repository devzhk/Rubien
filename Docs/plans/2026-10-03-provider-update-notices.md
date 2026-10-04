# Provider release checks and notices

## Goal

Finish the missing update-checking part of provider setup. Show the installed and published versions, check automatically while Rubien runs, and prompt users when a newer release is available.

The user clarified on 2026-10-03 that installation/sign-in alone does not satisfy the feature. Package installations must not silently miss release notices. This revises the design's earlier Phase 2 exclusion of package notices: a public release advisory may link to official update instructions, but must not imply that Rubien verified the user's registry, prefix, pins, or update eligibility.

## Scope

- Add strict semantic version comparison and bounded, read-only metadata requests to vendor/native, npm, and Homebrew publication sources.
- Keep discovery, version checks, and release checks independent of sign-in and the chat runtime. Never start an installer or terminate a chat during a check.
- Share automatic-check preferences, last results, retry deadlines, and seven-day Later suppression across Rubien builds, keyed by provider and selected installation.
- Start background checks after 30 seconds, check daily with jitter, and catch up once on activation. Manual checks bypass normal age but respect Retry-After.
- Add Settings controls and a compact in-app notice with Update instructions and Later. Preserve a previous result on network failure and label its age.
- Public latest-release comparisons are advisory. Native Claude Code and Codex installations also show advisory notices for fresh newer releases, as requested after testing 0.8.0. Channel/updater uncertainty limits update actions, not notice visibility. Pre-release, custom, missing, and broken installations must not produce a false up-to-date claim.
- One-click native updates still require updater retention tests; package mutations and automatic installation still require Phase 3 ownership/usage checks. This step executes no update command.

## Verification

1. Capture real metadata shapes without modifying either working provider.
2. Test numeric/prerelease ordering, malformed metadata, request limits/redirects/rate limits, overdue checks/backoff, opt-out, suppression, concurrent checks, stale results, and executable changes.
3. Build with pinned dependencies and the verified preview launcher.
4. Use the exact preview to verify the real Codex release notice, update instructions, and Settings controls. Preserve the user's CLI installations and login state.

## Status

Implemented in the working tree. No commit or release is part of this step.

- Added the release client/version parser, shared check state and locks, daily scheduler, Settings controls, and in-app package release notices.
- Captured public metadata in `build/ProviderUpdateValidation/`. The production URLSession client successfully checked all six endpoints: native and npm Codex 0.160.0; native and npm Claude 2.1.288; Homebrew Codex 0.160.0 and Claude 2.1.285. These values are validation evidence, not runtime constants.
- The first 14 focused tests passed, including the opt-in live metadata test. The final run passed 15 deterministic tests, with the live test skipped by default. This includes changing the selected executable and opting out while a request is running. Logs: `/private/tmp/rubien-release-check-live-tests.log` and `/private/tmp/rubien-release-check-final-tests.log`.
- Built Rubien and verified linked SDK 27.0 with minimum macOS 14.4. Pinned dependencies are unchanged.
- Visual replacement/check is pending: computer control reported the Mac locked. The running preview still has the earlier build until it can be closed and rebuilt through `scripts/preview-app.sh`.
- Native manual updates, native updater/channel verification, and package execution/auto-install remain unfinished. This change reports releases and offers update instructions; it runs no update command.
