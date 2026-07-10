import Foundation

private let metadataResolutionPipelineLog = RubienLogger(
    subsystem: "com.rubien.metadata",
    category: "resolution.imported-pdf"
)

/// Resolution pipeline used when a PDF import supplies only extracted file
/// metadata. Keeping this flow in RubienCore gives every front door the same
/// verification and pending-intake behavior without introducing a Core →
/// PDFKit dependency.
public enum MetadataResolutionPipeline {
    public static func resolve(
        seed: MetadataResolutionSeed,
        fallback: Reference?
    ) async -> MetadataResolutionResult {
        if let doi = seed.doi?.rubien_nilIfBlank {
            let result = await resolveIdentifier(.doi(doi), seed: seed, fallback: fallback)
            if shouldReturnImmediately(result) { return result }
        }

        if let isbn = seed.isbn?.rubien_nilIfBlank {
            let result = await resolveIdentifier(.isbn(isbn), seed: seed, fallback: fallback)
            if shouldReturnImmediately(result) { return result }
        }

        if seed.workKindHint == .book,
           seed.isbn == nil,
           let title = seed.title?.rubien_nilIfBlank,
           let bookReference = try? await MetadataFetcher.searchBookByTitle(title) {
            let evidence = buildGenericEvidence(
                for: bookReference,
                fetchMode: .identifier,
                origin: .identifierAPI,
                recordKey: bookReference.isbn?.rubien_nilIfBlank,
                exactIdentifierMatch: false
            )
            let result = verifyFetchedRecord(
                AuthoritativeMetadataRecord(reference: bookReference, evidence: evidence),
                seed: seed,
                fallback: fallback,
                defaultRejectMessage: "Book title search matched, but auto-verification rules were not met."
            )
            if shouldReturnImmediately(result) { return result }
        }

        if let title = seed.title?.rubien_nilIfBlank,
           let titleResult = await resolveByTitle(title, seed: seed, fallback: fallback) {
            return titleResult
        }

        return .seedOnly(
            IntakeEnvelope(
                seed: seed,
                fallbackReference: fallback,
                message: "No authoritative metadata matched; keeping local attachment and seed only."
            )
        )
    }

    private enum Identifier {
        case doi(String)
        case isbn(String)
    }

    private static func shouldReturnImmediately(_ result: MetadataResolutionResult) -> Bool {
        switch result {
        case .verified, .candidate, .blocked:
            return true
        case .seedOnly, .rejected:
            return false
        }
    }

    private static func resolveIdentifier(
        _ identifier: Identifier,
        seed: MetadataResolutionSeed,
        fallback: Reference?
    ) async -> MetadataResolutionResult {
        do {
            let reference: Reference
            switch identifier {
            case .doi(let value):
                reference = try await MetadataFetcher.fetchFromDOI(value)
            case .isbn(let value):
                reference = try await MetadataFetcher.fetchFromISBN(value)
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
            return verifyFetchedRecord(
                AuthoritativeMetadataRecord(reference: reference, evidence: evidence),
                seed: seed,
                fallback: fallback,
                defaultRejectMessage: "Identifier matched, but auto-verification rules were not met."
            )
        } catch {
            metadataResolutionPipelineLog.error(
                "Imported PDF identifier resolution failed: \(error.localizedDescription)"
            )
            return .rejected(
                RejectedEnvelope(
                    seed: seed,
                    fallbackReference: fallback,
                    currentReference: fallback,
                    reason: .insufficientEvidence,
                    message: error.localizedDescription
                )
            )
        }
    }

    private static func resolveByTitle(
        _ title: String,
        seed: MetadataResolutionSeed,
        fallback: Reference?
    ) async -> MetadataResolutionResult? {
        guard let fetched = try? await MetadataFetcher.fetchFromOpenAlexByTitle(title) else {
            return nil
        }
        let titleScore = MetadataResolution.titleSimilarity(title, fetched.title)
        guard titleScore >= 0.80 else { return nil }

        var enriched = fetched
        if (enriched.abstract ?? "").isEmpty,
           let doi = enriched.doi,
           !doi.isEmpty,
           let abstract = try? await MetadataFetcher.fetchAbstractFromSemanticScholar(doi: doi) {
            enriched.abstract = abstract
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

    private static func verifyFetchedRecord(
        _ record: AuthoritativeMetadataRecord,
        seed: MetadataResolutionSeed,
        fallback: Reference?,
        defaultRejectMessage: String
    ) -> MetadataResolutionResult {
        let decision = MetadataVerifier.verify(reference: record.reference, seed: seed, evidence: record.evidence)
        switch decision {
        case .verified(let envelope):
            let mergedReference = fallback.map {
                MetadataResolution.mergeReference(primary: envelope.reference, fallback: $0)
            } ?? envelope.reference
            return .verified(VerifiedEnvelope(reference: mergedReference, evidence: envelope.evidence))

        case .candidate(let envelope):
            let current = fallback.map {
                MetadataResolution.mergeReference(primary: envelope.currentReference ?? record.reference, fallback: $0)
            } ?? envelope.currentReference ?? record.reference
            return .candidate(
                CandidateEnvelope(
                    seed: envelope.seed,
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
                    seed: envelope.seed,
                    fallbackReference: fallback ?? envelope.fallbackReference,
                    currentReference: envelope.currentReference ?? record.reference,
                    candidates: envelope.candidates,
                    reason: envelope.reason,
                    message: envelope.message,
                    evidence: envelope.evidence ?? record.evidence
                )
            )

        case .rejected(let envelope):
            let mergedCurrent = fallback.map {
                MetadataResolution.mergeReference(primary: envelope.currentReference ?? record.reference, fallback: $0)
            } ?? envelope.currentReference ?? record.reference
            return .rejected(
                RejectedEnvelope(
                    seed: envelope.seed,
                    fallbackReference: fallback ?? envelope.fallbackReference,
                    currentReference: mergedCurrent,
                    reason: envelope.reason,
                    message: envelope.message.isEmpty ? defaultRejectMessage : envelope.message,
                    evidence: envelope.evidence ?? record.evidence
                )
            )
        }
    }

    private static func buildGenericEvidence(
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

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
