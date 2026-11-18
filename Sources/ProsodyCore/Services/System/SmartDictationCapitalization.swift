import ApplicationServices
import Foundation

/// A bounded prefix of the focused field immediately before the insertion
/// caret. `hasCompletePrefix` means the read began at UTF-16 offset zero.
struct SmartDictationTextContext: Equatable, Sendable {
    let precedingText: String
    let hasCompletePrefix: Bool
}

/// AX access is isolated behind this small surface so unit tests can exercise
/// the policy without a live application. Production uses the live accessors.
@MainActor
struct SmartDictationAXAccess {
    let attribute: @MainActor (AXUIElement, String) -> CFTypeRef?
    let stringForRange: @MainActor (AXUIElement, CFRange) -> String?

    static let live = Self(
        attribute: { element, name in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
                return nil
            }
            return value
        },
        stringForRange: { element, range in
            var request = range
            guard let rangeValue = AXValueCreate(.cfRange, &request) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &value
            ) == .success else { return nil }
            return value as? String
        }
    )
}

@MainActor
enum SmartDictationAXContextReader {
    /// Keep AX IPC small. A larger field can still be transformed when this
    /// window contains a sentence boundary; otherwise the text is left alone.
    static let maximumPrefixUTF16Count = 512
    /// The value fallback is only considered after AX reports a small field.
    static let maximumFallbackValueUTF16Count = 2_048

    static func context(
        from element: AXUIElement,
        selection: CFRange
    ) -> SmartDictationTextContext? {
        context(from: element, selection: selection, access: .live)
    }

    static func context(
        from element: AXUIElement,
        selection: CFRange,
        access: SmartDictationAXAccess
    ) -> SmartDictationTextContext? {
        guard selection.location >= 0, selection.length >= 0 else { return nil }
        guard isSupportedTextControl(element, access: access),
              !isSecure(element, access: access) else { return nil }
        guard let current = range(from: access.attribute(element, kAXSelectedTextRangeAttribute)),
              current.location == selection.location,
              current.length == selection.length else { return nil }
        return readContext(from: element, selection: selection, access: access)
    }

    /// The caller has already verified focus, security, and the live selection.
    /// This path still checks the role before reading any field text.
    static func readValidatedContext(
        from element: AXUIElement,
        selection: CFRange,
        access: SmartDictationAXAccess
    ) -> SmartDictationTextContext? {
        guard selection.location >= 0, selection.length >= 0,
              isSupportedTextControl(element, access: access) else { return nil }
        return readContext(from: element, selection: selection, access: access)
    }

    private static func readContext(
        from element: AXUIElement,
        selection: CFRange,
        access: SmartDictationAXAccess
    ) -> SmartDictationTextContext? {
        let caret = selection.location
        guard caret > 0 else {
            return SmartDictationTextContext(precedingText: "", hasCompletePrefix: true)
        }

        let length = min(caret, maximumPrefixUTF16Count)
        let start = caret - length
        let request = CFRange(location: start, length: length)
        if let candidate = access.stringForRange(element, request),
           candidate.utf16.count == length {
            return SmartDictationTextContext(
                precedingText: candidate,
                hasCompletePrefix: start == 0
            )
        }

        // Some controls expose AXValue but not AXStringForRange. Read it only
        // after the reported field size proves that the value is bounded.
        guard let characterCount = integerAttribute(
            element, kAXNumberOfCharactersAttribute, access: access
        ),
        characterCount >= caret,
        characterCount <= maximumFallbackValueUTF16Count,
        let value = access.attribute(element, kAXValueAttribute) as? String,
        value.utf16.count >= caret else { return nil }

        let units = Array(value.utf16)
        let prefix = String(decoding: units[..<caret], as: UTF16.self)
        guard prefix.utf16.elementsEqual(units[..<caret]) else { return nil }
        return SmartDictationTextContext(precedingText: prefix, hasCompletePrefix: true)
    }

    private static func isSupportedTextControl(
        _ element: AXUIElement,
        access: SmartDictationAXAccess
    ) -> Bool {
        guard let role = access.attribute(element, kAXRoleAttribute) as? String else { return false }
        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }

    private static func isSecure(
        _ element: AXUIElement,
        access: SmartDictationAXAccess
    ) -> Bool {
        (access.attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }

    private static func integerAttribute(
        _ element: AXUIElement,
        _ name: String,
        access: SmartDictationAXAccess
    ) -> Int? {
        (access.attribute(element, name) as? NSNumber)?.intValue
    }

    private static func range(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetType(value as! AXValue) == .cfRange,
              AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

enum SmartDictationCapitalization {
    private enum ContextState {
        case sentenceStart
        case midSentence
        case uncertain
    }

    private struct FirstCasedScalar {
        let index: String.Index
        let scalar: Unicode.Scalar
    }

    private static let genericInitialWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those",
        "it", "we", "you", "they", "he", "she", "there", "here",
        "what", "when", "where", "why", "how", "who", "which",
        "if", "while", "because", "although", "though", "but", "and",
        "or", "so", "then", "also", "just", "only", "even", "still",
        "now", "today", "tomorrow", "yesterday",
        "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "can", "could",
        "shall", "should", "might", "must", "need", "needs", "want",
        "wants", "think", "know", "see", "look", "make", "makes",
        "use", "uses", "get", "gets", "go", "goes", "come", "comes",
        "let", "please"
    ]

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "mr", "mrs", "ms", "dr", "prof", "sr", "jr",
        "st", "vs", "etc", "inc", "ltd", "co", "fig", "vol", "approx",
        "dept", "est", "cf", "al", "a.m", "p.m"
    ]

    private static let trailingIgnorable: Set<Character> = [
        "\"", "'", "“", "”", "‘", "’", "(", ")", "[", "]", "{", "}",
        "«", "»", "‹", "›"
    ]
    private static let openingQuoteOrBracket: Set<Character> = [
        "\"", "'", "“", "‘", "(", "[", "{", "«", "‹"
    ]

    /// Applies the preference and AX bridge. A disabled toggle performs no AX
    /// read at all. Missing, mismatched, secure, or unsupported context returns
    /// the original text unchanged.
    @MainActor
    static func apply(
        to text: String,
        smartCapitalization: Bool,
        element: AXUIElement?,
        selection: CFRange?
    ) -> String {
        apply(
            to: text,
            smartCapitalization: smartCapitalization,
            element: element,
            selection: selection,
            access: .live
        )
    }

    @MainActor
    static func apply(
        to text: String,
        smartCapitalization: Bool,
        element: AXUIElement?,
        selection: CFRange?,
        access: SmartDictationAXAccess
    ) -> String {
        guard smartCapitalization, let element, let selection,
              let context = SmartDictationAXContextReader.context(
                from: element, selection: selection, access: access
              ) else { return text }
        return transform(text, context: context)
    }

    /// Used after destination validation. It avoids repeating the secure-field
    /// and selection checks while still restricting reads to supported text
    /// controls.
    @MainActor
    static func applyValidated(
        to text: String,
        smartCapitalization: Bool,
        element: AXUIElement?,
        selection: CFRange?,
        access: SmartDictationAXAccess
    ) -> String {
        guard smartCapitalization, let element, let selection,
              let context = SmartDictationAXContextReader.readValidatedContext(
                from: element, selection: selection, access: access
              ) else { return text }
        return transform(text, context: context)
    }

    /// Pure policy. Context is deliberately required: without a trustworthy
    /// prefix the caller must keep the original text.
    static func transform(_ text: String, context: SmartDictationTextContext) -> String {
        guard !text.isEmpty else { return text }
        let state = state(for: context)
        guard state != .uncertain, let first = firstCasedScalar(in: text) else { return text }

        switch state {
        case .sentenceStart:
            guard shouldCapitalizeInitialWord(in: text, firstCasedAt: first.index) else { return text }
            return replacing(first, in: text, with: String(first.scalar).uppercased())
        case .midSentence:
            guard shouldLowercaseInitialWord(in: text, firstCasedAt: first.index) else { return text }
            return replacing(first, in: text, with: String(first.scalar).lowercased())
        case .uncertain:
            return text
        }
    }

    private static func state(for context: SmartDictationTextContext) -> ContextState {
        let text = context.precedingText
        guard !text.isEmpty else { return .sentenceStart }
        if context.hasCompletePrefix,
           text.allSatisfy({ $0.isWhitespace || openingQuoteOrBracket.contains($0) }) {
            return .sentenceStart
        }
        guard let lastNonWhitespace = text.lastIndex(where: { !$0.isWhitespace }) else {
            return context.hasCompletePrefix || text.contains(where: \.isNewline)
                ? .sentenceStart : .uncertain
        }

        let trailingWhitespace = text[text.index(after: lastNonWhitespace)...]
        if trailingWhitespace.contains(where: \.isNewline) { return .sentenceStart }

        var candidate = lastNonWhitespace
        while candidate > text.startIndex,
              trailingIgnorable.contains(text[candidate]) || text[candidate].isWhitespace {
            candidate = text.index(before: candidate)
        }
        let character = text[candidate]
        if character == "." || character == "!" || character == "?" {
            let after = text[text.index(after: candidate)...]
            guard after.contains(where: \.isWhitespace) else { return .uncertain }
            if character == ".", isAbbreviationBeforePeriod(in: text, periodIndex: candidate) {
                return .midSentence
            }
            return .sentenceStart
        }

        if context.hasCompletePrefix || containsSentenceBoundary(in: text) {
            return .midSentence
        }
        return .uncertain
    }

    private static func containsSentenceBoundary(in text: String) -> Bool {
        if text.contains(where: \.isNewline) { return true }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                var cursor = text.index(after: index)
                while cursor < text.endIndex, trailingIgnorable.contains(text[cursor]) {
                    cursor = text.index(after: cursor)
                }
                if cursor < text.endIndex, text[cursor].isWhitespace,
                   character != "." || !isAbbreviationBeforePeriod(in: text, periodIndex: index) {
                    return true
                }
            }
            index = text.index(after: index)
        }
        return false
    }

    private static func isAbbreviationBeforePeriod(in text: String, periodIndex: String.Index) -> Bool {
        var index = periodIndex
        var token = ""
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            guard character.isLetter || character == "." || character == "'" ||
                    character == "’" || character == "-" else { break }
            token.insert(character, at: token.startIndex)
            index = previous
        }
        guard !token.isEmpty else { return false }
        let normalized = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else { return false }
        if abbreviations.contains(normalized) { return true }
        if normalized.count == 1, normalized.allSatisfy(\.isLetter) { return true }

        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { part in
            part.count == 1 && part.allSatisfy(\.isLetter)
        }
    }

    private static func firstCasedScalar(in text: String) -> FirstCasedScalar? {
        guard let index = text.unicodeScalars.firstIndex(where: { $0.properties.isCased }) else {
            return nil
        }
        return FirstCasedScalar(index: index, scalar: text.unicodeScalars[index])
    }

    private static func replacing(
        _ first: FirstCasedScalar,
        in text: String,
        with replacement: String
    ) -> String {
        var result = text
        let end = result.unicodeScalars.index(after: first.index)
        result.replaceSubrange(first.index..<end, with: replacement)
        return result
    }

    /// NaturalLanguage measured at roughly 98 ms on first use on this target,
    /// which is material immediately before insertion. This deterministic path
    /// lowercases only a small generic allowlist and leaves other title-case
    /// words unchanged rather than loading a tagger.
    private static func shouldLowercaseInitialWord(
        in text: String,
        firstCasedAt index: String.Index
    ) -> Bool {
        let wordRange = initialWordRange(in: text, firstCasedAt: index)
        let word = String(text[wordRange])
        guard !word.isEmpty else { return false }

        let cased = word.unicodeScalars.filter { $0.properties.isCased }
        guard let first = cased.first, first.properties.isUppercase,
              cased.dropFirst().allSatisfy({ $0.properties.isLowercase }) else { return false }
        if cased.count == 1, wordRange.upperBound < text.endIndex,
           text[wordRange.upperBound] == "." { return false }

        let normalized = word.lowercased()
        if normalized == "i" { return false }
        if normalized == "the", hasProperLookingNextWord(in: text, firstCasedAt: index) {
            return false
        }
        return genericInitialWords.contains(normalized)
    }

    /// Do not turn brands, acronyms, or camel-case words into title case when
    /// they begin a sentence. Only an all-lowercase word is changed.
    private static func shouldCapitalizeInitialWord(
        in text: String,
        firstCasedAt index: String.Index
    ) -> Bool {
        let word = initialWord(in: text, firstCasedAt: index)
        let cased = word.unicodeScalars.filter { $0.properties.isCased }
        guard let first = cased.first, first.properties.isLowercase else { return false }
        return !cased.dropFirst().contains(where: { $0.properties.isUppercase })
    }

    private static func initialWord(in text: String, firstCasedAt index: String.Index) -> String {
        String(text[initialWordRange(in: text, firstCasedAt: index)])
    }

    private static func initialWordRange(
        in text: String,
        firstCasedAt index: String.Index
    ) -> Range<String.Index> {
        var end = index
        while end < text.endIndex {
            let character = text[end]
            if character.isLetter || character == "'" || character == "’" || character == "-" {
                end = text.index(after: end)
            } else {
                break
            }
        }
        return index..<end
    }

    /// A cheap guard for phrases such as "The Beatles" and "The Hague".
    /// If the next word looks title-cased, acronymic, or mixed-case, keep the
    /// article rather than guessing that it is an ordinary sentence-initial
    /// article. Lowercase next words still take the normal allowlist path.
    private static func hasProperLookingNextWord(
        in text: String,
        firstCasedAt index: String.Index
    ) -> Bool {
        var cursor = initialWordRange(in: text, firstCasedAt: index).upperBound
        while cursor < text.endIndex,
              text[cursor].isWhitespace || trailingIgnorable.contains(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return false }

        let start = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isLetter || character.isNumber ||
                character == "'" || character == "’" || character == "-" {
                cursor = text.index(after: cursor)
            } else {
                break
            }
        }
        guard cursor > start else { return false }

        let cased = text[start..<cursor].unicodeScalars.filter { $0.properties.isCased }
        guard let first = cased.first else { return false }
        return first.properties.isUppercase || cased.dropFirst().contains(where: { $0.properties.isUppercase })
    }

}
