# Codex installer revalidation, 2026-11-01

Restore native Codex updates after the official bootstrap changed from the
October 24 reviewed script. Per the user's explicit choice, run the current
official updater without requiring an exact-script SHA-256 pin.

1. Inspect the full bootstrap diff. The candidate SHA-256 is
   `44ac252c1b9a68c02bdf0de8e1c6cbfde36fc1afa8684624962eae7d4c461e70`.
   Changes adjust macOS `lsof` handling, release-use path matching, and executable
   permissions/completeness checks for the new `codex-exec-server` helper.
2. Exercise the production update from 0.164.0 to 0.166.0 in a disposable home,
   retaining running 0.163.0 and 0.164.0 servers and their complete resources.
   Include a non-ASCII path and a process whose working directory is the oldest
   release root, then confirm cleanup after that process exits.
3. Remove the pinned hash and replacement-script rejection. Keep bounded HTTPS
   download validation, file identity/digest comparison before execution, and
   installation/policy/version checks. Journal the actual downloaded digest.
4. Replace the rejection regression with coverage for a changed official script
   executing successfully and an invalid download remaining blocked. Keep the
   live harness as an opt-in compatibility diagnostic without a production pin.
5. Update the provider design and action plan to reflect the current policy;
   build and run focused provider tests and the live update again.
6. Record evidence and request the optional independent review and simplify
   sweep before committing, as required by AGENTS.md.

No release preparation or changes to shared provider installations are included.

## Validation

- `swift build --disable-automatic-resolution` passed.
- Focused ProviderMaintenanceTests, ProviderSetupTests, ProviderUpdateTests, and
  ProviderUpdaterLiveTests passed: 79 tests, zero failures, three opt-in checks
  skipped. The native live check was subsequently run through the harness.
- `python3 scripts/validate-codex-installer.py` passed with the production update
  action: 0.164.0 → 0.166.0. Both older servers responded after cutover, all 42
  files in each older release retained identical hashes, and late helper launches
  succeeded. The selected package includes an executable `codex-exec-server`.
- The non-ASCII home and release-root working-directory checks passed. After all
  uses exited, cleanup pruned 0.163.0 and retained previous 0.164.0 and selected
  0.166.0 with identical resource hashes, selection history, and latest policy.
- The first fixture used an accented character with different composed/decomposed
  path bytes between Python and Foundation. Repeated installer runs then treated
  the same directory as a new selection and replaced selection history. The final
  fixture uses non-ASCII characters without a decomposed form so the test isolates
  escaped `lsof` output consistently across both drivers.
- Evidence: `build/ProviderUpdateValidation/live-codex-retention-測試-fqoj9ru6/result.json`.
  Logs: `/private/tmp/rubien-codex-revalidation-{build,tests,live}.log`.

## Final implementation

- Removed the production script allowlist and its compatibility error. The
  updater executes the complete current official bootstrap and journals that
  download's actual SHA-256 and source URL. Existing bounded HTTPS validation,
  pre-execution file checks, installation ownership/policy checks, locking, and
  installed-version verification remain.
- Updated tests to execute a newly downloaded fixture script through the real
  runner and verify the resulting installation and journal. Invalid downloads
  still fail before shell execution. The first-install live test now binds
  Codex execution to its prepared fixture rather than a production hash constant.
- Final build passed. Focused provider tests: 81 tests, zero failures, four
  opt-in checks skipped. The native opt-in check passed separately through the
  live harness after rebuilding the test bundle.
- Final unpinned production update passed all retention and cleanup checks:
  `build/ProviderUpdateValidation/live-codex-retention-測試-2l5pkd5d/result.json`.
  The actual updater digest in the production journal matches the diagnostic
  snapshot. Logs: `/private/tmp/rubien-codex-official-updater-{build,tests,live}.log`.
- No dependency or shared provider installation changes.

## Approved reviews

- The user approved the independent review and `/simplify` sweep. Independent,
  reuse, and efficiency reviews found no actionable issues.
- The quality review requested accepting a newer stable release in the opt-in
  live diagnostic, since it invokes the current latest updater. The harness now
  accepts stable versions at least as new as the requested target and records
  the actual version; the live test verifies the executable's reported version
  against the target and result message.
- Post-review build and focused tests passed: 81 tests, zero failures, four
  opt-in tests skipped. The native opt-in test passed separately through the
  real production updater: 0.164.0 → 0.166.0, with all retention, helper,
  non-ASCII path, working-directory, and cleanup checks passing.
- Final evidence:
  `build/ProviderUpdateValidation/live-codex-retention-測試-r784ocju/result.json`.
  Logs: `/private/tmp/rubien-codex-updater-reviewed-{build,tests,live}.log`.
