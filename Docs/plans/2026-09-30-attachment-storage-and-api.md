# Attachment storage safety and CLI/MCP

Finish the local attachment foundation before enabling iCloud. Preserve the live
library, unrelated checkout changes, pinned dependencies, and local-only UI label.

## Steps

1. Protect library promotion with lifetime shared leases for open databases and
   exclusive source/destination leases for promotion. Keep lock files outside the
   copied tree, reject stale source reuse, retain the source on validation failure,
   and avoid opening an empty destination after a failed move. Test contention,
   interrupted copy, concurrent destination ownership, and successful restart.
2. Keep PDF/Markdown import limits in Core. Exercise boundary imports and measure
   validation/reader costs with generated temporary fixtures; document the results.
3. Add `attachment list/add/status/read/export/rename/remove` through the same Core
   store. Return explicit local-only status and per-input batch results. Bound reads
   and preserve original bytes on export. Cover errors and JSON contracts.
4. Add matching native and npm MCP tools, approval classifications, schema/argument
   tests, and documentation. Build/test focused Mac targets and npm; check Linux
   parity with the available local toolchain/container.

Attachment receive journals and acknowledgement-aware cleanup remain in the iCloud
phase because their ownership rules depend on sync acknowledgement. No release,
commit, live-library migration, or production CloudKit changes in this step.

## Implemented

- Open databases hold shared root leases; promotion claims both roots exclusively
  and holds SQLite exclusive ownership through copy, verification, and publication.
  Lock files remain outside the copied tree. A source marker written before SQLite
  publication prevents stale source reuse and allows retry to the recorded destination.
  Copy/integrity failures retain the source and stop startup before an empty library opens.
- Attachment file operations participate in root leases. Export protects the new
  internal files. Confirmed replacement uses same-directory POSIX rename, fixing a
  Foundation replacement failure found by the Linux tests.
- Added all seven attachment commands and matching native/npm tools, shared write
  approval policy, explicit local-only status, per-input batch results, bounded reads,
  export protection, JSON schemas, and CLI/MCP documentation.
- The Core size preflight rejects oversized files before journal creation; streaming
  copy/hash checks still enforce the limit if the source grows after preflight.

## Byte-limit measurement

On the development Mac, generated temporary fixtures at the exact limits passed
import and text reading. Files one byte above each limit were rejected. Timing
includes CLI startup; peak RSS is from `/usr/bin/time -l`.

| Fixture | Import | Read | Import peak RSS | Read peak RSS | Oversize rejection |
|---|---:|---:|---:|---:|---:|
| PDF, 250 MiB | 0.901 s | 0.669 s | 387.5 MiB | 278 MiB | 0.054 s |
| Markdown, 50 MiB | 0.217 s | 0.168 s | 221.3 MiB | 168.6 MiB | 0.049 s |

The PDF has a simple text page and a large unused stream; Markdown is repeated plain
text. These measurements cover import, verification, and bounded extraction. They
do not establish worst-case rendering time for complex PDFs or large Markdown DOMs.
The limits are local product limits, not claims about CloudKit asset capacity.

## Verification

- Mac: app and CLI builds passed; 38 Core storage/policy tests and 43 CLI/native
  MCP tests passed.
- Linux: Swift 6.3.2 on Ubuntu 22.04 built the CLI and passed 78 focused Core,
  CLI, and native MCP tests, including replacement exports and interrupted promotion.
- npm: TypeScript build and all 101 tests passed, including native/npm schema,
  approval, and attachment operation parity.
- `git diff --check` passed. Pinned dependencies are unchanged. Tests and byte-limit
  measurements used temporary libraries; the live library and installed app were untouched.
- Final preview refresh is pending: the Mac locked before the old preview could
  be quit. Verified products are `.xcodebuild/Build/Products/Debug/Rubien` and
  `.build/debug/rubien-cli`; copy both into the isolated preview after quitting it.
