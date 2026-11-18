#if canImport(XCTest)
import ApplicationServices
import Foundation
import XCTest
@testable import ProsodyCore

@MainActor
final class SmartDictationCapitalizationTests: XCTestCase {
    func testSentenceStartsAtEmptyFieldAndAfterWhitespacePunctuation() {
        XCTAssertEqual(transformed("hello ", after: ""), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "   "), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "First paragraph.\n\n"), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "First paragraph\n\n"), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "First. "), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "Really! "), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "Why? "), "Hello ")
    }

    func testQuotesBracketsAndClosersDoNotHideSentenceBoundaries() {
        XCTAssertEqual(transformed("hello ", after: "He said. (“"), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "Done.) "), "Hello ")
        XCTAssertEqual(transformed("hello ", after: "Done.” "), "Hello ")
        XCTAssertEqual(transformed("The", after: "He said, "), "the")
    }

    func testOpeningQuoteOrBracketOnlyPrefixIsASentenceStart() {
        XCTAssertEqual(transformed("the", after: "“"), "The")
        XCTAssertEqual(transformed("the", after: " (["), "The")
        XCTAssertEqual(transformed("the", after: "“", complete: false), "the")
    }

    func testGenericInitialWordsLowercaseOnlyInConfidentMidSentenceContext() {
        XCTAssertEqual(transformed("The", after: "I was thinking "), "the")
        XCTAssertEqual(transformed("This", after: "We know "), "this")
        XCTAssertEqual(transformed("We", after: "Then "), "we")
        XCTAssertEqual(transformed("Is", after: "The question "), "is")
    }

    func testProperNounsAcronymsAndMixedCaseArePreserved() {
        XCTAssertEqual(transformed("Paris", after: "I visited "), "Paris")
        XCTAssertEqual(transformed("Smith", after: "I met "), "Smith")
        XCTAssertEqual(transformed("NASA", after: "I joined "), "NASA")
        XCTAssertEqual(transformed("iPhone", after: "I bought an "), "iPhone")
        XCTAssertEqual(transformed("May", after: "We met in "), "May")
        XCTAssertEqual(transformed("Mark", after: "I called "), "Mark")
        XCTAssertEqual(transformed("Google", after: "I searched "), "Google")
        XCTAssertEqual(transformed("I", after: "Then "), "I")
        XCTAssertEqual(transformed("Running", after: "I was "), "Running")
        XCTAssertEqual(transformed("Beautiful", after: "It looked "), "Beautiful")

        XCTAssertEqual(transformed("iPhone", after: ""), "iPhone")
        XCTAssertEqual(transformed("NASA", after: ""), "NASA")
        XCTAssertEqual(transformed("eBay", after: ""), "eBay")
    }

    func testArticlePhrasesThatLookLikeNamesKeepTheirCasing() {
        XCTAssertEqual(transformed("The Beatles", after: "I listened to "), "The Beatles")
        XCTAssertEqual(transformed("The Hague", after: "I visited "), "The Hague")
        XCTAssertEqual(transformed("The United States", after: "I visited "), "The United States")
        XCTAssertEqual(transformed("The iPhone", after: "I bought "), "The iPhone")
        XCTAssertEqual(transformed("The “Beatles”", after: "I listened to "), "The “Beatles”")
        XCTAssertEqual(transformed("The (Hague)", after: "I visited "), "The (Hague)")
        XCTAssertEqual(transformed("The question", after: "I answered "), "the question")
    }

    func testAbbreviationsAndSingleInitialsDoNotStartSentences() {
        XCTAssertEqual(transformed("The", after: "Use e.g. "), "the")
        XCTAssertEqual(transformed("The", after: "Use i.e. "), "the")
        XCTAssertEqual(transformed("The", after: "I met Mr. "), "the")
        XCTAssertEqual(transformed("The", after: "I met Dr. "), "the")
        XCTAssertEqual(transformed("The", after: "It was J. "), "the")
        XCTAssertEqual(transformed("The", after: "See U.S. "), "the")
        XCTAssertEqual(transformed("the", after: "I met Mr. Smith. "), "The")
    }

    func testLoneTitleCasedInitialBeforePeriodStaysCapitalizedMidSentence() {
        XCTAssertEqual(transformed("A. Smith", after: "I met "), "A. Smith")
        XCTAssertEqual(transformed("a. Smith", after: ""), "A. Smith")
    }

    func testPeriodWithoutWhitespaceIsUncertain() {
        XCTAssertEqual(transformed("the", after: "Hello."), "the")
        XCTAssertEqual(transformed("the", after: "Hello.\n"), "The")
    }

    func testUnicodeAccentsCombiningGraphemesAndGermanExpansion() {
        XCTAssertEqual(transformed("éclair ", after: ""), "Éclair ")
        XCTAssertEqual(transformed("e\u{301}clair ", after: ""), "E\u{301}clair ")
        XCTAssertEqual(transformed("ßeta ", after: ""), "SSeta ")
        XCTAssertEqual(transformed("ß", after: ""), "SS")
        XCTAssertEqual(transformed("ß", after: "").utf16.count, 2)
    }

    func testTransformedUTF16LengthFeedsReceiptCaret() {
        let text = transformed("ß", after: "")
        XCTAssertEqual(text, "SS")
        let expected = DictationSelectionRebase.expectedCaret(
            after: CFRange(location: 5, length: 0),
            insertedUTF16Count: text.utf16.count
        )
        XCTAssertEqual(expected?.location, 7)
        XCTAssertEqual(expected?.length, 0)
    }

    func testTrailingSingleSpaceAndUncasedTextArePreserved() {
        let result = transformed("hello ", after: "")
        XCTAssertEqual(result, "Hello ")
        XCTAssertEqual(result.filter { $0 == " " }.count, 1)
        XCTAssertEqual(transformed("123... ", after: ""), "123... ")
    }

    func testTruncatedContextWithoutBoundaryDoesNotGuess() {
        XCTAssertEqual(transformed("The", after: "   ", complete: false), "The")
        XCTAssertEqual(transformed("The", after: "long sentence", complete: false), "The")
        XCTAssertEqual(transformed("The", after: "Earlier. Later words", complete: false), "the")
        XCTAssertEqual(transformed("The", after: "Earlier\nLater words", complete: false), "the")
    }

    func testReplacementSelectionUsesTextBeforeSelectionStart() {
        let state = FakeAXState(
            selection: CFRange(location: 7, length: 3),
            text: "Hello. old"
        )
        let result = SmartDictationCapitalization.apply(
            to: "world ",
            smartCapitalization: true,
            element: dummyElement,
            selection: state.currentSelection,
            access: state.access
        )
        XCTAssertEqual(result, "World ")
        XCTAssertEqual(state.requestedRanges.first?.location, 0)
        XCTAssertEqual(state.requestedRanges.first?.length, 7)
    }

    func testDisabledPreferenceMakesNoAXCalls() {
        let state = FakeAXState(selection: CFRange(location: 0, length: 0), text: "")
        let result = SmartDictationCapitalization.apply(
            to: "hello ",
            smartCapitalization: false,
            element: dummyElement,
            selection: state.currentSelection,
            access: state.access
        )
        XCTAssertEqual(result, "hello ")
        XCTAssertTrue(state.attributeReads.isEmpty)
        XCTAssertEqual(state.rangeReads, 0)
        XCTAssertEqual(state.valueReads, 0)
    }

    func testMissingAXElementLeavesTextUnchangedWithoutReads() {
        let state = FakeAXState(selection: CFRange(location: 0, length: 0), text: "")
        let result = SmartDictationCapitalization.apply(
            to: "hello ", smartCapitalization: true,
            element: nil, selection: state.currentSelection, access: state.access
        )
        XCTAssertEqual(result, "hello ")
        XCTAssertTrue(state.attributeReads.isEmpty)
        XCTAssertEqual(state.rangeReads, 0)
    }

    func testAXReaderPrefersBoundedRangeAndDoesNotReadValue() {
        let state = FakeAXState(
            selection: CFRange(location: 7, length: 0),
            text: "Hello. "
        )
        state.numberOfCharacters = 7
        let context = SmartDictationAXContextReader.context(
            from: dummyElement, selection: state.currentSelection, access: state.access
        )
        XCTAssertEqual(context?.precedingText, "Hello. ")
        XCTAssertEqual(context?.hasCompletePrefix, true)
        XCTAssertEqual(state.requestedRanges.first?.location, 0)
        XCTAssertEqual(state.requestedRanges.first?.length, 7)
        XCTAssertEqual(state.valueReads, 0)
    }

    func testValidatedPathSkipsDuplicateSecureAndSelectionReads() {
        let state = FakeAXState(selection: CFRange(location: 7, length: 0), text: "Hello. ")
        let result = SmartDictationCapitalization.applyValidated(
            to: "the", smartCapitalization: true,
            element: dummyElement, selection: state.currentSelection, access: state.access
        )
        XCTAssertEqual(result, "The")
        XCTAssertFalse(state.attributeReads.contains(kAXSubroleAttribute))
        XCTAssertFalse(state.attributeReads.contains(kAXSelectedTextRangeAttribute))
        XCTAssertEqual(state.requestedRanges.count, 1)
    }

    func testAXReaderRecognizesFieldBeginningWithoutReadingText() {
        let state = FakeAXState(selection: CFRange(location: 0, length: 0), text: "ignored")
        let context = SmartDictationAXContextReader.context(
            from: dummyElement, selection: state.currentSelection, access: state.access
        )
        XCTAssertEqual(context?.precedingText, "")
        XCTAssertEqual(context?.hasCompletePrefix, true)
        XCTAssertEqual(state.rangeReads, 0)
        XCTAssertEqual(state.valueReads, 0)
    }

    func testAXReaderRejectsSecureUnsupportedAndMismatchedSelectionWithoutTextReads() {
        let secure = FakeAXState(selection: CFRange(location: 7, length: 0), text: "secret")
        secure.subrole = kAXSecureTextFieldSubrole
        XCTAssertNil(SmartDictationAXContextReader.context(
            from: dummyElement, selection: secure.currentSelection, access: secure.access
        ))
        XCTAssertEqual(SmartDictationCapitalization.apply(
            to: "hello ", smartCapitalization: true,
            element: dummyElement, selection: secure.currentSelection, access: secure.access
        ), "hello ")
        XCTAssertFalse(secure.attributeReads.contains(kAXSelectedTextRangeAttribute))
        XCTAssertEqual(secure.rangeReads, 0)
        XCTAssertEqual(secure.valueReads, 0)

        let unsupported = FakeAXState(selection: CFRange(location: 7, length: 0), text: "text")
        unsupported.role = kAXButtonRole
        XCTAssertNil(SmartDictationAXContextReader.context(
            from: dummyElement, selection: unsupported.currentSelection, access: unsupported.access
        ))
        XCTAssertEqual(SmartDictationCapitalization.apply(
            to: "hello ", smartCapitalization: true,
            element: dummyElement, selection: unsupported.currentSelection, access: unsupported.access
        ), "hello ")
        XCTAssertEqual(unsupported.rangeReads, 0)

        let mismatch = FakeAXState(selection: CFRange(location: 7, length: 0), text: "Hello. ")
        mismatch.currentSelection = CFRange(location: 6, length: 0)
        XCTAssertNil(SmartDictationAXContextReader.context(
            from: dummyElement, selection: CFRange(location: 7, length: 0), access: mismatch.access
        ))
        XCTAssertEqual(mismatch.rangeReads, 0)
    }

    func testAXReaderFallsBackOnlyForSmallReportedValues() {
        let small = FakeAXState(selection: CFRange(location: 7, length: 0), text: "Hello. ")
        small.supportsRange = false
        small.numberOfCharacters = 7
        let context = SmartDictationAXContextReader.context(
            from: dummyElement, selection: small.currentSelection, access: small.access
        )
        XCTAssertEqual(context?.precedingText, "Hello. ")
        XCTAssertEqual(context?.hasCompletePrefix, true)
        XCTAssertEqual(small.valueReads, 1)

        let large = FakeAXState(selection: CFRange(location: 7, length: 0), text: String(repeating: "a", count: 3_000))
        large.supportsRange = false
        large.numberOfCharacters = 3_000
        XCTAssertNil(SmartDictationAXContextReader.context(
            from: dummyElement, selection: large.currentSelection, access: large.access
        ))
        XCTAssertEqual(large.valueReads, 0)
    }

    func testAXReaderRejectsFallbackRangeThatSplitsUTF16Surrogate() {
        let state = FakeAXState(selection: CFRange(location: 1, length: 0), text: "😀 hello")
        state.supportsRange = false
        state.numberOfCharacters = 8
        XCTAssertNil(SmartDictationAXContextReader.context(
            from: dummyElement, selection: state.currentSelection, access: state.access
        ))
        XCTAssertEqual(state.valueReads, 1)
    }

    func testAXReaderLeavesTruncatedWindowWithoutBoundaryUncertain() throws {
        let text = String(repeating: "a", count: 1_000)
        let state = FakeAXState(selection: CFRange(location: 900, length: 0), text: text)
        let context = SmartDictationAXContextReader.context(
            from: dummyElement, selection: state.currentSelection, access: state.access
        )
        XCTAssertEqual(context?.hasCompletePrefix, false)
        XCTAssertEqual(context?.precedingText.utf16.count, 512)
        XCTAssertEqual(state.requestedRanges.first?.location, 388)
        XCTAssertEqual(state.requestedRanges.first?.length, 512)
        XCTAssertEqual(SmartDictationCapitalization.transform("The", context: try XCTUnwrap(context)), "The")
    }

    func testAXReaderUsesBoundaryInsideTruncatedWindow() throws {
        let text = String(repeating: "a", count: 600) + "Earlier. "
        let selection = CFRange(location: text.utf16.count, length: 0)
        let state = FakeAXState(selection: selection, text: text)
        let context = try XCTUnwrap(SmartDictationAXContextReader.context(
            from: dummyElement, selection: selection, access: state.access
        ))
        XCTAssertFalse(context.hasCompletePrefix)
        XCTAssertEqual(SmartDictationCapitalization.transform("the", context: context), "The")
    }

    func testPreferenceDefaultsTrueOnlyWhenAbsentAndPersistsFalse() {
        let suite = "Prosody-SmartCapitalization-Tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "preferences.smartDictationCapitalization"

        XCTAssertNil(defaults.object(forKey: key))
        let preferences = ProsodyPreferences(defaults: defaults)
        XCTAssertTrue(preferences.smartDictationCapitalization)
        XCTAssertNil(defaults.object(forKey: key))
        preferences.smartDictationCapitalization = false
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
        XCTAssertFalse(ProsodyPreferences(defaults: defaults).smartDictationCapitalization)
        preferences.smartDictationCapitalization = true
        XCTAssertTrue(ProsodyPreferences(defaults: defaults).smartDictationCapitalization)
    }

    func testSettingsSearchFindsSmartCapitalizationTarget() throws {
        let entries = DictationSettingsView.controlsForSearch
        let entry = try XCTUnwrap(entries.first { $0.id == "clippy.settings.dictation.smart-capitalization" })
        XCTAssertEqual(entry.title, "Smart sentence capitalization")
        XCTAssertEqual(entry.help, "Best effort in apps that expose caret context.")

        let index = SettingsSearchIndex(sections: [(section: .dictation, entries: entries)])
        XCTAssertEqual(
            index.results(for: "sentence capitalization").first?.id.control,
            "clippy.settings.dictation.smart-capitalization"
        )
        XCTAssertEqual(
            index.results(for: "smart capitalization").first?.id.control,
            "clippy.settings.dictation.smart-capitalization"
        )
        XCTAssertEqual(
            index.results(for: "caret context").first?.id.control,
            "clippy.settings.dictation.smart-capitalization"
        )
    }

    private var dummyElement: AXUIElement { AXUIElementCreateSystemWide() }

    private func transformed(
        _ text: String,
        after precedingText: String,
        complete: Bool = true
    ) -> String {
        SmartDictationCapitalization.transform(
            text,
            context: SmartDictationTextContext(
                precedingText: precedingText,
                hasCompletePrefix: complete
            )
        )
    }
}

@MainActor
private final class FakeAXState {
    var role: String? = kAXTextFieldRole
    var subrole: String?
    var currentSelection: CFRange
    var text: String?
    var numberOfCharacters: Int?
    var supportsRange = true
    var attributeReads: [String] = []
    var requestedRanges: [CFRange] = []
    var rangeReads = 0
    var valueReads = 0

    init(selection: CFRange, text: String?) {
        currentSelection = selection
        self.text = text
    }

    var access: SmartDictationAXAccess {
        SmartDictationAXAccess(
            attribute: { [weak self] _, name in
                guard let self else { return nil }
                self.attributeReads.append(name)
                switch name {
                case kAXRoleAttribute:
                    return self.role.map { $0 as CFString }
                case kAXSubroleAttribute:
                    return self.subrole.map { $0 as CFString }
                case kAXSelectedTextRangeAttribute:
                    return axRangeValue(self.currentSelection)
                case kAXNumberOfCharactersAttribute:
                    return self.numberOfCharacters.map { NSNumber(value: $0) }
                case kAXValueAttribute:
                    self.valueReads += 1
                    return self.text.map { $0 as CFString }
                default:
                    return nil
                }
            },
            stringForRange: { [weak self] _, range in
                guard let self else { return nil }
                self.rangeReads += 1
                self.requestedRanges.append(range)
                guard self.supportsRange, let text = self.text else { return nil }
                let units = Array(text.utf16)
                guard range.location >= 0, range.length >= 0,
                      range.location <= units.count,
                      range.length <= units.count - range.location else { return nil }
                let start = range.location
                let end = start + range.length
                return String(decoding: units[start..<end], as: UTF16.self)
            }
        )
    }
}

private func axRangeValue(_ range: CFRange) -> CFTypeRef? {
    var range = range
    return AXValueCreate(.cfRange, &range)
}
#endif
