import { emptyReference, id, nowISO, parseAuthors } from "./model";
import { AuthorName, ReferenceRecord } from "./types";

export async function resolveLocator(input: string): Promise<ReferenceRecord> {
  const locator = input.trim();
  if (!locator) throw new Error("Enter a DOI, arXiv ID, ISBN, URL, or title.");
  const doi = extractDOI(locator);
  if (doi) return resolveDOI(doi);
  const arxiv = extractArxiv(locator);
  if (arxiv) return resolveArxiv(arxiv);
  const isbn = extractISBN(locator);
  if (isbn) return resolveISBN(isbn);
  if (/^https?:\/\//i.test(locator)) {
    return emptyReference({
      id: id("ref"),
      title: locator,
      url: locator,
      referenceType: "Web Page",
      metadataSource: "manual",
      verificationStatus: "seedOnly"
    });
  }
  return resolveTitle(locator);
}

async function resolveDOI(doi: string): Promise<ReferenceRecord> {
  const response = await fetch(`https://api.crossref.org/works/${encodeURIComponent(doi)}`);
  if (!response.ok) throw new Error(`Crossref did not return metadata for ${doi}.`);
  const payload = (await response.json()) as CrossrefWorkResponse;
  const work = payload.message;
  const issued = firstDate(work.issued?.["date-parts"] ?? work.published?.["date-parts"]);
  return emptyReference({
    id: id("ref"),
    title: work.title?.[0] ?? doi,
    authors: (work.author ?? []).map((author) => ({ given: author.given ?? "", family: author.family ?? author.name ?? "" })),
    year: issued?.year,
    issuedMonth: issued?.month,
    issuedDay: issued?.day,
    journal: work["container-title"]?.[0],
    volume: work.volume,
    issue: work.issue,
    pages: work.page,
    doi,
    url: work.URL,
    abstract: stripTags(work.abstract),
    publisher: work.publisher,
    referenceType: work.type === "proceedings-article" ? "Conference Paper" : "Journal Article",
    metadataSource: "doi",
    verificationStatus: "candidate"
  });
}

async function resolveArxiv(arxivId: string): Promise<ReferenceRecord> {
  const response = await fetch(`https://export.arxiv.org/api/query?id_list=${encodeURIComponent(arxivId)}`);
  if (!response.ok) throw new Error(`arXiv did not return metadata for ${arxivId}.`);
  const xml = new DOMParser().parseFromString(await response.text(), "application/xml");
  const entry = xml.querySelector("entry");
  if (!entry) throw new Error(`No arXiv entry found for ${arxivId}.`);
  const authors: AuthorName[] = [...entry.querySelectorAll("author > name")].map((node) =>
    parseAuthors(node.textContent ?? "")[0]
  ).filter(Boolean);
  const published = entry.querySelector("published")?.textContent;
  const date = published ? new Date(published) : undefined;
  return emptyReference({
    id: id("ref"),
    title: normalizeXML(entry.querySelector("title")?.textContent ?? arxivId),
    authors,
    year: date && !Number.isNaN(date.getTime()) ? date.getFullYear() : undefined,
    abstract: normalizeXML(entry.querySelector("summary")?.textContent ?? ""),
    doi: entry.querySelector("arxiv\\:doi, doi")?.textContent ?? undefined,
    url: `https://arxiv.org/abs/${arxivId}`,
    journal: "arXiv",
    referenceType: "Journal Article",
    metadataSource: "arxiv",
    verificationStatus: "candidate"
  });
}

async function resolveISBN(isbn: string): Promise<ReferenceRecord> {
  const response = await fetch(`https://openlibrary.org/isbn/${encodeURIComponent(isbn)}.json`);
  if (!response.ok) throw new Error(`Open Library did not return metadata for ${isbn}.`);
  const work = (await response.json()) as OpenLibraryBook;
  const authors = await openLibraryAuthors(work.authors?.map((author) => author.key) ?? []);
  return emptyReference({
    id: id("ref"),
    title: work.title ?? isbn,
    authors,
    year: numberFrom(work.publish_date),
    publisher: work.publishers?.[0],
    numberOfPages: work.number_of_pages?.toString(),
    isbn,
    referenceType: "Book",
    metadataSource: "isbn",
    verificationStatus: "candidate"
  });
}

async function resolveTitle(title: string): Promise<ReferenceRecord> {
  const response = await fetch(
    `https://api.openalex.org/works?search=${encodeURIComponent(title)}&per-page=1`
  );
  if (!response.ok) {
    return emptyReference({
      id: id("ref"),
      title,
      referenceType: "Journal Article",
      metadataSource: "manual",
      verificationStatus: "seedOnly"
    });
  }
  const payload = (await response.json()) as OpenAlexResponse;
  const work = payload.results?.[0];
  if (!work) {
    return emptyReference({
      id: id("ref"),
      title,
      referenceType: "Journal Article",
      metadataSource: "manual",
      verificationStatus: "seedOnly"
    });
  }
  return emptyReference({
    id: id("ref"),
    title: work.title ?? title,
    authors: (work.authorships ?? []).map((authorship) => parseAuthors(authorship.author.display_name)[0]).filter(Boolean),
    year: work.publication_year,
    journal: work.primary_location?.source?.display_name,
    doi: work.doi?.replace(/^https?:\/\/doi.org\//i, ""),
    url: work.primary_location?.landing_page_url ?? work.id,
    referenceType: work.type === "book" ? "Book" : work.type === "dissertation" ? "Thesis" : "Journal Article",
    metadataSource: "openalex",
    verificationStatus: "candidate"
  });
}

function extractDOI(input: string): string | undefined {
  const match = input.match(/10\.\d{4,9}\/[-._;()/:A-Z0-9]+/i);
  return match?.[0].replace(/[.);,\s]+$/, "");
}

function extractArxiv(input: string): string | undefined {
  const match =
    input.match(/arxiv\.org\/abs\/([0-9]{4}\.[0-9]{4,5}(v\d+)?)/i) ??
    input.match(/\barXiv:([0-9]{4}\.[0-9]{4,5}(v\d+)?)\b/i) ??
    input.match(/\b([0-9]{4}\.[0-9]{4,5}(v\d+)?)\b/);
  return match?.[1];
}

function extractISBN(input: string): string | undefined {
  const compact = input.replace(/[-\s]/g, "");
  return /^(97[89])?\d{9}[\dX]$/i.test(compact) ? compact : undefined;
}

async function openLibraryAuthors(keys: string[]): Promise<AuthorName[]> {
  const authors = await Promise.all(
    keys.slice(0, 16).map(async (key) => {
      try {
        const response = await fetch(`https://openlibrary.org${key}.json`);
        const author = (await response.json()) as { name?: string };
        return parseAuthors(author.name ?? "")[0];
      } catch {
        return undefined;
      }
    })
  );
  return authors.filter(Boolean) as AuthorName[];
}

function firstDate(parts?: number[][]): { year?: number; month?: number; day?: number } | undefined {
  const first = parts?.[0];
  if (!first) return undefined;
  return { year: first[0], month: first[1], day: first[2] };
}

function numberFrom(value?: string): number | undefined {
  const match = value?.match(/\d{4}/);
  return match ? Number(match[0]) : undefined;
}

function stripTags(value?: string): string | undefined {
  return value?.replace(/<[^>]+>/g, "").trim();
}

function normalizeXML(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

interface CrossrefWorkResponse {
  message: {
    title?: string[];
    author?: Array<{ given?: string; family?: string; name?: string }>;
    issued?: { "date-parts": number[][] };
    published?: { "date-parts": number[][] };
    "container-title"?: string[];
    volume?: string;
    issue?: string;
    page?: string;
    URL?: string;
    abstract?: string;
    publisher?: string;
    type?: string;
  };
}

interface OpenLibraryBook {
  title?: string;
  authors?: Array<{ key: string }>;
  publish_date?: string;
  publishers?: string[];
  number_of_pages?: number;
}

interface OpenAlexResponse {
  results?: Array<{
    id?: string;
    doi?: string;
    title?: string;
    publication_year?: number;
    type?: string;
    primary_location?: {
      landing_page_url?: string;
      source?: { display_name?: string };
    };
    authorships?: Array<{ author: { display_name: string } }>;
  }>;
}
