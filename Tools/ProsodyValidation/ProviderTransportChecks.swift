import ProsodyCore
import Foundation

extension ProsodyValidation {
    /// Exercise URLSession's real HTTP redirect delegate. URLProtocol stubs do
    /// not reproduce redirect forwarding, so use an isolated loopback fixture.
    static func checkProviderTransport() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-c", #"""
import http.server, json
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond(False)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.respond(True)
    def respond(self, post):
        if self.path.startswith('/blocked/'):
            self.send_response(307 if post else 302)
            self.send_header('Location', '/destination')
            self.end_headers()
        else:
            data = json.dumps({'choices':[{'message':{'role':'assistant','content':'Fixture notes'}}]}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        let output = Pipe()
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        guard let text = String(data: output.fileHandleForReading.availableData, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TransportCheckError.fixtureFailed
        }
        let local = URL(string: "http://127.0.0.1:\(port)")!
        let blocked = OpenAICompatibleProvider(baseURL: local.appendingPathComponent("blocked"), apiKey: "synthetic-fixture-key")
        do {
            _ = try await blocked.testConnection()
            throw TransportCheckError.redirectFollowed
        } catch NotesProviderError.server(let statusCode, _) {
            precondition(statusCode == 302)
        }
        let request = NotesRequest(title: "Transport fixture", transcript: Transcript(segments: [
            TranscriptSegment(source: .system, start: 0, end: 1, text: "Synthetic test data", isFinal: true)
        ]), template: .summary, duration: 1)
        do {
            _ = try await blocked.generate(request: request, modelID: "fixture")
            throw TransportCheckError.redirectFollowed
        } catch NotesProviderError.server(let statusCode, _) {
            precondition(statusCode == 307)
        }
        let direct = OpenAICompatibleProvider(baseURL: local.appendingPathComponent("success"))
        _ = try await direct.testConnection()
        let result = try await direct.generate(request: request, modelID: "fixture")
        precondition(result.markdown == "Fixture notes")
        print("Provider transport: PASS (direct requests, blocked GET 302 and POST 307 redirects)")
    }
}

private enum TransportCheckError: Error {
    case fixtureFailed
    case redirectFollowed
}
