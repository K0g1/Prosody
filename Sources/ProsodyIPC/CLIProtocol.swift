import Darwin
import Foundation
import Network

public struct CLIRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { case status, labels, replacements, transcribe }

    public let command: Command
    public enum ReplacementOperation: String, Codable, Sendable { case list, set, remove }

    public var replacementOperation: ReplacementOperation?
    public var originalWord: String?
    public var replacementWord: String?
    public var files: [String] = []
    public var outputDirectory: String?
    public var label: String?
    public var title: String?
    public var format: String?
    public var preserveFileName: Bool?
    public var omitFillers: Bool?
    public var markdownFields: [String: Bool] = [:]
    public var stdout = false

    public init(command: Command) { self.command = command }

    public static let fields = ["title", "date", "time", "duration", "audio-name", "timestamps", "speakers", "labels"]
}

public struct CLIResponse: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let input: String
        public var output: String?
        public var text: String?
        public var error: String?

        public init(input: String, output: String? = nil, text: String? = nil, error: String? = nil) {
            self.input = input
            self.output = output
            self.text = text
            self.error = error
        }
    }

    public var message: String?
    public var error: String?
    public var items: [Item]

    public init(message: String? = nil, error: String? = nil, items: [Item] = []) {
        self.message = message
        self.error = error
        self.items = items
    }
}

public enum CLISocket {
    public nonisolated static func directory() throws -> URL {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 1 else { throw CocoaError(.fileNoSuchFile) }
        var raw = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &raw, size) == size else { throw CocoaError(.fileNoSuchFile) }
        let pathBytes = raw.dropLast().map { UInt8(bitPattern: $0) }
        let path = String(decoding: pathBytes, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("ProsodyCLI", isDirectory: true)
    }

    public nonisolated static func endpoint() throws -> NWEndpoint { .unix(path: try socketURL().path) }
    public nonisolated static func socketURL() throws -> URL { try directory().appendingPathComponent("v1.sock") }

    public static let requestLimit = 1_048_576
    public static let responseLimit = 64 * 1_048_576

    public nonisolated static func send<T: Encodable>(_ message: T, on connection: NWConnection,
        limit: Int, completion: @escaping @Sendable (NWError?) -> Void) throws {
        let body = try JSONEncoder().encode(message)
        guard body.count <= limit, let length = UInt32(exactly: body.count) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        var size = length.bigEndian
        var packet = withUnsafeBytes(of: &size) { Data($0) }
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed(completion))
    }

    public nonisolated static func receive<T: Decodable & Sendable>(_ type: T.Type, on connection: NWConnection,
        limit: Int, completion: @escaping @Sendable (Result<T, any Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard let header, header.count == 4, error == nil else {
                completion(.failure(error ?? CocoaError(.fileReadCorruptFile)))
                return
            }
            let size = header.reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= limit else {
                completion(.failure(CocoaError(.fileReadCorruptFile)))
                return
            }
            BodyReader<T>(connection: connection, size: size, completion: completion).receiveNextChunk()
        }
    }

    // Only one receive is outstanding at a time. Each callback runs on the connection's queue.
    private final class BodyReader<Message: Decodable & Sendable>: @unchecked Sendable {
        private let connection: NWConnection
        private let size: Int
        private let completion: @Sendable (Result<Message, any Error>) -> Void
        private var body = Data()

        init(connection: NWConnection, size: Int, completion: @escaping @Sendable (Result<Message, any Error>) -> Void) {
            self.connection = connection
            self.size = size
            self.completion = completion
        }

        func receiveNextChunk() {
            let count = min(size - body.count, 64 * 1024)
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] chunk, _, _, error in
                do {
                    if let error { throw error }
                    guard let chunk, chunk.count == count else { throw CocoaError(.fileReadCorruptFile) }
                    body.append(chunk)
                    if body.count == size {
                        completion(.success(try JSONDecoder().decode(Message.self, from: body)))
                    } else {
                        receiveNextChunk()
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }
}
