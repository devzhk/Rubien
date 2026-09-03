# Chrome Web Store distribution

## Goal

Publish the Rubien Importer through the Chrome Web Store without breaking
existing unpacked installations, while keeping the browser extension and native
host coupled to the matching Rubien release.

## Changes

1. Treat the Web Store ID as the primary extension identity and temporarily
   allow the legacy unpacked ID in both native-host registration and caller
   validation.
2. Make the checked-in manifest key derive the Web Store ID so development and
   unpacked release installs exercise the production identity.
3. Produce two verified archives: the existing GitHub/manual-install ZIP and a
   root-manifest Web Store ZIP with the forbidden `key` field removed.
4. Lock the identity and packaging contracts down with Swift and Node tests.
5. Document the Web Store submission boundary in the release runbook. Store
   submission and publication remain explicit, external release actions.

## Verification

- Run the browser-extension Node tests.
- Run focused RubienCore, RubienBrowserHost, and Rubien app tests.
- Package the extension and inspect both ZIP layouts and manifests.
- Build all targets, then review the resulting diff before merging.
