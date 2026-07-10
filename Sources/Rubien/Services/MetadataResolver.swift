#if os(macOS)
import Foundation
import OSLog
import RubienCore
import RubienPDFKit

private let resolverLog = Logger(subsystem: "Rubien", category: "MetadataResolver")

private func resolverTrace(_ message: String) {
    guard RubienDebugLogging.metadataVerbose else { return }
    resolverLog.notice("\(message, privacy: .public)")
    if let data = "[MetadataResolver] \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

enum ReferenceMetadataRefreshResult {
    case refreshed(Reference)
    case pending(MetadataResolutionResult)
    case skipped(String)
    case failed(String)
}

struct ManualCandidateImportAssessment {
    let reference: Reference
    let canImportDirectly: Bool
    let presentFields: [String]
    let missingFields: [String]
}

struct ManualEntryOutcome: Sendable {
    let result: MetadataResolutionResult
    let preferredPDFURL: String?    // populated only on .verified from paper-URL path

    init(result: MetadataResolutionResult, preferredPDFURL: String? = nil) {
        self.result = result
        self.preferredPDFURL = preferredPDFURL
    }
}

@MainActor
final class MetadataResolver {

    init() {}

    // MARK: - PDF import

    func resolveImportedPDF(url: URL, extracted: PDFService.ExtractedMetadata) async -> MetadataResolutionResult {
        await ImportedPDFMetadataResolver.resolve(url: url, extracted: extracted)
    }

    // MARK: - Manual entry (paste DOI / arXiv / PMID / ISBN / title)

    func resolveManualEntry(_ text: String) async -> ManualEntryOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ManualEntryOutcome(result: .rejected(
                RejectedEnvelope(
                    seed: nil,
                    fallbackReference: nil,
                    reason: .unsupportedRoute,
                    message: "Enter a DOI, arXiv ID, PMID, PMCID, ISBN, paper URL, or paper title."
                )
            ))
        }

        if let identifier = MetadataFetcher.extractIdentifier(from: trimmed) {
            let (result, scrapedPDFURL) = await resolveIdentifierLocally(identifier, seed: nil, fallback: nil)
            return ManualEntryOutcome(result: result, preferredPDFURL: scrapedPDFURL)
        }

        // Treat any remaining input as a title search (OpenAlex -> Semantic Scholar)
        let seed = MetadataResolutionSeed(
            fileName: trimmed,
            title: trimmed,
            workKindHint: .unknown
        )
        if let titleResult = await resolveByTitle(trimmed, seed: seed, fallback: nil) {
            return ManualEntryOutcome(result: titleResult)
        }
        return ManualEntryOutcome(result: .rejected(
            RejectedEnvelope(
                seed: seed,
                fallbackReference: nil,
                currentReference: nil,
                reason: .insufficientEvidence,
                message: "No matching record found. Try a DOI, arXiv ID, PMID, PMCID, paper URL, or ISBN instead."
            )
        ))
    }

    // MARK: - Seed-based resolution (used by retry path)

    func resolveSeed(_ seed: MetadataResolutionSeed, fallback: Reference?) async -> MetadataResolutionResult {
        if let doi = seed.doi?.rubien_nilIfBlank {
            let (result, _) = await resolveIdentifierLocally(.doi(doi), seed: seed, fallback: fallback)
            if case .verified = result { return result }
            if case .candidate = result { return result }
            if case .blocked = result { return result }
        }
        if let isbn = seed.isbn?.rubien_nilIfBlank {
            let (result, _) = await resolveIdentifierLocally(.isbn(isbn), seed: seed, fallback: fallback)
            if case .verified = result { return result }
            if case .candidate = result { return result }
            if case .blocked = result { return result }
        }
        if let title = seed.title?.rubien_nilIfBlank,
           let titleResult = await resolveByTitle(title, seed: seed, fallback: fallback) {
            return titleResult
        }
        return .seedOnly(
            IntakeEnvelope(
                seed: seed,
                fallbackReference: fallback,
                currentReference: fallback,
                message: "Seed retained; no authoritative match found."
            )
        )
    }

    // MARK: - Candidate confirmation

    func resolveCandidate(
        _ candidate: MetadataCandidate,
        fallback: Reference? = nil,
        seed: MetadataResolutionSeed? = nil,
        treatingManualSelectionAsConfirmation: Bool = false,
        reviewedBy: String = "candidate-selection"
    ) async -> MetadataResolutionResult {
        let assessment = Self.assessManuallyConfirmedCandidate(candidate, fallback: fallback)
        let candidateReference = assessment.reference
        let manual = MetadataVerifier.manuallyVerified(candidateReference, reviewedBy: reviewedBy)
        let evidence = buildGenericEvidence(
            for: manual,
            fetchMode: .manual,
            origin: .manual,
            recordKey: Self.recordKey(for: candidate),
            exactIdentifierMatch: false
        )
        _ = treatingManualSelectionAsConfirmation
        _ = seed
        return .verified(VerifiedEnvelope(reference: manual, evidence: evidence))
    }

    // MARK: - Retry / refresh

    func retryIntake(_ intake: MetadataIntake) async -> MetadataResolutionResult {
        if let originalInput = intake.originalInput?.rubien_nilIfBlank {
            let outcome = await resolveManualEntry(originalInput)
            return outcome.result
        }
        if let seed = intake.decodedSeed {
            return await resolveSeed(
                seed,
                fallback: intake.decodedFallbackReference ?? intake.decodedCurrentReference
            )
        }
        return .rejected(
            RejectedEnvelope(
                seed: nil,
                fallbackReference: intake.decodedFallbackReference,
                currentReference: intake.decodedCurrentReference,
                reason: .unsupportedRoute,
                message: "Pending intake has no retryable input."
            )
        )
    }

    func refreshReference(_ reference: Reference, allowCandidateSelection _: Bool) async -> ReferenceMetadataRefreshResult {
        return await withTaskGroup(of: ReferenceMetadataRefreshResult.self) { group in
            group.addTask { await self.refreshReferenceCore(reference) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                return .failed("Metadata refresh timed out after 90 seconds. Check your network and try again.")
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func refreshReferenceCore(_ reference: Reference) async -> ReferenceMetadataRefreshResult {
        let seed = MetadataResolutionSeed.fromReference(reference)
        let hasIdentifier = normalizedIdentifier(reference.doi) != nil
            || normalizedIdentifier(reference.isbn) != nil
            || normalizedIdentifier(reference.pmid) != nil
        let hasTitle = !reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasIdentifier,
           let result = await refreshWithDirectIdentifierAPIs(reference, seed: seed) {
            return result
        }

        if !hasIdentifier, seed.workKindHint == .book, hasTitle,
           let result = await refreshWithBookTitleSearch(reference, seed: seed) {
            return result
        }

        if hasTitle,
           let result = await refreshWithOpenAlexTitleSearch(reference, seed: seed) {
            return result
        }

        return .skipped("No matching record found in known databases. Add a DOI or ISBN and retry.")
    }

    private func refreshOutcome(from result: MetadataResolutionResult, original: Reference) async -> ReferenceMetadataRefreshResult {
        switch result {
        case .verified(let envelope):
            var refreshed = MetadataResolution.mergeRefreshedReference(primary: envelope.reference, existing: original)

            if (refreshed.abstract ?? "").isEmpty {
                if let doi = refreshed.doi, !doi.isEmpty {
                    if let abs = try? await MetadataFetcher.fetchAbstractFromSemanticScholar(doi: doi) {
                        refreshed.abstract = abs
                    } else if let abs = try? await MetadataFetcher.fetchAbstractFromOpenAlex(doi: doi) {
                        refreshed.abstract = abs
                    }
                } else if !refreshed.title.isEmpty,
                          let abs = try? await MetadataFetcher.fetchAbstractFromOpenAlex(title: refreshed.title) {
                    refreshed.abstract = abs
                }
            }

            if MetadataResolution.hasMeaningfulRefreshChanges(original: original, refreshed: refreshed) {
                return .refreshed(refreshed)
            }
            return .skipped("No metadata changes.")
        case .candidate, .blocked, .seedOnly, .rejected:
            return .pending(result)
        }
    }

    private func refreshWithDirectIdentifierAPIs(_ reference: Reference, seed: MetadataResolutionSeed) async -> ReferenceMetadataRefreshResult? {
        let identifier: MetadataFetcher.Identifier?
        if let doi = normalizedIdentifier(reference.doi) {
            identifier = .doi(doi)
        } else if let pmid = normalizedIdentifier(reference.pmid) {
            identifier = .pmid(pmid)
        } else if let isbn = normalizedIdentifier(reference.isbn) {
            identifier = .isbn(isbn)
        } else {
            identifier = nil
        }
        guard let identifier else { return nil }

        let (localResult, _) = await resolveIdentifierLocally(identifier, seed: seed, fallback: reference)
        let outcome = await refreshOutcome(from: localResult, original: reference)
        switch outcome {
        case .refreshed, .skipped:
            return outcome
        default:
            return nil
        }
    }

    private func refreshWithOpenAlexTitleSearch(_ reference: Reference, seed: MetadataResolutionSeed) async -> ReferenceMetadataRefreshResult? {
        let title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        _ = seed
        do {
            guard let fetched = try await MetadataFetcher.fetchFromOpenAlexByTitle(title) else { return nil }
            let titleScore = MetadataResolution.titleSimilarity(title, fetched.title)
            guard titleScore >= 0.80 else { return nil }

            var refreshed = MetadataResolution.mergeRefreshedReference(primary: fetched, existing: reference)
            if (refreshed.abstract ?? "").isEmpty, let doi = refreshed.doi, !doi.isEmpty,
               let abs = try? await MetadataFetcher.fetchAbstractFromSemanticScholar(doi: doi) {
                refreshed.abstract = abs
            }
            if MetadataResolution.hasMeaningfulRefreshChanges(original: reference, refreshed: refreshed) {
                return .refreshed(refreshed)
            }
            return .skipped("No metadata changes.")
        } catch {
            resolverTrace("refreshWithOpenAlexTitleSearch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func refreshWithBookTitleSearch(_ reference: Reference, seed: MetadataResolutionSeed) async -> ReferenceMetadataRefreshResult? {
        let title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        _ = seed
        guard let bookRef = try? await MetadataFetcher.searchBookByTitle(title) else { return nil }
        let titleScore = MetadataResolution.titleSimilarity(title, bookRef.title)
        guard titleScore >= 0.60 else { return nil }
        let refreshed = MetadataResolution.mergeRefreshedReference(primary: bookRef, existing: reference)
        if MetadataResolution.hasMeaningfulRefreshChanges(original: reference, refreshed: refreshed) {
            return .refreshed(refreshed)
        }
        return .skipped("Book title search matched but metadata is unchanged.")
    }

    // MARK: - Title search (OpenAlex -> Semantic Scholar)

    private func resolveByTitle(
        _ title: String,
        seed: MetadataResolutionSeed?,
        fallback: Reference?
    ) async -> MetadataResolutionResult? {
        guard let fetched = try? await MetadataFetcher.fetchFromOpenAlexByTitle(title) else {
            return nil
        }
        let titleScore = MetadataResolution.titleSimilarity(title, fetched.title)
        guard titleScore >= 0.80 else { return nil }

        var enriched = fetched
        if (enriched.abstract ?? "").isEmpty, let doi = enriched.doi, !doi.isEmpty,
           let abs = try? await MetadataFetcher.fetchAbstractFromSemanticScholar(doi: doi) {
            enriched.abstract = abs
        }

        let evidence = buildGenericEvidence(
            for: enriched,
            fetchMode: .identifier,
            origin: .identifierAPI,
            recordKey: enriched.doi?.rubien_nilIfBlank,
            exactIdentifierMatch: false
        )
        return verifyFetchedRecord(
            AuthoritativeMetadataRecord(reference: enriched, evidence: evidence),
            seed: seed,
            fallback: fallback,
            defaultRejectMessage: "Title search matched, but auto-verification rules were not met."
        )
    }

    // MARK: - Identifier resolution (direct HTTP to CrossRef / arXiv / PMID / ISBN)

    private func resolveIdentifierLocally(
        _ identifier: MetadataFetcher.Identifier,
        seed: MetadataResolutionSeed?,
        fallback: Reference?
    ) async -> (MetadataResolutionResult, scrapedPDFURL: String?) {
        do {
            // All non-paperURL identifiers fetch a Reference with no scrapedPDFURL;
            // only .paperURL ever yields a non-nil URL via PaperURLResolver.
            let (reference, scrapedPDFURL): (Reference, String?)
            switch identifier {
            case .doi(let value):    (reference, scrapedPDFURL) = (try await MetadataFetcher.fetchFromDOI(value), nil)
            case .pmid(let value):   (reference, scrapedPDFURL) = (try await MetadataFetcher.fetchFromPMID(value), nil)
            case .arxiv(let value):  (reference, scrapedPDFURL) = (try await MetadataFetcher.fetchFromArXiv(value), nil)
            case .isbn(let value):   (reference, scrapedPDFURL) = (try await MetadataFetcher.fetchFromISBN(value), nil)
            case .pmcid(let value):  (reference, scrapedPDFURL) = (try await MetadataFetcher.fetchFromPMCID(value), nil)
            case .paperURL(let url):
                let outcome = try await PaperURLResolver.resolve(url)
                (reference, scrapedPDFURL) = (outcome.reference, outcome.scrapedPDFURL)
            }

            let evidence = buildGenericEvidence(
                for: reference,
                fetchMode: .identifier,
                origin: .identifierAPI,
                recordKey: normalizedIdentifier(reference.doi)
                    ?? normalizedIdentifier(reference.pmid)
                    ?? normalizedIdentifier(reference.isbn),
                exactIdentifierMatch: true
            )
            let result = verifyFetchedRecord(
                AuthoritativeMetadataRecord(reference: reference, evidence: evidence),
                seed: seed,
                fallback: fallback,
                defaultRejectMessage: "Identifier matched, but auto-verification rules were not met."
            )

            // Force scrapedPDFURL to nil on any non-verified outcome — preferredPDFURL
            // is defined as "populated only on .verified". See ManualEntryOutcome.
            let effectiveScrapedPDFURL: String? = {
                if case .verified = result { return scrapedPDFURL }
                return nil
            }()
            return (result, effectiveScrapedPDFURL)
        } catch PaperURLResolver.ResolveError.noAuthorsAvailable(let partialRef, _) {
            // Spec §4: empty Reference.authors produces .candidate (NOT .rejected),
            // so the user reviews the partial metadata before importing.
            // scrapedPDFURL is intentionally discarded — preferredPDFURL is
            // .verified-only.
            resolverTrace("resolveIdentifierLocally noAuthorsAvailable: title=\(partialRef.title)")
            let envelope = MetadataResolver.candidateEnvelopeForNoAuthors(
                partialRef: partialRef,
                seed: seed,
                fallback: fallback
            )
            return (.candidate(envelope), nil)
        } catch {
            resolverTrace("resolveIdentifierLocally failed error=\"\(error.localizedDescription)\"")
            return (.rejected(
                RejectedEnvelope(
                    seed: seed,
                    fallbackReference: fallback,
                    currentReference: fallback,
                    reason: .insufficientEvidence,
                    message: error.localizedDescription
                )
            ), nil)
        }
    }

    // MARK: - Verification glue

    private func verifyFetchedRecord(
        _ record: AuthoritativeMetadataRecord,
        seed: MetadataResolutionSeed?,
        fallback: Reference?,
        defaultRejectMessage: String
    ) -> MetadataResolutionResult {
        let decision = MetadataVerifier.verify(reference: record.reference, seed: seed, evidence: record.evidence)
        switch decision {
        case .verified(let envelope):
            let mergedReference = fallback.map { MetadataResolution.mergeReference(primary: envelope.reference, fallback: $0) } ?? envelope.reference
            return .verified(VerifiedEnvelope(reference: mergedReference, evidence: envelope.evidence))

        case .candidate(let envelope):
            let current = fallback.map { MetadataResolution.mergeReference(primary: envelope.currentReference ?? record.reference, fallback: $0) }
                ?? envelope.currentReference
                ?? record.reference
            return .candidate(
                CandidateEnvelope(
                    seed: seed ?? envelope.seed,
                    fallbackReference: fallback ?? envelope.fallbackReference,
                    currentReference: current,
                    candidates: envelope.candidates,
                    message: envelope.message,
                    evidence: envelope.evidence ?? record.evidence
                )
            )

        case .blocked(let envelope):
            return .blocked(
                BlockedEnvelope(
                    seed: seed ?? envelope.seed,
                    fallbackReference: fallback ?? envelope.fallbackReference,
                    currentReference: envelope.currentReference ?? record.reference,
                    candidates: envelope.candidates,
                    reason: envelope.reason,
                    message: envelope.message,
                    evidence: envelope.evidence ?? record.evidence
                )
            )

        case .rejected(let envelope):
            let mergedCurrent = fallback.map { MetadataResolution.mergeReference(primary: envelope.currentReference ?? record.reference, fallback: $0) }
                ?? envelope.currentReference
                ?? record.reference
            return .rejected(
                RejectedEnvelope(
                    seed: seed ?? envelope.seed,
                    fallbackReference: fallback ?? envelope.fallbackReference,
                    currentReference: mergedCurrent,
                    reason: envelope.reason,
                    message: envelope.message.isEmpty ? defaultRejectMessage : envelope.message,
                    evidence: envelope.evidence ?? record.evidence
                )
            )
        }
    }

    // MARK: - Candidate → Reference helpers

    nonisolated private static func referenceFromCandidate(
        _ candidate: MetadataCandidate,
        fallback: Reference?
    ) -> Reference {
        let candidateAbstract = candidate.snippet?.rubien_nilIfBlank
        let fallbackAbstract = fallback?.abstract?.rubien_nilIfBlank
        let resolvedAbstract: String? = {
            switch (candidateAbstract, fallbackAbstract) {
            case let (candidateAbstract?, fallbackAbstract?):
                return candidateAbstract.count >= fallbackAbstract.count ? candidateAbstract : fallbackAbstract
            case let (candidateAbstract?, nil):
                return candidateAbstract
            case let (nil, fallbackAbstract?):
                return fallbackAbstract
            case (nil, nil):
                return nil
            }
        }()

        var ref = Reference(
            title: candidate.title,
            authors: candidate.authors,
            year: candidate.year,
            journal: candidate.journal,
            doi: fallback?.doi,
            url: candidate.detailURL.isEmpty ? fallback?.url : candidate.detailURL,
            abstract: resolvedAbstract,
            referenceType: candidate.referenceType ?? candidate.workKind.referenceType,
            metadataSource: candidate.source,
            publisher: candidate.publisher,
            isbn: candidate.isbn ?? fallback?.isbn,
            issn: candidate.issn ?? fallback?.issn
        )
        if let fallback {
            ref.volume = ref.volume ?? fallback.volume
            ref.issue = ref.issue ?? fallback.issue
            ref.pages = ref.pages ?? fallback.pages
            // Pre-B8 this also adopted `fallback.pdfPath` so the manually
            // confirmed candidate inherited the imported PDF. Reference
            // doesn't carry that field anymore — the PDF carry-through is now
            // routed through `MetadataPersistenceOptions.preferredPDFPath`
            // (resolved by the caller via `db.pdfFilename(for: fallbackId)`).
        }
        return ref
    }

    nonisolated static func assessManuallyConfirmedCandidate(
        _ candidate: MetadataCandidate,
        fallback: Reference?
    ) -> ManualCandidateImportAssessment {
        let reference = referenceFromCandidate(candidate, fallback: fallback)
        let titleReady = !reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let authorReady = !reference.authors.isEmpty
        let publicationReady = reference.year != nil
            || reference.journal?.rubien_nilIfBlank != nil
            || reference.publisher?.rubien_nilIfBlank != nil
        let abstractReady = reference.abstract?.rubien_nilIfBlank != nil
        let identifierReady = reference.doi?.rubien_nilIfBlank != nil
            || reference.isbn?.rubien_nilIfBlank != nil
            || reference.issn?.rubien_nilIfBlank != nil

        let canImportDirectly = titleReady && (
            (authorReady && publicationReady)
            || (authorReady && abstractReady)
            || (publicationReady && abstractReady)
            || identifierReady
        )

        let presentFields = [
            titleReady ? "Title" : nil,
            authorReady ? "Authors" : nil,
            publicationReady ? "Year/Journal/Publisher" : nil,
            abstractReady ? "Abstract" : nil,
            identifierReady ? "Identifier" : nil,
        ].compactMap { $0 }

        let missingFields = [
            titleReady ? nil : "Title",
            authorReady ? nil : "Authors",
            publicationReady ? nil : "Year/Journal/Publisher",
            abstractReady ? nil : "Abstract",
            identifierReady ? nil : "Identifier",
        ].compactMap { $0 }

        return ManualCandidateImportAssessment(
            reference: reference,
            canImportDirectly: canImportDirectly,
            presentFields: presentFields,
            missingFields: missingFields
        )
    }

    nonisolated private static func recordKey(for candidate: MetadataCandidate) -> String? {
        candidate.sourceRecordID?.rubien_nilIfBlank
    }

    nonisolated static func promoteManualCandidateSelectionResult(
        _ result: MetadataResolutionResult,
        reviewedBy: String
    ) -> MetadataResolutionResult {
        switch result {
        case .verified:
            return result
        case .candidate(let envelope):
            guard let evidence = envelope.evidence,
                  let reference = envelope.currentReference ?? envelope.fallbackReference else {
                return result
            }
            let manual = MetadataVerifier.manuallyVerified(reference, evidence: evidence, reviewedBy: reviewedBy)
            return .verified(VerifiedEnvelope(reference: manual, evidence: evidence))
        case .rejected(let envelope):
            guard let evidence = envelope.evidence,
                  let reference = envelope.currentReference ?? envelope.fallbackReference else {
                return result
            }
            let manual = MetadataVerifier.manuallyVerified(reference, evidence: evidence, reviewedBy: reviewedBy)
            return .verified(VerifiedEnvelope(reference: manual, evidence: evidence))
        case .seedOnly(let envelope):
            guard let evidence = envelope.evidence,
                  let reference = envelope.currentReference ?? envelope.fallbackReference else {
                return result
            }
            let manual = MetadataVerifier.manuallyVerified(reference, evidence: evidence, reviewedBy: reviewedBy)
            return .verified(VerifiedEnvelope(reference: manual, evidence: evidence))
        case .blocked:
            return result
        }
    }

    // MARK: - Evidence builder

    private func buildGenericEvidence(
        for reference: Reference,
        fetchMode: FetchMode,
        origin: EvidenceOrigin,
        recordKey: String?,
        exactIdentifierMatch: Bool
    ) -> EvidenceBundle {
        var fields: [FieldEvidence] = [FieldEvidence(field: "title", value: reference.title, origin: origin)]
        if !reference.authors.isEmpty {
            fields.append(FieldEvidence(field: "authors", value: reference.authors.displayString, origin: origin))
        }
        if let year = reference.year {
            fields.append(FieldEvidence(field: "year", value: String(year), origin: origin))
        }
        if let journal = reference.journal?.rubien_nilIfBlank {
            fields.append(FieldEvidence(field: "journal", value: journal, origin: origin))
        }
        if let pages = reference.pages?.rubien_nilIfBlank {
            fields.append(FieldEvidence(field: "pages", value: pages, origin: origin))
        }
        if let doi = reference.doi?.rubien_nilIfBlank {
            fields.append(FieldEvidence(field: "doi", value: doi, origin: origin))
        }
        if let isbn = reference.isbn?.rubien_nilIfBlank {
            fields.append(FieldEvidence(field: "isbn", value: isbn, origin: origin))
        }
        if let institution = reference.institution?.rubien_nilIfBlank {
            fields.append(FieldEvidence(field: "institution", value: institution, origin: origin))
        }
        if let thesisType = reference.genre?.rubien_nilIfBlank {
            fields.append(FieldEvidence(field: "thesisType", value: thesisType, origin: origin))
        }

        return EvidenceBundle(
            source: reference.metadataSource ?? .translationServer,
            recordKey: recordKey,
            sourceURL: reference.url,
            fetchMode: fetchMode,
            fieldEvidence: fields,
            verificationHints: VerificationHints(
                hasStructuredTitle: !reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasStructuredAuthors: !reference.authors.isEmpty,
                hasStructuredJournal: reference.journal?.rubien_nilIfBlank != nil,
                hasStructuredInstitution: reference.institution?.rubien_nilIfBlank != nil,
                hasStructuredPages: reference.pages?.rubien_nilIfBlank != nil,
                hasStructuredThesisType: reference.genre?.rubien_nilIfBlank != nil,
                hasStableRecordKey: recordKey?.rubien_nilIfBlank != nil,
                usedIdentifierFetch: fetchMode == .identifier,
                exactIdentifierMatch: exactIdentifierMatch
            )
        )
    }

    // MARK: - Small utilities

    private func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension MetadataResolver {
    /// Builds a CandidateEnvelope for the no-author safeguard path. Called
    /// from resolveIdentifierLocally's catch handler when PaperURLResolver
    /// throws .noAuthorsAvailable.
    nonisolated static func candidateEnvelopeForNoAuthors(
        partialRef: Reference,
        seed: MetadataResolutionSeed?,
        fallback: Reference?
    ) -> CandidateEnvelope {
        let candidate = MetadataCandidate(
            source: partialRef.metadataSource ?? .publisherCitationMeta,
            title: partialRef.title,
            authors: partialRef.authors,
            journal: partialRef.journal,
            publisher: partialRef.publisher,
            year: partialRef.year,
            detailURL: partialRef.url ?? "",
            // Score 1.0 — direct-source URL, no competing candidates, single
            // entry list. The user is reviewing because authors are missing,
            // not because of low confidence in the match. < candidateThreshold
            // (0.52) would render as a misleading "50% match" in the UI.
            score: 1.0,
            snippet: partialRef.abstract,
            workKind: .unknown,
            referenceType: partialRef.referenceType,
            isbn: partialRef.isbn,
            issn: partialRef.issn,
            sourceRecordID: partialRef.doi
        )
        return CandidateEnvelope(
            seed: seed,
            fallbackReference: fallback,
            currentReference: partialRef,
            candidates: [candidate],
            message: "Found a paper, but no authors are listed on the page or in CrossRef. Review before importing.",
            evidence: nil
        )
    }
}
#endif
