import Foundation

/// Removes written hesitation sounds while retaining the original speech clock.
struct FillerWordFilter: Sendable {
    private static let sounds = #"u+h+m*|u+m+|e+r+m+|e+r{2,}|e+h+|h+m+|m{2,}|m+h+|a+h+|a{3,}"#
    private static let word = #"\p{L}\p{M}\p{N}_@'’\-"#
    private static let candidates = try! NSRegularExpression(
        pattern: #"(?<!["# + word + #"])(?:"# + sounds + #"|a(?=[,–—]))(?!["# + word + #"])"#,
        options: .caseInsensitive
    )
    private static let openQuote = CharacterSet(charactersIn: "\"'“‘([{")
    private static let horizontal = CharacterSet.whitespaces
    private static let gloss = ["(": ")", "[": "]", "{": "}"]
    private static let closers = CharacterSet(charactersIn: "\"'”’)]}")
    private static let pauses = CharacterSet(charactersIn: ",;:–—")
    private static let endings = CharacterSet(charactersIn: ".!?…")

    func apply(to transcript: Transcript) -> Transcript {
        var contexts: [AudioSource: Context] = [:]
        let segments = transcript.segments.compactMap { segment -> TranscriptSegment? in
            guard !segment.wasUserEdited else { return segment }
            let initial = contexts[segment.source, default: Context()]
            let cleaned = Self.clean(segment.text, context: initial)
            if !segment.isEchoDuplicate { contexts[segment.source] = cleaned.context }
            guard !cleaned.edits.isEmpty else { return segment }
            guard !cleaned.text.isEmpty else { return nil }
            var result = segment
            result.text = cleaned.text
            // Recognizer word spans are strings joined by spaces. Associate
            // surviving text with its original span before changing any text.
            if segment.words.map(\.text).joined(separator: " ") == segment.text {
                result.words = Self.timedWords(segment.words, edits: cleaned.edits, text: cleaned.text)
                if let first = result.words.first, let last = result.words.last {
                    result.start = first.start
                    result.end = last.end
                }
            }
            return result
        }
        return Transcript(schemaVersion: transcript.schemaVersion, segments: segments)
    }

    static func clean(_ text: String) -> String {
        clean(text, context: .init()).text
    }

    private struct Context {
        var atSentenceStart = true
        var promoteNextWord = false
    }

    private struct Edit {
        let range: NSRange
        let replacement: String
        var isRemoval = true
    }

    private static func clean(_ text: String, context initial: Context)
        -> (text: String, edits: [Edit], context: Context)
    {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = candidates.matches(in: text, range: fullRange)
        var edits: [Edit] = []
        var cursor = 0
        var sentenceStart = initial.atSentenceStart
        var lastOutput: Character?

        for match in matches {
            var start = match.range.location
            var end = NSMaxRange(match.range)
            guard start >= cursor else { continue }

            // Keep a bare article, letter, unit, or a label such as “Plan A”.
            // Treat “a” as hesitation only at a boundary with a marked pause.
            let leading = source.substring(with: NSRange(location: cursor, length: start - cursor))
            let startsSentence = isSentenceStart(after: leading, initial: sentenceStart)
            let after = character(in: source, at: end)
            let token = source.substring(with: match.range)
            if token.lowercased() == "a", !startsSentence { continue }
            if token.lowercased() == "mm", leading.last(where: { !$0.isWhitespace })?.isNumber == true { continue }
            if after == ".", let next = character(in: source, at: end + 1),
               next.isLetter || next.isNumber { continue } // domains, initialisms

            var wrapperStart = start
            var wrapperEnd = end
            while wrapperStart > cursor, contains(horizontal, character(in: source, at: wrapperStart - 1)) { wrapperStart -= 1 }
            while contains(horizontal, character(in: source, at: wrapperEnd)) { wrapperEnd += 1 }
            if let opener = character(in: source, at: wrapperStart - 1).map(String.init),
               let closer = gloss[opener], character(in: source, at: wrapperEnd).map(String.init) == closer {
                start = wrapperStart - 1
                end = wrapperEnd + 1
            }

            while start > cursor, contains(horizontal, character(in: source, at: start - 1)) { start -= 1 }
            // Remove a paired interruption comma/dash owned by the filler.
            // At a normal list boundary the first comma still separates the
            // surrounding items.
            let prior = character(in: source, at: start - 1)
            let interrupting = prior == "," || prior == "—" || prior == "–"
            var punctuation = ""
            var scan = end
            while contains(horizontal, character(in: source, at: scan)) { scan += 1 }
            let punctuationStart = scan
            while let next = character(in: source, at: scan),
                  contains(pauses, next) || contains(endings, next) {
                if contains(endings, next) { punctuation.append(next) }
                scan += 1
            }
            let consumedPunctuation = scan > punctuationStart
            if consumedPunctuation {
                end = scan
                while contains(horizontal, character(in: source, at: end)) { end += 1 }
            } else {
                end = scan
            }
            if interrupting, consumedPunctuation {
                let followingPause = character(in: source, at: scan - 1)
                if !punctuation.isEmpty || followingPause == prior { start -= 1 }
            }

            let kept = source.substring(with: NSRange(location: cursor, length: start - cursor))
            lastOutput = kept.last ?? lastOutput
            let ending = startsSentence ? "" : punctuation
            let following = character(in: source, at: end)
            let join = lastOutput?.isWhitespace == false && !contains(openQuote, lastOutput)
                && following.map { $0.isLetter || $0.isNumber || "(\"“‘".contains($0) } == true
            let replacement = ending + (join ? " " : "")
            edits.append(Edit(range: NSRange(location: start, length: end - start), replacement: replacement))
            lastOutput = replacement.last ?? lastOutput
            sentenceStart = isSentenceStart(after: replacement, initial: startsSentence)
            cursor = end
        }

        // Case follows the surviving speech, including a continuation into
        // the next block after an entire filler-only block was removed.
        var capitals: [Edit] = []
        var previousEnd = 0
        var state = initial
        for edit in edits {
            let kept = source.substring(with: NSRange(location: previousEnd, length: edit.range.location - previousEnd))
            updateCapitalization(in: kept, offset: previousEnd, context: &state, edits: &capitals)
            state.atSentenceStart = isSentenceStart(after: edit.replacement, initial: state.atSentenceStart)
            state.promoteNextWord = state.atSentenceStart
            previousEnd = NSMaxRange(edit.range)
        }
        updateCapitalization(in: source.substring(from: previousEnd), offset: previousEnd, context: &state, edits: &capitals)
        let allEdits = (edits + capitals).sorted { $0.range.location < $1.range.location }
        guard !allEdits.isEmpty else { return (text, [], state) }
        let updated = NSMutableString(string: text)
        for edit in allEdits.reversed() { updated.replaceCharacters(in: edit.range, with: edit.replacement) }
        var cleaned = (updated as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.contains(where: { $0.isLetter || $0.isNumber || $0.isSymbol }) { cleaned = "" }
        return (cleaned, allEdits, state)
    }

    private static func timedWords(_ words: [TranscriptWord], edits: [Edit], text: String) -> [TranscriptWord] {
        var offset = 0
        var editIndex = 0
        var kept: [TranscriptWord] = []
        for word in words {
            let end = offset + word.text.utf16.count
            while editIndex < edits.count, NSMaxRange(edits[editIndex].range) <= offset { editIndex += 1 }
            let removal = edits.dropFirst(editIndex).prefix { $0.range.location < end }.contains {
                $0.isRemoval && $0.range.location <= offset && NSMaxRange($0.range) >= end
            }
            if !removal { kept.append(word) }
            offset = end + 1
        }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard kept.count == parts.count else {
            // Keep the valid segment time when a compact token (e.g. um,hello)
            // cannot be represented as a one-to-one word rewrite.
            return []
        }
        return zip(kept, parts).map { word, part in
            var updated = word
            updated.text = String(part)
            return updated
        }
    }

    private static func updateCapitalization(in text: String, offset: Int, context: inout Context, edits: inout [Edit]) {
        context.atSentenceStart = isSentenceStart(after: text, initial: context.atSentenceStart)
        guard context.promoteNextWord, let index = text.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return }
        context.promoteNextWord = false
        let endOfWord = text[index...].firstIndex { !$0.isLetter } ?? text.endIndex
        guard index < endOfWord else { return }
        let first = text[index]
        // Preserve deliberate casing such as iPhone or eBay.
        guard !text[text.index(after: index)..<endOfWord].contains(where: \.isUppercase) else { return }
        let capital = first.uppercased()
        guard capital != String(first) else { return }
        let range = NSRange(index..<text.index(after: index), in: text)
        edits.append(Edit(range: NSRange(location: offset + range.location, length: range.length), replacement: capital, isRemoval: false))
    }

    private static func isSentenceStart(after text: String, initial: Bool) -> Bool {
        if text.last(where: { !$0.isWhitespace || $0.isNewline })?.isNewline == true { return true }
        let last = text.unicodeScalars.last { !CharacterSet.whitespacesAndNewlines.contains($0)
            && !closers.contains($0) && !openQuote.contains($0) }
        return last.map(endings.contains) ?? initial
    }

    private static func character(in source: NSString, at index: Int) -> Character? {
        guard index >= 0, index < source.length,
              let scalar = UnicodeScalar(source.character(at: index)) else { return nil }
        return Character(scalar)
    }

    private static func contains(_ set: CharacterSet, _ character: Character?) -> Bool {
        character?.unicodeScalars.first.map(set.contains) ?? false
    }
}
