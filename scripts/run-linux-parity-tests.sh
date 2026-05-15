#!/usr/bin/env bash
#
# Run RubienPDFKitTests.BackendParityTests on Linux with per-test process
# isolation. Each test is invoked in a fresh `swift test --filter` process.
#
# Why: swift-corelibs-xctest on Linux runs all tests in one process, and the
# global state of libdispatch + the threaded C libraries we link against
# (poppler-glib, cairo, gdk-pixbuf) leaves GCD's worker threads in an
# intermittent stuck state between test methods. The hang manifests as the
# xctest process sitting on do_sys_poll / do_epoll_wait waiting for the next
# test invocation that never arrives. Repro rate ~40% on x86_64 ubuntu-22.04
# and arm64 swift:6.3-jammy. Stable per-test invocation has 0 flakes.
#
# Mac doesn't need this: Xcode's XCTest runs all tests cleanly in one
# process. On Mac, just `swift test --filter RubienPDFKitTests` works.

set -euo pipefail

# Discover test method names from the bundle. Hard-code as a fallback if the
# bundle isn't built yet; both lists must stay in sync with
# Tests/RubienPDFKitTests/BackendParityTests.swift.
TESTS=(
  testExtractedTextOnLinearFixture
  testExtractedTextOnScanFixtureIsEmpty
  testOpenEncryptedThrowsLocked
  testOpenLinearFixture
  testOpenMissingFileThrowsCannotOpen
  testOutlineRootNilWhenNoOutline
  testOutlineRootStructureMatchesGeneratorContract
  testPageBoundsMatchUsLetter
  testRenderJPEGDropsThroughQualityLadderUnderTightBudget
  testRenderJPEGProducesValidImageAtTopQuality
  testRenderPNGProducesValidImage
  testRenderPNGThrowsMaxBytesExceeded
)

# Build once so per-test invocations are incremental.
swift build --build-tests >/dev/null

failed=0
for t in "${TESTS[@]}"; do
  printf "%-60s " "$t"
  if out=$(swift test --filter "RubienPDFKitTests.BackendParityTests/$t" 2>&1); then
    echo "PASS"
  else
    echo "FAIL"
    echo "--- output ---"
    echo "$out" | tail -20
    echo "--- end output ---"
    failed=$((failed + 1))
  fi
done

if [ $failed -gt 0 ]; then
  echo
  echo "$failed test(s) failed"
  exit 1
fi
echo
echo "all ${#TESTS[@]} parity tests passed"
