# Supported Paper URLs

Rubien resolves journal articles by DOI without journal-specific support. Direct publisher URLs require explicit support. This table lists the URL patterns recognized by the app and `rubien-cli add --source`.

This is the canonical registry. Other documentation should link here instead of duplicating the list.

| Publisher or venue | Host | Article URL patterns | PDF URL rewrite |
|---|---|---|---|
| OpenReview | `openreview.net` | `/forum?id=<id>` | `/pdf?id=<id>` |
| ACL Anthology | `aclanthology.org` | `/<paper-id>/` | `/<paper-id>.pdf` |
| CVF Open Access | `openaccess.thecvf.com` | `/content/<venue>/html/<paper>.html` | `/content/<venue>/papers/<paper>.pdf` |
| NeurIPS (legacy) | `papers.nips.cc` | `/paper/<year>/hash/<paper>.html` | `/paper/<year>/file/<paper>.pdf` |
| NeurIPS Proceedings | `proceedings.neurips.cc` | `/paper_files/paper/<year>/hash/<paper>.html` | `/paper_files/paper/<year>/file/<paper>.pdf` |
| PMLR | `proceedings.mlr.press` | `/v<volume>/<paper>.html` | `/v<volume>/<paper>/<paper>.pdf` |
| IEEE Xplore | `ieeexplore.ieee.org` | `/document/<id>` or `/abstract/document/<id>` | None |
| ACM Digital Library | `dl.acm.org` | `/doi/10.<registrant>/<suffix>` or `/doi/abs/10.<registrant>/<suffix>` | `/doi/pdf/10.<registrant>/<suffix>` |
| Nature | `nature.com` | `/articles/<article-id>` | `/articles/<article-id>.pdf` |
| Springer Link | `link.springer.com` | `/article/<id>`, `/chapter/<id>`, `/book/<id>`, or `/referenceworkentry/<id>` | None |
| ScienceDirect | `sciencedirect.com` | `/science/article/pii/<pii>` or `/science/article/abs/pii/<pii>` | `/science/article/pii/<pii>/pdfft` |
| eLife | `elifesciences.org` | `/articles/<numeric-id>` | `/articles/<numeric-id>.pdf` |
| eNeuro | `www.eneuro.org` | `/content/<volume>/<issue>/ENEURO.<id>` or `/content/early/<yyyy>/<mm>/<dd>/ENEURO.<id>`; `.abstract`, `.full`, and `.long` variants are accepted | `/content/eneuro/<volume>/<issue>/ENEURO.<id>.full.pdf` or `/content/eneuro/early/<yyyy>/<mm>/<dd>/ENEURO.<id>.full.pdf` |
| APS Physical Review journals | `journals.aps.org` | `/<journal>/abstract/10.1103/<suffix>` or `/<journal>/accepted/10.1103/<suffix>` | `/<journal>/pdf/10.1103/<suffix>` → abstract URL |

Rubien reads most pages from `citation_*` HTML metadata, then uses CrossRef to normalize records with a DOI. eLife uses its official API. APS URLs resolve directly through their embedded DOI so Cloudflare-protected publisher HTML is not required. PDF access depends on the publisher.

## Requesting support for another site

Open a [Paper URL support issue](https://github.com/devzhk/Rubien/issues/new?template=paper-url-support.yml) with one unrecognized article landing page. Do not include institutional proxy credentials, session cookies, or temporary signed URLs.

## Adding another publisher or journal

To add a host or URL pattern:

1. Add the host and its article URL patterns to `KnownPaperHost.classify` in `Sources/RubienCore/Services/PaperURLResolver.swift`.
2. Add any PDF-to-landing-page or canonical URL rewrites to `rewritePDFURLToLanding` in the same file.
3. Add regression tests for extraction, classification, rewriting, and resolution under `Tests/RubienCoreTests/`.
4. Verify that a live page exposes the required metadata, including authors, and that redirects stay within the allowlist.
5. Update this table. If CLI behavior or examples change, update `Docs/CLI-Reference.md` too.
