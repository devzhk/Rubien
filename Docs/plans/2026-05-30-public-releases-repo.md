# Public Releases Repo (Sparkle auto-update fix for a private source repo) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Sparkle auto-update — currently broken because release-asset DMGs in the **private** `devzhk/Rubien` repo return **404 for anonymous downloads** — by hosting DMGs in a new **public** `devzhk/Rubien-releases` repo, while keeping the appcast and `SUFeedURL` exactly where they are so **existing v0.1.2/v0.1.3 installs self-heal without a new build**.

**Architecture:** The appcast stays at `https://devzhk.github.io/Rubien/appcast.xml` (served by the private repo's existing Pages workflow). Only the `<enclosure url="…">` values move from `github.com/devzhk/Rubien/releases/…` to `github.com/devzhk/Rubien-releases/releases/…`. EdDSA signatures and `length` are computed over DMG *content*, not the URL, so re-hosting the identical bytes leaves them valid — we change one attribute per item. `scripts/release.sh` is then rewired so future releases push the DMG to the public repo (and still tag the private source commit).

**Tech stack:** GitHub Releases + `gh` CLI, GitHub Pages (Actions `deploy-pages`), Sparkle 2 appcast, bash release pipeline, EdDSA `sign_update`.

---

## Background — root cause (the bug this fixes)

- `devzhk/Rubien` is **private**. GitHub release **assets** on a private repo require authentication to download.
- Sparkle downloads the enclosure URL **anonymously** (no GitHub token). So `https://github.com/devzhk/Rubien/releases/download/v0.1.3/Rubien-0.1.3.dmg` → **HTTP 404** for the updater. Symptom the user saw: *"An error occurred while downloading the update."*
- The **appcast itself is already public** — it's served by GitHub Pages (`build_type: workflow`, public site), which is public even for a private repo on the Free plan. Only the DMG assets are gated.

∴ We do **not** need to open-source the code, change `SUFeedURL`, or rebuild the app. We only need the *DMG bytes* to live at a publicly-downloadable URL, and the appcast to point there.

**Why "option #2" (separate public repo) over making `devzhk/Rubien` public:** the secrets audit was clean, but the user is not ready to open the source to contributors. A dedicated asset-host repo keeps the source private while making releases downloadable.

---

## Design invariant (the load-bearing decision)

**The appcast URL and `SUFeedURL` must NOT change.** Existing installs (v0.1.2 on Mac A, and any future v0.1.3 installs) poll `https://devzhk.github.io/Rubien/appcast.xml`. If we moved the appcast to the public repo and changed `SUFeedURL`, only *new* builds would know the new feed — the already-installed clients would keep polling the old URL forever and never self-heal. Keeping the appcast in place means **the moment we repoint the enclosure URLs, every already-installed client's next update check succeeds.**

So the split is:

| Thing | Lives where | Changes? |
|---|---|---|
| Source code | private `devzhk/Rubien` | no |
| Appcast `Docs/appcast.xml` + Pages workflow | private `devzhk/Rubien` (Pages) | edit enclosure URLs only |
| `SUFeedURL` (`UpdateConstants.swift`) | app binary | **no** |
| DMG assets | **new public `devzhk/Rubien-releases`** | new |

---

## Key facts the implementer needs (verified this session, 2026-05-30)

- `gh` is authenticated as `devzhk` (active account).
- **Pages is workflow-built.** `.github/workflows/pages.yml` triggers on push to `main` touching `Docs/appcast.xml` (among 3 files), copies `Docs/appcast.xml` → `_site/appcast.xml`, and deploys. So **commit + push the repointed appcast → live feed updates automatically** (no manual publish). Pages CDN sends `cache-control: max-age=600`, so propagation to clients can lag up to ~10 min.
- `devzhk/Rubien-releases` does **not** exist yet.
- Live appcast `https://devzhk.github.io/Rubien/appcast.xml` → **HTTP 200** (public). Its `last-modified` tracks the last release, confirming the Pages workflow runs on appcast pushes.
- `https://github.com/devzhk/Rubien/releases/download/v0.1.3/Rubien-0.1.3.dmg` → **HTTP 404** anonymously (the bug).
- All four releases (`v0.1.0`–`v0.1.3`) exist on the private repo and their DMGs are downloadable *with auth* (`gh release download`), so they can be mirrored to the public repo as **byte-identical** copies (signatures stay valid).
- `scripts/release.sh`:
  - Line **158**: `DMG_URL="https://github.com/devzhk/Rubien/releases/download/v${VERSION}/${VERSIONED_DMG}"` — the value that becomes the appcast enclosure URL (passed to `appcast.sh` via env at line 159).
  - Lines **174-178**: `gh release create "v${VERSION}" "$DMG_PATH" …` with **no `--repo`** → tags + uploads to the *current* (private) repo. **This is the only step that creates the `v${VERSION}` git tag.** Redirecting it to the public repo would silently stop tagging the private source — Task 4 compensates with an explicit `git tag`.
- `scripts/lib/appcast.sh` consumes `DMG_URL` as an env var (line 29). **No change needed there** — fixing `DMG_URL` in `release.sh` is sufficient for future releases.
- Current appcast enclosure signatures (used to verify the mirrored bytes match):
  - v0.1.0 `jDvf54SQB7reLXXhflPQfAKocGLVfkex3JUw8GBmoqSmQlpIn9uVn1aw4pR5M6JjrwyGzTOtIUusBk78OdGPAA==` (length `17066217`)
  - v0.1.1 `r6N/QX9hR7/vH+Vt34GbL3OMeQ3LpqZTXGe4hrQhtoKbnI3rUBxWP1QT3CMMCOqKqx4lsYA9C7mYRQr/my/YBg==` (length `16370237`)
  - v0.1.2 `bTg9Bl8ovuXYAqvpNGAfnyRE8mpug9buqd8br4F5dyQN9JMglThqn19M59/fkixhEXJdiXjRXh5f2LBedMExCQ==` (length `16437702`)
  - v0.1.3 `kQUTZutxQblCDj6p+K3X9foKjvxZrvqW4TuDChuE9CIwj2+PCgd6YPNnEfauAk9THpW1P+Xd5uVdriFEmFXoBw==` (length `16864967`)

---

## Files / artifacts touched

- **Create (external):** public repo `devzhk/Rubien-releases` + 4 releases (`v0.1.0`–`v0.1.3`) hosting the mirrored DMGs.
- **Modify:** `Docs/appcast.xml` — repoint 4 `<enclosure url>` values (private → public repo).
- **Modify:** `scripts/release.sh` — `DMG_URL` base (line 158), `gh release create --repo` (lines 174-178), add private-repo source tag.
- **Modify:** `Docs/Release-Runbook.md` — document the two-repo split.
- **Modify:** `CLAUDE.md` — one bullet in the Releases section noting where DMGs live.
- **Unchanged (intentionally):** `Sources/Rubien/Services/Updates/UpdateConstants.swift` (`SUFeedURL`), `.github/workflows/pages.yml`, `scripts/lib/appcast.sh`.

---

## Task 1: Create the public `devzhk/Rubien-releases` repo

**Files:** none (external repo creation).

- [ ] **Step 1: Create the repo with an initial commit.**

`--add-readme` gives the repo a default-branch HEAD, which `gh release create` needs as a tag target (a release tag must point at a commit).

```bash
gh repo create devzhk/Rubien-releases \
  --public \
  --description "Public release assets (notarized DMGs) for Rubien. Source is private at devzhk/Rubien; this repo only hosts binaries so Sparkle can download them anonymously. Changelog: https://devzhk.github.io/Rubien/appcast.xml" \
  --add-readme
```

Expected: `✓ Created repository devzhk/Rubien-releases on GitHub`.

- [ ] **Step 2: Confirm it's public and has a default branch.**

```bash
gh repo view devzhk/Rubien-releases --json visibility,defaultBranchRef \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print('visibility',d['visibility'],'branch',d['defaultBranchRef']['name'])"
```

Expected: `visibility PUBLIC branch main` (the default-branch name feeds nothing downstream; `gh release create` tags it regardless).

---

## Task 2: Mirror all four DMGs (byte-identical) to the public repo and verify

**Why mirror all four, not just v0.1.3:** the appcast lists four `<item>`s. Sparkle only ever downloads the newest, but leaving three `<enclosure>` URLs pointing at dead (404) private assets is a public-facing landmine (anyone re-deriving a download link, or a future Sparkle behavior change, hits a 404). Mirroring all four keeps the appcast fully valid and the public repo a complete release history. Bytes are downloaded from the private repo's published assets — the *exact* bytes the existing EdDSA signatures were computed over — so signatures remain valid by construction.

**Files:** none (asset upload; DMGs staged under a temp dir).

- [ ] **Step 1: Stage the four published DMGs from the private repo.**

```bash
STAGE="$(mktemp -d -t rubien-dmg-mirror)"
for v in 0.1.0 0.1.1 0.1.2 0.1.3; do
  gh release download "v$v" --repo devzhk/Rubien \
    --pattern "Rubien-$v.dmg" --dir "$STAGE" --clobber
done
ls -l "$STAGE"
```

Expected: four files `Rubien-0.1.0.dmg … Rubien-0.1.3.dmg`.

- [ ] **Step 2: Prove each staged DMG matches the appcast signature BEFORE uploading.**

This is the safety gate: if a mirrored byte stream didn't match the published signature, the re-hosted update would be rejected by clients. `sign_update --verify <file> <sig>` derives the public key from the keychain and checks the signature over the file content.

```bash
SIGN_UPDATE="$(find .build -name 'sign_update' -type f -perm -111 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "run 'swift build' first"; exit 1; }
verify() { "$SIGN_UPDATE" --verify "$STAGE/Rubien-$1.dmg" "$2" && echo "v$1 OK"; }
verify 0.1.0 "jDvf54SQB7reLXXhflPQfAKocGLVfkex3JUw8GBmoqSmQlpIn9uVn1aw4pR5M6JjrwyGzTOtIUusBk78OdGPAA=="
verify 0.1.1 "r6N/QX9hR7/vH+Vt34GbL3OMeQ3LpqZTXGe4hrQhtoKbnI3rUBxWP1QT3CMMCOqKqx4lsYA9C7mYRQr/my/YBg=="
verify 0.1.2 "bTg9Bl8ovuXYAqvpNGAfnyRE8mpug9buqd8br4F5dyQN9JMglThqn19M59/fkixhEXJdiXjRXh5f2LBedMExCQ=="
verify 0.1.3 "kQUTZutxQblCDj6p+K3X9foKjvxZrvqW4TuDChuE9CIwj2+PCgd6YPNnEfauAk9THpW1P+Xd5uVdriFEmFXoBw=="
```

Expected: four `vX.Y.Z OK` lines (each prints the Sparkle "verified" message then our marker). If any fails, **stop** — the private asset differs from what the appcast claims; do not proceed.

- [ ] **Step 3: Create the four releases on the public repo, marking only v0.1.3 latest.**

Older releases pass `--latest=false` so GitHub's "Latest" badge lands on v0.1.3. v0.1.1 mirrors the private repo's pre-release flag.

```bash
gh release create v0.1.0 "$STAGE/Rubien-0.1.0.dmg" --repo devzhk/Rubien-releases \
  --title "Rubien 0.1.0" --notes "Release asset mirror. Changelog: https://devzhk.github.io/Rubien/appcast.xml" --latest=false
gh release create v0.1.1 "$STAGE/Rubien-0.1.1.dmg" --repo devzhk/Rubien-releases \
  --title "Rubien 0.1.1" --notes "Release asset mirror. Changelog: https://devzhk.github.io/Rubien/appcast.xml" --prerelease --latest=false
gh release create v0.1.2 "$STAGE/Rubien-0.1.2.dmg" --repo devzhk/Rubien-releases \
  --title "Rubien 0.1.2" --notes "Release asset mirror. Changelog: https://devzhk.github.io/Rubien/appcast.xml" --latest=false
gh release create v0.1.3 "$STAGE/Rubien-0.1.3.dmg" --repo devzhk/Rubien-releases \
  --title "Rubien 0.1.3" --notes "Release asset mirror. Changelog: https://devzhk.github.io/Rubien/appcast.xml" --latest
```

Expected: four `https://github.com/devzhk/Rubien-releases/releases/tag/vX.Y.Z` URLs.

- [ ] **Step 4: Verify every public DMG URL downloads anonymously (200 after redirects).**

GitHub release assets 302-redirect to a signed object store URL; `-L` follows them. This is the exact path Sparkle takes.

```bash
for v in 0.1.0 0.1.1 0.1.2 0.1.3; do
  code=$(curl -sIL -o /dev/null -w "%{http_code}" \
    "https://github.com/devzhk/Rubien-releases/releases/download/v$v/Rubien-$v.dmg")
  echo "v$v -> $code"
done
```

Expected: four `vX.Y.Z -> 200` lines.

- [ ] **Step 5: Clean up the staging dir.**

```bash
rm -rf "$STAGE"
```

---

## Task 3: Repoint the appcast enclosure URLs, push, and verify the live feed

**Files:**
- Modify: `Docs/appcast.xml` (4 enclosure URLs)

- [ ] **Step 1: Repoint all four enclosure URLs (private → public repo).**

The substring `devzhk/Rubien/releases/download/` is unique to the four private enclosure URLs; replacing it with `devzhk/Rubien-releases/releases/download/` touches exactly those four lines and nothing else (the appcast's `<link>` is `…/Rubien/appcast.xml`, which does not contain `/releases/download/`).

```bash
sed -i '' \
  's#github.com/devzhk/Rubien/releases/download/#github.com/devzhk/Rubien-releases/releases/download/#g' \
  Docs/appcast.xml
```

- [ ] **Step 2: Verify the edit — 4 public URLs, 0 private, still valid XML, signatures untouched.**

```bash
echo "public enclosure URLs: $(grep -c 'Rubien-releases/releases/download' Docs/appcast.xml)  (expect 4)"
echo "stale private URLs:    $(grep -c 'devzhk/Rubien/releases/download'  Docs/appcast.xml)  (expect 0)"
echo "edSignature lines:     $(grep -c 'sparkle:edSignature' Docs/appcast.xml)  (expect 4, unchanged)"
xmllint --noout Docs/appcast.xml && echo "XML OK"
```

Expected: `4`, `0`, `4`, `XML OK`.

- [ ] **Step 3: Commit and push (triggers the Pages deploy workflow).**

```bash
git add Docs/appcast.xml
git commit -m "release infra: host DMGs on public devzhk/Rubien-releases so Sparkle downloads anonymously (private-repo assets 404'd)"
git push origin main
```

- [ ] **Step 4: Wait for the Pages workflow, then confirm the live feed serves the new URLs.**

```bash
gh run watch "$(gh run list --workflow pages.yml --repo devzhk/Rubien --limit 1 --json databaseId -q '.[0].databaseId')" --repo devzhk/Rubien --exit-status
# CDN cache is max-age=600; re-check until it flips (≤ ~10 min):
curl -s https://devzhk.github.io/Rubien/appcast.xml | grep -c 'Rubien-releases/releases/download'
```

Expected: workflow completes green; the `grep -c` eventually prints `4`.

---

## Task 4: Rewire `scripts/release.sh` for future releases

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Introduce a `RELEASES_REPO` variable (near the other env defaults, ~line 27).**

```bash
NOTARY_PROFILE="${NOTARY_PROFILE:-RubienNotary}"
RELEASES_REPO="${RELEASES_REPO:-devzhk/Rubien-releases}"   # public host for DMG assets
APPCAST_TARGET="${APPCAST_TARGET:-production}"
```

- [ ] **Step 2: Point `DMG_URL` (line 158) at the public repo.**

```bash
# Production publishes this DMG to $RELEASES_REPO (step 3 below). For
# APPCAST_TARGET=staging, no asset is uploaded (gh release create is
# production-gated), so this URL is a placeholder in the staging appcast —
# same as before this change, when it pointed at an equally-absent private-repo
# asset. Staging is for local feed testing; hand-upload a DMG if a staging
# build must actually download.
DMG_URL="https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/${VERSIONED_DMG}"
```

> **Staging note (Codex review):** `Docs/staging-appcast.xml` currently has **zero** `<item>`/`<enclosure>` entries — staging has never been run. The placeholder URL only materializes if someone runs `APPCAST_TARGET=staging ./scripts/release.sh`, and it was already non-downloadable before this change. No behavior change; the comment above makes the limitation explicit.

- [ ] **Step 3: Tag the private source commit + create the public release (replace lines 173-178).**

Because `gh release create` now targets the public repo, the private source repo would otherwise never get a `v${VERSION}` tag. Add an explicit annotated tag on the just-pushed appcast commit (the release point) so the source stays traceable.

```bash
# 15. Tag the source commit on the PRIVATE repo. The gh release below now
#     targets the public releases repo, so without this the source would be
#     left untagged for this version.
if [ "$APPCAST_TARGET" = "production" ]; then
    git tag -a "v${VERSION}" -m "Rubien ${VERSION} (build ${BUILD_NUMBER})"
    git push origin "v${VERSION}"
fi

# 16. Create the GitHub release with the DMG on the PUBLIC releases repo so
#     Sparkle (anonymous) can download it. The appcast stays on the private
#     repo's Pages (Docs/appcast.xml -> devzhk.github.io/Rubien/appcast.xml).
if [ "$APPCAST_TARGET" = "production" ]; then
    gh release create "v${VERSION}" "$DMG_PATH" \
        --repo "$RELEASES_REPO" \
        --title "Rubien ${VERSION}" \
        --notes "$RELEASE_NOTES_TEXT" \
        --latest
fi
```

- [ ] **Step 4: Syntax-check the script.**

```bash
bash -n scripts/release.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 5: Commit.**

```bash
git add scripts/release.sh
git commit -m "release.sh: publish DMGs to public devzhk/Rubien-releases, tag source on private repo"
```

---

## Task 5: Document the two-repo split

**Files:**
- Modify: `Docs/Release-Runbook.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a "Release hosting" note to `Docs/Release-Runbook.md`** explaining: source + appcast + Pages live in private `devzhk/Rubien`; DMG assets live in public `devzhk/Rubien-releases`; `SUFeedURL` and the appcast URL never change; the reason is Sparkle's anonymous download vs. private-asset 404; and that `release.sh` tags the private source while `gh release create` targets the public repo.

- [ ] **Step 2: Add one bullet to the Releases section of `CLAUDE.md`:** "DMGs are hosted on the **public** `devzhk/Rubien-releases` repo (Sparkle downloads anonymously; private-repo assets 404). The appcast and `SUFeedURL` stay on the private repo's Pages (`devzhk.github.io/Rubien/appcast.xml`) so existing installs self-heal. `release.sh` sets `RELEASES_REPO` and tags the private source separately."

- [ ] **Step 3: Commit.**

```bash
git add Docs/Release-Runbook.md CLAUDE.md
git commit -m "docs: document public releases-repo split for Sparkle"
```

---

## Task 6: End-to-end verification (Sparkle actually updates)

- [ ] **Step 1:** On Mac A's existing **v0.1.2** install (the one that showed the download error), trigger *Check for Updates*. It should now find v0.1.3, download from the public repo, pass the EdDSA check, and install. (Allow up to ~10 min after Task 3 for the Pages CDN to serve the new appcast.)
- [ ] **Step 2:** Confirm the updated app reports v0.1.3 (build 4) and — given the CloudKit Production fix already shipped in v0.1.3 — syncs against Production.
- [ ] **Step 3:** Repeat on the Mac mini (or install the public DMG directly via browser) and confirm it pulls the library from Production.

---

## Open questions for review

1. **Mirror scope.** Mirror all four versions (chosen, for a valid appcast with no dead links) vs. only v0.1.3 (the only one Sparkle ever downloads)? Any reason to *not* publish the old binaries publicly?
2. **Source tagging.** Is an annotated `git tag v${VERSION}` on the appcast commit the right traceability mechanism now that `gh release create` moved off the private repo? Should it instead tag the *build* commit? (Here the appcast commit is the last commit of the release and an accurate marker.) Acceptable that the public repo's `v${VERSION}` tag points at its README commit (an asset anchor, not source)?
3. **Public release notes.** Mirror releases carry a pointer to the appcast changelog rather than full notes. For *future* releases, `gh release create --repo public` uses `RELEASE_NOTES_TEXT` (the real notes) — is having the user-facing notes on the public repo (not the private one) the right call, or should both carry notes?
4. **CDN propagation.** Pages serves `cache-control: max-age=600`; clients may see the old (404-pointing) appcast for up to 10 min after Task 3. Document-and-wait is the plan — anything better (e.g., a cache-bust) worth doing?
5. **Staging path.** ✅ *Resolved by Codex review:* `APPCAST_TARGET=staging` computes a `DMG_URL` on the public repo with no asset behind it — but `Docs/staging-appcast.xml` has **zero items today** (staging never run), and the URL was equally non-downloadable before the rewire (it pointed at an absent private-repo asset). Not a regression. Resolution: keep behavior, add an explicit code comment (Task 4 Step 2) documenting the placeholder; do **not** auto-publish staging DMGs publicly.
6. **`--add-readme` + README-anchored tags.** Cleanest way to give the public repo a tag target, or prefer an empty/orphan setup?
7. **Security surface.** The public repo exposes only notarized DMGs + a README. Confirm nothing in a DMG embeds private material beyond what ships to users anyway (it's the same binary users run). Any objection to the repo description linking back to the private appcast URL?

---

## Rollback / safety

- **Fully reversible.** Nothing here mutates the private source, the app binary, the signing keys, or the CloudKit data. If anything looks wrong after Task 3, `git revert` the appcast commit and push — Pages redeploys the previous (private-URL) appcast within ~10 min. The public repo can be deleted with no effect on the private repo.
- **Signatures are never regenerated** — we re-host identical bytes and reuse the existing `sparkle:edSignature`/`length`. Task 2 Step 2 proves the bytes match before anything is published.
- **No new build, no re-notarization** — the DMGs are the already-notarized, already-stapled artifacts.

---

## Resolution log (Codex review, 2026-05-30, fresh thread)

Codex reviewed the plan against the real codebase and **green-lit it as structurally sound**. Verified correct:

- **Root cause** — Pages redeploys on `Docs/appcast.xml` push (`pages.yml:12,14,16,43,55`); `SUFeedURL` = `…/Rubien/appcast.xml` (`UpdateConstants.swift:6`), stamped at `build-app.sh:188-189,194`; the four enclosure URLs are the only private-asset pointers. No rebuild / `SUFeedURL` change needed.
- **Signature invariance** — `sign_update` signs file *bytes*, not the URL (`Sparkle/sign_update/main.swift:183,185,276,287`); runtime verify is over downloaded bytes (`SUSignatureVerifier.m:87,95,173,175`). Re-hosting identical bytes keeps sigs valid; `--verify` is a valid pre-upload gate (caveat: derives key from local keychain, not the app's `SUPublicEDKey` — already documented at `release.sh:121-130`).
- **release.sh rewire** — `DMG_URL` at line 158; `gh release create` (`release.sh:175`) is the *only* tag-creating step (no other `git tag` in the file), so the explicit `git tag -a` compensation is correct.
- **All commands/flags** — `gh repo create`, `--latest`/`--latest=false`/`--prerelease`, `gh release download --pattern/--dir/--clobber`, the `sed` substitution (matches only the 4 enclosures, not `<link>` at `appcast.xml:5`), `curl -sIL -w %{http_code}`, `gh run watch --exit-status` — all valid on local `gh 2.61.0`.
- **appcast.sh** — consumes `DMG_URL` as env (`appcast.sh:5,9,28-29`); no edits needed.

**One gap flagged → patched:** staging `DMG_URL` would point at a public-repo asset that staging never uploads. Investigation: `Docs/staging-appcast.xml` has **zero items** (staging never run) and the URL was equally absent before the rewire — not a regression. Resolved by documenting the placeholder in Task 4 Step 2 (no behavior change; staging DMGs are deliberately not auto-published).
