# Citation Meta Fixtures

These HTML fixtures back `CitationMetaScraperParseTests` and `PaperURLResolverTests`.

## Synthetic vs. captured

The initial set is **synthetic** — small hand-written HTML files that exercise
the parser's specific code paths (relative-PDF resolution, paywall detection,
missing citation_*, etc.). They are not meant to mirror a real publisher's
page byte-for-byte.

Before shipping, capture **real HTML** from each target site and verify the
parser produces the same fields. Replace each synthetic fixture with the real
one, keeping the comment header noting source URL and capture date.

## Refresh procedure

When a fixture starts failing (because a site redesigned its meta tags):

1. Open the source URL in a browser; "View Source" or `curl -A "Rubien/1.0" <url>`.
2. Save the entire `<head>` (or full document) into the fixture file.
3. Update the comment header's CAPTURED date.
4. Run `swift test --filter CitationMetaScraperParseTests`.
5. If the test expectations now mismatch, update the assertions to match the
   new meta-tag set. Open a GitHub issue noting which site changed.

## Sites covered

| Fixture | Live source |
|---|---|
| openreview-forum.html | https://openreview.net/forum?id=<some-real-id> |
| aclanthology-paper.html | https://aclanthology.org/<some-real-paper>/ |
| cvf-paper.html | https://openaccess.thecvf.com/content/<conf>/html/<paper>.html |
| neurips-proceedings.html | https://proceedings.neurips.cc/... (capture before shipping) |
| pmlr-paper.html | https://proceedings.mlr.press/... (capture before shipping) |
| ieee-xplore.html | https://ieeexplore.ieee.org/document/... (capture before shipping) |
| nature-article.html | https://nature.com/articles/... (capture before shipping) |
| springer-chapter.html | https://link.springer.com/chapter/... (capture before shipping) |
| acm-dl.html | https://dl.acm.org/doi/... (capture before shipping) |
| sciencedirect-article.html | https://www.sciencedirect.com/science/article/pii/... (capture before shipping) |

Smoke tests (`PaperURLLiveSmokeTests.swift`) gated behind `RUBIEN_LIVE_TESTS=1`
hit these live URLs and assert minimum fields (`title`, `authors`, `year`).
