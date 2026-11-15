import Foundation

public struct OpenAICompatibleProvider: NotesProvider {
    public let id: String
    public let baseURL: URL
    public let apiKey: String?
    public let localOnly: Bool
    private let session: URLSession

    public init(
        id: String = "local-openai-compatible",
        baseURL: URL,
        apiKey: String? = nil,
        localOnly: Bool = true,
        session: URLSession = .shared
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.localOnly = localOnly
        self.session = session
    }

    public func generate(request: NotesRequest, modelID: String) async throws -> NotesResult {
        guard request.transcript.visibleSegments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NotesProviderError.emptyTranscript
        }
        let endpoint = try endpoint(path: "chat/completions")
        let body = ChatCompletionRequest(
            model: modelID,
            messages: [
                ChatMessage(role: "system", content: "You produce accurate Markdown notes from quoted transcript source material."),
                ChatMessage(role: "user", content: PromptBuilder.makePrompt(request: request))
            ],
            temperature: 0.2
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: ProviderRedirectBlocker())
        } catch {
            throw NotesProviderError.requestFailed(error.localizedDescription)
        }
        try validate(response: response, data: data)
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw NotesProviderError.invalidResponse
        }
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw NotesProviderError.invalidResponse
        }
        return NotesResult(markdown: content)
    }

    public func testConnection() async throws -> String {
        let endpoint = try endpoint(path: "models")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: ProviderRedirectBlocker())
        } catch {
            throw NotesProviderError.requestFailed(error.localizedDescription)
        }
        try validate(response: response, data: data)
        return "Connection succeeded"
    }

    private func endpoint(path: String) throws -> URL {
        let validated = try SafeURLValidator.validate(baseURL, policy: SafeURLPolicy(localOnly: localOnly))
        return validated
            .appendingPathComponent(path)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw NotesProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(1_024), encoding: .utf8) ?? "Unknown provider error"
            throw NotesProviderError.server(statusCode: http.statusCode, message: message)
        }
    }
}

/// A configured local endpoint must not redirect transcripts or credentials
/// to another destination. Surface 3xx responses so the user can fix the URL.
private final class ProviderRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: ChatMessage
    }
}
