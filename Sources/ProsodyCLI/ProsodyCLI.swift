import Darwin
import Foundation
import Network
import ProsodyIPC

@main
struct ProsodyCLI {
    struct UsageError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
            print(help)
            return
        }
        let command = arguments.removeFirst()
        if arguments == ["--help"] || arguments == ["-h"] { print(help); return }
        do {
            guard let name = CLIRequest.Command(rawValue: command) else { throw UsageError("Unknown command: \(command)") }
            let (request, json) = try parse(name, arguments: arguments)
            let reply = try await send(request)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(reply), as: UTF8.self))
            } else {
                if let message = reply.message { print(message) }
                for item in reply.items {
                    if let error = item.error { stderr("\(item.input): \(error)") }
                    else if name == .labels || name == .replacements { print([item.input, item.text, item.output].compactMap { $0 }.joined(separator: "\t")) }
                    else if let value = item.output ?? item.text { print(value) }
                }
                if let error = reply.error { stderr(error) }
            }
            if reply.error != nil || reply.items.contains(where: { $0.error != nil }) { exit(1) }
        } catch let error as UsageError {
            stderr(error.message)
            stderr("Run prosody --help for usage.")
            exit(2)
        } catch {
            stderr(error.localizedDescription)
            exit(1)
        }
    }

    private static func parse(_ command: CLIRequest.Command, arguments: [String]) throws -> (CLIRequest, Bool) {
        var request = CLIRequest(command: command)
        if command == .replacements {
            var parts = arguments[...]
            var json = false
            while parts.first == "--json" {
                parts.removeFirst()
                json = true
            }
            if parts.isEmpty { return (request, json) }
            guard let operation = CLIRequest.ReplacementOperation(rawValue: parts.removeFirst()) else {
                throw UsageError("Use replacements list, set, or remove.")
            }
            let operandCount: Int
            switch operation {
            case .list: operandCount = 0
            case .set: operandCount = 2
            case .remove: operandCount = 1
            }
            // Keep the existing trailing flag precedence when an operand is literally "--json".
            if parts.last == "--json" {
                parts.removeLast()
                json = true
            }
            while parts.count > operandCount, parts.first == "--json" {
                parts.removeFirst()
                json = true
            }
            guard parts.count == operandCount else {
                throw UsageError("Pass ORIGINAL and REPLACEMENT to set, or ORIGINAL to remove.")
            }
            request.replacementOperation = operation
            if !parts.isEmpty { request.originalWord = parts.removeFirst() }
            request.replacementWord = parts.first
            return (request, json)
        }
        var json = false
        var flags = true
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next(), !next.isEmpty else { throw UsageError("Missing value for \(flag)") }
            return next
        }
        while let arg = iterator.next() {
            if arg == "--", flags { flags = false; continue }
            if arg == "--json", flags { json = true; continue }
            guard command == .transcribe else { throw UsageError("\(command.rawValue) accepts only --json.") }
            if !flags || !arg.hasPrefix("-") {
                request.files.append(absolutePath(arg))
                continue
            }
            switch arg {
            case "--output-dir", "-o": request.outputDirectory = absolutePath(try value(arg))
            case "--label", "-l": request.label = try value(arg)
            case "--title": request.title = try value(arg)
            case "--format", "-f":
                let format = try value(arg)
                switch format {
                case "markdown": request.format = "markdown"
                case "plain-markdown": request.format = "textOnlyMarkdown"
                case "text": request.format = "rawText"
                default: throw UsageError("Unknown output format: \(format)")
                }
            case "--keep-filename": request.preserveFileName = true
            case "--label-filenames": request.preserveFileName = false
            case "--omit-fillers": request.omitFillers = true
            case "--keep-fillers": request.omitFillers = false
            case "--stdout": request.stdout = true
            case "--include", "--exclude":
                let fields = try value(arg).split(separator: ",").map(String.init)
                guard !fields.isEmpty, fields.allSatisfy(CLIRequest.fields.contains) else {
                    throw UsageError("Invalid metadata fields. Valid fields: \(CLIRequest.fields.joined(separator: ", ")).")
                }
                for field in fields { request.markdownFields[field] = arg == "--include" }
            default: throw UsageError("Unknown flag: \(arg)")
            }
        }
        if command == .transcribe {
            guard !request.files.isEmpty, request.files.count <= 512 else { throw UsageError("Provide 1–512 audio files.") }
            if request.stdout || request.title != nil {
                guard request.files.count == 1 else { throw UsageError("--stdout and --title require a single file.") }
            }
            if request.stdout && request.outputDirectory != nil {
                throw UsageError("Choose either --stdout or --output-dir.")
            }
        }
        return (request, json)
    }

    private static func send(_ request: CLIRequest) async throws -> CLIResponse {
        let connection = NWConnection(to: try CLISocket.endpoint(), using: .tcp)
        let responses = AsyncThrowingStream<CLIResponse, any Error> { continuation in
            continuation.onTermination = { _ in connection.cancel() }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    CLISocket.receive(CLIResponse.self, on: connection, limit: CLISocket.responseLimit) { result in
                        switch result {
                        case .success(let reply): continuation.yield(reply); continuation.finish()
                        case .failure:
                            continuation.finish(throwing: CLIResponseError("Prosody closed the connection before returning a result."))
                        }
                    }
                    do {
                        try CLISocket.send(request, on: connection, limit: CLISocket.requestLimit) { error in
                            if let error { continuation.finish(throwing: error) }
                        }
                    } catch { continuation.finish(throwing: error) }
                case .waiting(let error), .failed(let error):
                    continuation.finish(throwing: CLIResponseError("Prosody is unavailable. Open the app and enable the command-line tool in Settings → General. \(error.localizedDescription)"))
                case .cancelled:
                    continuation.finish(throwing: CLIResponseError("The connection to Prosody closed."))
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "prosody.cli.client"))
        for try await response in responses { return response }
        throw CLIResponseError("Prosody did not return a response.")
    }

    private struct CLIResponseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    private static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static let help = """
    Usage
      prosody status [--json]
      prosody labels [--json]
      prosody replacements [--json] list [--json]
      prosody replacements [--json] set ORIGINAL REPLACEMENT [--json]
      prosody replacements [--json] remove ORIGINAL [--json]
      prosody transcribe [options] <audio-file> [...]

    Options
      -o, --output-dir PATH              Save to this folder
      -l, --label NAME|UUID              Apply a saved label
      -f, --format markdown|plain-markdown|text
      --title TEXT                       Name one transcript
      --keep-filename / --label-filenames
      --omit-fillers / --keep-fillers
      --include LIST / --exclude LIST    Override Markdown fields
      --stdout                          Print one transcript
      --json                            Print structured results
      --                                Treat later arguments as filenames

    Markdown fields: \(CLIRequest.fields.joined(separator: ", "))
    The tool runs jobs in the open Prosody app using its selected model.
    """
}
