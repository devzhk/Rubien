# Supported Paper URLs

Rubien accepts first-class publisher pages, identifier URLs, and direct PDF or Markdown URLs. This is the canonical registry for URL patterns recognized by the app and `rubien-cli add --source`; other documentation should link here instead of duplicating the list.

## Publisher and venue article pages

These hosts have explicit article-path support. Rubien preserves the publisher landing page, rewrites recognized PDF forms where possible, and either reads `citation_*` metadata or uses the DOI/API path noted below.

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
| Science / AAAS | `www.science.org` | `/doi/10.1126/<suffix>`, `/doi/full/10.1126/<suffix>`, or `/doi/abs/10.1126/<suffix>` | `/doi/pdf/10.1126/<suffix>` or `/doi/epdf/10.1126/<suffix>` |
| American Chemical Society | `pubs.acs.org` | `/doi/10.1021/<suffix>`, `/doi/full/10.1021/<suffix>`, or `/doi/abs/10.1021/<suffix>` | `/doi/pdf/10.1021/<suffix>` or `/doi/epdf/10.1021/<suffix>` |
| Astronomy & Astrophysics | `www.aanda.org` | `/articles/aa/full_html/<yyyy>/<issue>/<id>/<id>.html` or `/articles/aa/abs/<yyyy>/<issue>/<id>/<id>.html` | `/articles/aa/pdf/<yyyy>/<issue>/<id>.pdf` |
| eLife | `elifesciences.org` | `/articles/<numeric-id>` | `/articles/<numeric-id>.pdf` |
| eNeuro | `www.eneuro.org` | `/content/<volume>/<issue>/ENEURO.<id>` or `/content/early/<yyyy>/<mm>/<dd>/ENEURO.<id>`; `.abstract`, `.full`, and `.long` variants are accepted | `/content/eneuro/<volume>/<issue>/ENEURO.<id>.full.pdf` or `/content/eneuro/early/<yyyy>/<mm>/<dd>/ENEURO.<id>.full.pdf` |
| APS Physical Review journals | `journals.aps.org` | `/<journal>/abstract/10.1103/<suffix>` or `/<journal>/accepted/10.1103/<suffix>` | `/<journal>/pdf/10.1103/<suffix>` → abstract URL |

Rubien reads most pages from `citation_*` HTML metadata, then uses CrossRef to normalize records with a DOI. eLife uses its official API. APS, Science, and ACS URLs resolve directly through their embedded DOI so publisher HTML is not required. PDF access depends on the publisher.

## Identifier, preprint, and direct-file URLs

These URLs are supported without adding their hosts to the publisher allowlist.

| Source | Host | Supported URL patterns | How Rubien handles it |
|---|---|---|---|
| DOI | `doi.org` | `/10.<registrant>/<suffix>` | Extracts the DOI and resolves metadata through CrossRef. |
| arXiv abstract | `arxiv.org` | `/abs/<yymm.number>[vN]` or `/abs/<archive>/<7-digit-id>[vN]` | Resolves through the arXiv API; an optional version suffix is ignored. |
| arXiv DataCite DOI | `doi.org` | `/10.48550/arXiv.<id>[vN]` | Routes to the arXiv resolver instead of CrossRef. |
| arXiv PDF | `arxiv.org` | `/pdf/<id>.pdf` | Downloads and imports the PDF directly. Use the abstract URL when metadata-only import is preferred. |
| PubMed Central | `pmc.ncbi.nlm.nih.gov` or legacy `www.ncbi.nlm.nih.gov` | `/articles/PMC<digits>/` or `/pmc/articles/PMC<digits>/` | Extracts the PMCID, converts it through NCBI, then resolves through PubMed/CrossRef. Query strings and fragments are accepted. |
| bioRxiv DOI | `doi.org` | `/10.1101/<suffix>` or `/10.64898/<suffix>` | Resolves metadata through CrossRef. With PDF download requested, Rubien tries bioRxiv's `.full.pdf` endpoint before OpenAlex. |
| bioRxiv PDF | `www.biorxiv.org` | `/content/<doi>[vN].full.pdf` | Downloads and imports the PDF directly. |
| medRxiv DOI | `doi.org` | `/10.1101/<suffix>` | Resolves metadata through CrossRef. With PDF download requested, Rubien tries medRxiv's `.full.pdf` endpoint before OpenAlex. |
| medRxiv PDF | `www.medrxiv.org` | `/content/<doi>[vN].full.pdf` | Downloads and imports the PDF directly. |
| Remote PDF | Any HTTP(S) host | Any URL whose path ends in `.pdf` | Downloads and imports the PDF directly unless it matches a first-class publisher PDF pattern above. |
| Remote Markdown | Any HTTP(S) host | Any URL whose path ends in `.md` or `.markdown` | Downloads and imports Markdown; GitHub `/blob/` URLs are requested with `raw=1`. |

bioRxiv and medRxiv website landing pages normally append a version such as `v1`, which is not part of the DOI. For metadata import, use the displayed `https://doi.org/...` link; use the `.full.pdf` URL for direct file import.

PubMed article URLs are not currently parsed as PMID inputs; paste the bare PMID instead. Remote `.bib` and `.ris` URLs are also not imported—download those files first.

## Requesting support for another site

Open a [Paper URL support issue](https://github.com/devzhk/Rubien/issues/new?template=paper-url-support.yml) with one unrecognized article landing page. Do not include institutional proxy credentials, session cookies, or temporary signed URLs.

## Adding another publisher or journal

To add a host or URL pattern:

1. Add the host and its article URL patterns to `KnownPaperHost.classify` in `Sources/RubienCore/Services/PaperURLResolver.swift`.
2. Add any PDF-to-landing-page or canonical URL rewrites to `rewritePDFURLToLanding` in the same file.
3. Add regression tests for extraction, classification, rewriting, and resolution under `Tests/RubienCoreTests/`.
4. Verify that a live page exposes the required metadata, including authors, and that redirects stay within the allowlist.
5. Update this table. If CLI behavior or examples change, update `Docs/CLI-Reference.md` too.
