import Foundation

public enum MetadataVerifier {
    public static func verify(
        reference: Reference,
        seed: MetadataResolutionSeed?,
        evidence: EvidenceBundle
    ) -> MetadataVerificationDecision {
        switch reference.referenceType {
        case .thesis:
            return verifyThesis(reference: reference, seed: seed, evidence: evidence)
        case .book, .bookSection:
            return verifyBook(reference: reference, seed: seed, evidence: evidence)
        default:
            return verifyJournalLike(reference: reference, seed: seed, evidence: evidence)
        }
    }

    public static func manuallyVerified(
        _ reference: Reference,
        evidence: EvidenceBundle? = nil,
        reviewedBy: String?
    ) -> Reference {
        var manual = reference
        if let evidence = evidence {
            manual.metadataSource = evidence.source
            manual.recordKey = evidence.recordKey?.rubien_nilIfBlank ?? manual.recordKey
            manual.verificationSourceURL = evidence.sourceURL?.rubien_nilIfBlank ?? manual.verificationSourceURL
            manual.evidenceBundleHash = evidence.bundleHash ?? manual.evidenceBundleHash
        }
        manual.verificationStatus = .verifiedManual
        manual.acceptedByRuleID = nil
        manual.evidenceBundleHash = manual.evidenceBundleHash ?? MetadataVerificationCodec.sha256Hex(for: reference)
        manual.verifiedAt = Date()
        manual.reviewedBy = reviewedBy?.rubien_nilIfBlank ?? "manual-review"
        return manual
    }

    private static func verifyJournalLike(
        reference: Reference,
        seed: MetadataResolutionSeed?,
        evidence: EvidenceBundle
    ) -> MetadataVerificationDecision {
        let title = normalized(reference.title)
        guard !title.isEmpty else {
            return .rejected(
                RejectedEnvelope(
                    seed: seed,
                    fallbackReference: nil,
                    currentReference: reference,
                    reason: .insufficientEvidence,
                    message: "Missing a verifiable title.",
                    evidence: evidence
                )
            )
        }

        let titleScore = MetadataResolution.titleSimilarity(seed?.title ?? "", reference.title)
        let firstAuthorExact = authorsMatch(seed?.firstAuthor, reference.authors.first?.displayName)
        let yearExact = seed?.year != nil && seed?.year == reference.year
        let journalExact = journalMatch(seed?.journal, reference.journal)
        let doiExact = identifierMatch(seed?.doi, reference.doi)
        let recordKeyPresent = evidence.recordKey?.rubien_nilIfBlank != nil || evidence.verificationHints.hasStableRecordKey

        if doiExact && titleScore >= 0.92 && (yearExact || firstAuthorExact) {
            return .verified(verifiedEnvelope(reference, evidence: evidence, rule: .j1DOIExact))
        }

        if recordKeyPresent
            && (evidence.verificationHints.usedStructuredExport || evidence.verificationHints.usedStructuredDetail)
            && titleScore >= 0.90
            && firstAuthorExact
            && yearExact
            && journalExact {
            return .verified(verifiedEnvelope(reference, evidence: evidence, rule: .j2SourceRecordKey))
        }

        if evidence.verificationHints.competingCandidateCount > 1 {
            return .candidate(
                CandidateEnvelope(
                    seed: seed,
                    fallbackReference: nil,
                    currentReference: reference,
                    candidates: [],
                    message: "Multiple candidates matched; manual review required.",
                    evidence: evidence
                )
            )
        }

        return .rejected(
            RejectedEnvelope(
                seed: seed,
                fallbackReference: nil,
                currentReference: reference,
                reason: .verifierRuleNotSatisfied,
                message: "Did not meet journal auto-verification rules.",
                evidence: evidence
            )
        )
    }

    private static func verifyThesis(
        reference: Reference,
        seed: MetadataResolutionSeed?,
        evidence: EvidenceBundle
    ) -> MetadataVerificationDecision {
        let recordKeyPresent = evidence.recordKey?.rubien_nilIfBlank != nil || evidence.verificationHints.hasStableRecordKey
        let titleScore = MetadataResolution.titleSimilarity(seed?.title ?? "", reference.title)
        let authorExact = authorsMatch(seed?.firstAuthor, reference.authors.first?.displayName)
        let institutionExact = normalized(seed?.publisher ?? "") == normalized(reference.institution ?? "")
            || normalized(seed?.journal ?? "") == normalized(reference.institution ?? "")
            || evidence.verificationHints.hasStructuredInstitution
        let yearExact = seed?.year != nil && seed?.year == reference.year
        let thesisTypePresent = reference.genre?.rubien_nilIfBlank != nil || evidence.verificationHints.hasStructuredThesisType

        if recordKeyPresent && titleScore >= 0.90 && authorExact && institutionExact && yearExact && thesisTypePresent {
            return .verified(verifiedEnvelope(reference, evidence: evidence, rule: .t1ThesisSourceKey))
        }

        return .rejected(
            RejectedEnvelope(
                seed: seed,
                fallbackReference: nil,
                currentReference: reference,
                reason: .verifierRuleNotSatisfied,
                message: "Did not meet thesis auto-verification rules.",
                evidence: evidence
            )
        )
    }

    private static func verifyBook(
        reference: Reference,
        seed: MetadataResolutionSeed?,
        evidence: EvidenceBundle
    ) -> MetadataVerificationDecision {
        let hasISBN = identifierMatch(seed?.isbn, reference.isbn)
        let recordKeyPresent = evidence.recordKey?.rubien_nilIfBlank != nil || evidence.verificationHints.hasStableRecordKey
        let titleScore = MetadataResolution.titleSimilarity(seed?.title ?? "", reference.title)
        let publisherExact = normalized(seed?.publisher ?? "") == normalized(reference.publisher ?? "")
            || evidence.fieldValue("publisher")?.rubien_nilIfBlank != nil
        let yearExact = seed?.year != nil && seed?.year == reference.year

        if (hasISBN || recordKeyPresent) && titleScore >= 0.90 && publisherExact && yearExact {
            return .verified(verifiedEnvelope(reference, evidence: evidence, rule: .b1ISBNOrRecordKey))
        }

        return .rejected(
            RejectedEnvelope(
                seed: seed,
                fallbackReference: nil,
                currentReference: reference,
                reason: .verifierRuleNotSatisfied,
                message: "Did not meet book auto-verification rules.",
                evidence: evidence
            )
        )
    }

    private static func verifiedEnvelope(
        _ reference: Reference,
        evidence: EvidenceBundle,
        rule: AcceptedRuleID
    ) -> VerifiedEnvelope {
        var verified = reference
        verified.verificationStatus = .verifiedAuto
        verified.acceptedByRuleID = rule.rawValue
        verified.recordKey = evidence.recordKey
        verified.verificationSourceURL = evidence.sourceURL
        verified.metadataSource = evidence.source
        verified.evidenceBundleHash = evidence.bundleHash
        verified.verifiedAt = Date()
        return VerifiedEnvelope(reference: verified, evidence: evidence)
    }

    private static func authorsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    private static func identifierMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    private static func journalMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = normalized(MetadataResolution.normalizeJournalName(lhs) ?? lhs)
        let right = normalized(MetadataResolution.normalizeJournalName(rhs) ?? rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    private static func normalized(_ value: String?) -> String {
        MetadataResolution.normalizedComparableText(value ?? "")
    }
}
