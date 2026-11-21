#if canImport(XCTest)
import Foundation
import Network
import ProsodyIPC
import XCTest

final class CLIProtocolTests: XCTestCase {
    func testRoundTripAcrossMultipleReadChunks() throws {
        let socket = try CLISocket.directory().deletingLastPathComponent()
            .appendingPathComponent("p-\(UUID().uuidString.prefix(12)).sock")
        let endpoint = NWEndpoint.unix(path: socket.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = endpoint
        let listener = try NWListener(using: parameters)
        let client = NWConnection(to: endpoint, using: .tcp)
        defer {
            client.stateUpdateHandler = nil
            client.cancel()
            listener.cancel()
            try? FileManager.default.removeItem(at: socket)
        }

        let queue = DispatchQueue(label: "prosody.cli.round-trip-test")
        let title = String(repeating: "A sample title. ", count: 5_000)
        let transcript = String(repeating: "A sample transcript with café and 🎙️.\n", count: 4_000)
        let finished = expectation(description: "received complete CLI response")
        listener.newConnectionHandler = { peer in
            peer.start(queue: queue)
            CLISocket.receive(CLIRequest.self, on: peer, limit: CLISocket.requestLimit) { result in
                do {
                    let request = try result.get()
                    XCTAssertEqual(request.command, .transcribe)
                    XCTAssertEqual(request.title, title)
                    try CLISocket.send(CLIResponse(items: [.init(input: "sample.wav", text: transcript)]),
                                       on: peer, limit: CLISocket.responseLimit) { error in
                        XCTAssertNil(error)
                    }
                } catch {
                    XCTFail("Request failed: \(error)")
                    peer.cancel()
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { client.start(queue: queue) }
        }
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            CLISocket.receive(CLIResponse.self, on: client, limit: CLISocket.responseLimit) { result in
                defer { finished.fulfill() }
                do {
                    let response = try result.get()
                    XCTAssertEqual(response.items.first?.text, transcript)
                } catch {
                    XCTFail("Response failed: \(error)")
                }
            }
            var request = CLIRequest(command: .transcribe)
            request.title = title
            request.files = ["sample.wav"]
            do {
                try CLISocket.send(request, on: client, limit: CLISocket.requestLimit) { error in
                    XCTAssertNil(error)
                }
            } catch {
                XCTFail("Send failed: \(error)")
                client.cancel()
            }
        }
        listener.start(queue: queue)
        wait(for: [finished], timeout: 5)
    }
}
#endif
