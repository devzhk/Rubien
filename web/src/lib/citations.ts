import { AuthorName, ReferenceRecord } from "./types";

function last(author?: AuthorName): string {
  return author?.family || author?.given || "Unknown";
}

function initials(given: string): string {
  return given
    .split(/\s+/)
    .filter(Boolean)
    .map((part) => `${part[0].toUpperCase()}.`)
    .join(" ");
}

function apaAuthors(authors: AuthorName[]): string {
  if (!authors.length) return "Unknown";
  if (authors.length === 1) return `${authors[0].family}, ${initials(authors[0].given)}`.trim();
  const rendered = authors.map((author) => `${author.family}, ${initials(author.given)}`.trim());
  return `${rendered.slice(0, -1).join(", ")}, & ${rendered[rendered.length - 1]}`;
}

function lastFirstAuthors(authors: AuthorName[]): string {
  if (!authors.length) return "Unknown";
  return authors.map((author) => (author.given ? `${author.family}, ${author.given}` : author.family)).join(", ");
}

export const supportedCitationStyles = ["apa", "mla", "chicago", "ieee", "harvard", "vancouver", "nature"] as const;
export type CitationStyle = (typeof supportedCitationStyles)[number];

export function formatInlineCitation(refs: ReferenceRecord[], style: CitationStyle): string {
  if (["ieee", "vancouver", "nature"].includes(style)) {
    const numbers = refs.map((_, index) => index + 1).join(", ");
    return style === "nature" ? numbers : `[${numbers}]`;
  }
  const parts = refs.map((ref) => {
    const year = ref.year?.toString() ?? "n.d.";
    const primary = last(ref.authors[0]);
    if (style === "mla") return primary;
    if (style === "chicago") return `${primary} ${year}`;
    return `${primary}, ${year}`;
  });
  return `(${parts.join("; ")})`;
}

export function formatBibliography(ref: ReferenceRecord, style: CitationStyle): string {
  const year = ref.year?.toString() ?? "n.d.";
  const title = ref.title || "Untitled";
  const journal = ref.journal ? ` ${ref.journal}` : "";
  const volume = ref.volume ? `, ${ref.volume}` : "";
  const issue = ref.issue ? `(${ref.issue})` : "";
  const pages = ref.pages ? `, ${ref.pages}` : "";
  const doi = ref.doi ? ` https://doi.org/${ref.doi.replace(/^https?:\/\/doi.org\//i, "")}` : "";

  switch (style) {
    case "mla":
      return `${lastFirstAuthors(ref.authors)}. "${title}."${journal}${volume}${issue}${pages}, ${year}.${doi}`.trim();
    case "chicago":
      return `${lastFirstAuthors(ref.authors)}. "${title}."${journal}${volume}${issue} (${year})${pages}.${doi}`.trim();
    case "ieee":
      return `${lastFirstAuthors(ref.authors)}, "${title},"${journal}${volume}${issue}${pages}, ${year}.${doi}`.trim();
    case "harvard":
      return `${lastFirstAuthors(ref.authors)} ${year}, '${title}',${journal}${volume}${issue}${pages}.${doi}`.trim();
    case "vancouver":
      return `${lastFirstAuthors(ref.authors)}. ${title}.${journal}. ${year}${volume}${issue}${pages}.${doi}`.trim();
    case "nature":
      return `${lastFirstAuthors(ref.authors)}. ${title}.${journal}${volume}${pages} (${year}).${doi}`.trim();
    case "apa":
    default:
      return `${apaAuthors(ref.authors)} (${year}). ${title}.${journal}${volume}${issue}${pages}.${doi}`.trim();
  }
}
