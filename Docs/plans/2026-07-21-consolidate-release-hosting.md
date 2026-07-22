# Consolidate Release Hosting in `devzhk/Rubien`

## Goal

Make the now-public source repository the canonical home for Rubien releases,
without stranding Linux CLI installations that were shipped with a hard-coded
`devzhk/Rubien-releases` update endpoint.

## Release topology

- `devzhk/Rubien` hosts source, tags, release notes, the DMG, Chrome extension,
  and signed Linux CLI artifacts.
- The Sparkle feed remains at
  `https://devzhk.github.io/Rubien/appcast.xml`; existing app installations do
  not need a feed migration.
- Historical appcast entries continue to point at `devzhk/Rubien-releases`.
  Those signed artifacts stay valid and do not need to be copied.
- Version 0.6.3 is a one-time compatibility bridge. Its canonical release is
  created in `devzhk/Rubien`, while the Linux workflow creates a release with
  the same tag in `devzhk/Rubien-releases` containing only the signed Linux CLI
  archive and signature needed by shipped updaters.
- The 0.6.3 Linux CLI changes its update endpoint to `devzhk/Rubien`, so all
  later releases are published only in the source repository.

## Implementation

1. Backfill the already-published 0.6.2 release into `devzhk/Rubien`, reusing
   its source tag and byte-identical signed assets, before changing public
   `releases/latest` links. This prevents a temporary fallback to the old
   v0.1.3 source-repository release.
2. Point `scripts/release.sh` and the generated Sparkle enclosure URL at
   `devzhk/Rubien`.
3. Upload Linux artifacts to the source repository with `GITHUB_TOKEN`; for
   tag `v0.6.3`, also upload them to the legacy release using the existing
   cross-repository token.
4. Move CLI self-update discovery, public download links, MCP package metadata,
   and operational documentation to `devzhk/Rubien`.
5. Leave historical design documents and existing appcast enclosure URLs
   unchanged because they describe or reference already-published artifacts.
6. After the canonical release exists, update the GitHub repository homepage
   from the legacy releases repository to the Rubien Pages/project URL.

## Optional cleanup after 0.6.3

Delete the obsolete v0.1.0–v0.1.3 GitHub release entries from the source
repository after the migration is complete. Preserve their git tags and every
asset in `devzhk/Rubien-releases`, because historical Sparkle entries still use
the legacy URLs. This cleanup is intentionally outside the critical release
path.

## Verification

- Shell syntax-check the release scripts.
- Run the CLI self-update tests and version tests.
- Build and test the MCP server. Its checked-in 0.3.3 version is not yet
  occupied on npm, so the existing pending version remains valid.
- Run the normal Swift test suite and exact-SHA CI gate.
- Rebuild and statically verify the unsigned 0.6.3 candidate before requesting
  publication approval.
