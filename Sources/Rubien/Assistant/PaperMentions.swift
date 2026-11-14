import Foundation

/// The `@…` span currently being edited in the Assistant composer. Its range is
/// valid only for the exact `String` passed to `activeQuery`.
struct PaperMentionQuery: Equatable {
    let range: Range<String.Index>
    let text: String
}

/// One user-selected mention instance. Character offsets let the composer update
/// identity deterministically as edits shift/delete tokens; the stable reference
/// ID never has to be reconstructed from a potentially ambiguous title substring.
struct PaperMentionSelection: Equatable, Sendable {
    let reference: ChatReference
    var range: Range<Int>
}

struct PaperMentionCompletion: Equatable {
    let text: String
    let caretOffset: Int
    let mentionRange: Range<Int>
}

/// Pure parsing/replacement rules for paper mentions. Keeping these independent
/// of SwiftUI/AppKit makes the fiddly cursor and boundary behavior unit-testable.
enum PaperMentions {
    static let maximumQueryLength = 120
    static let maximumMentionsPerTurn = 20

    /// Returns the mention ending at `caret`, if any. An `@` can follow any
    /// character, including adjacent prose in languages that do not use spaces.
    /// Queries may contain spaces for multi-word paper titles. Email addresses
    /// can also open suggestions; only an explicit selection creates a mention.
    static func activeQuery(
        in text: String,
        caret: String.Index,
        completed selections: [PaperMentionSelection] = []
    ) -> PaperMentionQuery? {
        guard caret >= text.startIndex, caret <= text.endIndex else { return nil }
        let prefix = text[..<caret]
        let lineStart = prefix.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        guard let at = prefix.lastIndex(of: "@"), at >= lineStart else { return nil }

        let queryStart = text.index(after: at)
        let raw = String(text[queryStart..<caret])
        guard raw.count <= maximumQueryLength, !raw.contains("@") else { return nil }

        let atOffset = text.distance(from: text.startIndex, to: at)
        let caretOffset = text.distance(from: text.startIndex, to: caret)
        for selection in selections where tokenMatches(selection, in: text) {
            if atOffset > selection.range.lowerBound,
               atOffset < selection.range.upperBound {
                return nil  // an `@` that is part of the selected paper's title
            }
            if atOffset == selection.range.lowerBound,
               caretOffset >= selection.range.upperBound {
                return nil  // caret has moved past this completed mention
            }
        }

        return PaperMentionQuery(range: at..<caret, text: raw)
    }

    /// Replaces the active `@query` and returns both the new caret and the exact
    /// selected-token range as character offsets.
    static func completing(
        _ query: PaperMentionQuery,
        with reference: ChatReference,
        in text: String
    ) -> PaperMentionCompletion {
        let startOffset = text.distance(from: text.startIndex, to: query.range.lowerBound)
        let token = token(for: reference)
        let replacement = token + " "
        var result = text
        result.replaceSubrange(query.range, with: replacement)
        return PaperMentionCompletion(
            text: result,
            caretOffset: startOffset + replacement.count,
            mentionRange: startOffset..<(startOffset + token.count)
        )
    }

    /// Applies the single contiguous edit between two composer snapshots to every
    /// selected token. Edits before a token shift it; edits inside it remove its
    /// identity; unaffected tokens are validated byte-for-visible-character against
    /// their selected reference before they survive.
    static func reconciling(
        _ selections: [PaperMentionSelection],
        from oldText: String,
        to newText: String
    ) -> [PaperMentionSelection] {
        guard oldText != newText else {
            return selections.filter { tokenMatches($0, in: newText) }
        }
        let old = Array(oldText)
        let new = Array(newText)
        let commonLimit = min(old.count, new.count)
        var prefixCount = 0
        while prefixCount < commonLimit, old[prefixCount] == new[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < old.count - prefixCount,
              suffixCount < new.count - prefixCount,
              old[old.count - suffixCount - 1] == new[new.count - suffixCount - 1] {
            suffixCount += 1
        }

        let oldChanged = prefixCount..<(old.count - suffixCount)
        let newChangedCount = new.count - prefixCount - suffixCount
        let delta = newChangedCount - oldChanged.count

        return selections.compactMap { selection in
            var adjusted = selection
            if oldChanged.isEmpty {
                if oldChanged.lowerBound <= selection.range.lowerBound {
                    adjusted.range = shifted(selection.range, by: delta)
                } else if oldChanged.lowerBound < selection.range.upperBound {
                    return nil
                }
            } else if oldChanged.upperBound <= selection.range.lowerBound {
                adjusted.range = shifted(selection.range, by: delta)
            } else if oldChanged.lowerBound < selection.range.upperBound,
                      oldChanged.upperBound > selection.range.lowerBound {
                return nil
            }
            return tokenMatches(adjusted, in: newText) ? adjusted : nil
        }
    }

    /// Brings selections that were last reconciled against `reconciledText` up to
    /// date with `text`. The composer reconciles in a deferred `onChange`, so an
    /// edit and a send handled in the same run-loop turn would otherwise send
    /// ranges that are one edit behind, and the send-time check would drop them.
    static func updating(
        _ selections: [PaperMentionSelection],
        reconciledAgainst reconciledText: String,
        to text: String
    ) -> [PaperMentionSelection] {
        reconciledText == text
            ? selections
            : reconciling(selections, from: reconciledText, to: text)
    }

    /// Whether `selection` is a caret sitting exactly at the end of a selected
    /// mention that is still present in `text`. Dictation there must start with
    /// a space: a letter appended to the title drops the mention, and Han
    /// characters are letters that normally take no space.
    static func caretEndsMention(
        _ selection: Range<Int>?,
        in text: String,
        mentions: [PaperMentionSelection]
    ) -> Bool {
        guard let selection, selection.isEmpty else { return false }
        return mentions.contains {
            $0.range.upperBound == selection.lowerBound && tokenMatches($0, in: text)
        }
    }

    /// Final send-time defense: exact ranges must still contain their selected
    /// tokens. IDs are deduplicated and capped to the manifest's shared limit.
    static func selectionsStillPresent(
        in text: String,
        from selections: [PaperMentionSelection]
    ) -> [PaperMentionSelection] {
        var ids = Set<Int64>()
        return selections.filter {
            guard $0.reference.id > 0, tokenMatches($0, in: text) else { return false }
            return ids.insert($0.reference.id).inserted
        }.prefix(maximumMentionsPerTurn).map { $0 }
    }

    static func token(for reference: ChatReference) -> String {
        "@" + AssistantContext.sanitizeSeedField(
            reference.title,
            fallback: "Untitled",
            maxLength: 200
        )
    }

    private static func shifted(_ range: Range<Int>, by delta: Int) -> Range<Int> {
        (range.lowerBound + delta)..<(range.upperBound + delta)
    }

    private static func tokenMatches(_ selection: PaperMentionSelection, in text: String) -> Bool {
        guard selection.range.lowerBound >= 0,
              selection.range.upperBound <= text.count,
              selection.range.lowerBound <= selection.range.upperBound
        else { return false }
        let lower = text.index(text.startIndex, offsetBy: selection.range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: selection.range.upperBound)
        guard String(text[lower..<upper]) == token(for: selection.reference) else { return false }
        return upper == text.endIndex || !isTokenContinuation(text[upper])
    }

    private static func isTokenContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }
}
