#if os(macOS)
/// Turns a speech analyzer's results into the whole transcript so far.
///
/// The analyzer reports each stretch of audio first as volatile results, each
/// replacing the last guess for that stretch, then once as a final result. Final
/// text is kept; volatile text is the tail after it. Segment text keeps the
/// recognizer's own spacing.
struct AnalyzerTranscriptAccumulator {
    private(set) var finalized = ""
    private(set) var volatile = ""

    var transcript: String { finalized + volatile }

    /// Applies one result. Returns whether the transcript changed.
    @discardableResult
    mutating func apply(text: String, isFinal: Bool) -> Bool {
        let previous = transcript
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        return transcript != previous
    }
}
#endif
