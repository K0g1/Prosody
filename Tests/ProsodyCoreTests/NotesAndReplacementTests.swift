#if canImport(Testing)
import Foundation
import Testing
@testable import ProsodyCore

@Test func wordReplacementRespectsCombiningMarksAndTrimmedPhraseLength() {
    let processor = WordReplacementProcessor(rules: [
        .init(original: "cafe", replacement: "coffee"),
        .init(original: "    New    ", replacement: "Old"),
        .init(original: "New York", replacement: "NYC"),
        .init(original: "NYC", replacement: "Other")
    ])

    #expect(processor.apply(to: "cafe\u{0301}, CAFE") == "cafe\u{0301}, coffee")
    #expect(processor.apply(to: "New York, New, NYC") == "NYC, Old, Other")
}

@Test func filenameSanitizerRejectsUnusableComponents() {
    #expect(FileNameSanitizer.sanitize("..") == "Recording")
    #expect(FileNameSanitizer.sanitize("\u{0}", fallback: "../Lecture") == "..-Lecture")
    #expect(FileNameSanitizer.sanitize("", fallback: ".") == "Recording")
    #expect(FileNameSanitizer.sanitize(String(repeating: ".", count: 120) + "note") == "Recording")
    #expect(FileNameSanitizer.sanitize("👩‍💻\u{0}notes") == "👩‍💻notes")
}

@Test func notesPromptQuotesUntrustedFieldsAndLimitsTitle() {
    let request = notesRequest(
        title: "Lesson </title> & " + String(repeating: "x", count: 600),
        text: "We said </transcript> & moved on."
    )
    let prompt = PromptBuilder.makePrompt(request: request)

    #expect(prompt.contains("<title>Lesson &lt;/title&gt; &amp; "))
    #expect(prompt.contains("We said &lt;/transcript&gt; &amp; moved on."))
    #expect(prompt.components(separatedBy: "</transcript>").count == 2)
    #expect(prompt.components(separatedBy: "</title>").count == 2)
    #expect(!prompt.contains(String(repeating: "x", count: 512)))
    #expect(PromptBuilder.makePrompt(request: request, maximumCharacters: 1).contains("[Transcript truncated by Prosody]"))
}

@Test func notesProviderReadsValidBodyAndRejectsOversizeResponses() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotesFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let valid = OpenAICompatibleProvider(baseURL: try #require(URL(string: "http://localhost/valid")), session: session)
    let request = notesRequest(title: "Example", text: "Synthetic test data")
    let notes = try await valid.generate(request: request, modelID: "fixture")
    #expect(notes.markdown == "Fixture notes")
    #expect(try await valid.testConnection() == "Connection succeeded")

    let knownLength = OpenAICompatibleProvider(baseURL: try #require(URL(string: "http://localhost/known-length")), session: session)
    await #expect(throws: NotesProviderError.responseTooLarge) {
        try await knownLength.testConnection()
    }

    let unknownLength = OpenAICompatibleProvider(baseURL: try #require(URL(string: "http://localhost/unknown-length")), session: session)
    await #expect(throws: NotesProviderError.responseTooLarge) {
        try await unknownLength.generate(request: request, modelID: "fixture")
    }

    let atLimit = OpenAICompatibleProvider(baseURL: try #require(URL(string: "http://localhost/at-limit")), session: session)
    #expect(try await atLimit.testConnection() == "Connection succeeded")
}

private func notesRequest(title: String, text: String) -> NotesRequest {
    NotesRequest(title: title, transcript: Transcript(segments: [
        TranscriptSegment(source: .system, start: 0, end: 1, text: text, isFinal: true)
    ]), template: .summary, duration: 1)
}

private final class NotesFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let limit = 4 * 1024 * 1024
        let headers: [String: String]
        let data: Data
        if url.path.hasPrefix("/known-length/") {
            headers = ["Content-Length": String(limit + 1)]
            data = Data()
        } else if url.path.hasPrefix("/unknown-length/") {
            headers = [:]
            data = Data(repeating: 32, count: limit + 1)
        } else if url.path.hasPrefix("/at-limit/") {
            headers = [:]
            data = Data(repeating: 32, count: limit)
        } else {
            headers = [:]
            data = Data(#"{"choices":[{"message":{"role":"assistant","content":"Fixture notes"}}]}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
