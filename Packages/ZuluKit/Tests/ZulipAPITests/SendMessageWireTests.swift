import Foundation
import Testing
@testable import ZulipAPI

/// Answers every request with a canned send reply and keeps the request for inspection.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: String] = [:]
    nonisolated(unsafe) static var lastPath = ""
    nonisolated(unsafe) static var reply = #"{"result": "success", "msg": "", "id": 900}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastPath = request.url?.path ?? ""
        Self.lastBody = Self.form(Self.body(of: request))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A session hands a body to its protocols as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func form(_ data: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }
}

@Suite(.serialized)
struct SendMessageWireTests {
    private let client: ZulipClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ZulipClient(
            account: ZulipAccount(
                realmURL: URL(string: "https://chat.example.com")!,
                email: "me@example.com", apiKey: "key", userID: 5
            ),
            session: URLSession(configuration: configuration)
        )
    }()

    @Test func aTaggedChannelSendPutsTheEchoOnTheWire() async throws {
        let id = try await client.sendMessage(
            toChannel: 7, topic: "lunch plans", content: "a & b = c",
            echo: LocalEcho(queueID: "1234:5", localID: "8F2C-uuid")
        )
        #expect(id == 900)
        #expect(StubProtocol.lastPath.hasSuffix("/api/v1/messages"))
        #expect(StubProtocol.lastBody == [
            "type": "stream", "to": "7", "topic": "lunch plans", "content": "a & b = c",
            "queue_id": "1234:5", "local_id": "8F2C-uuid", "read_by_sender": "true",
        ])
    }

    @Test func aTaggedDirectSendPutsTheEchoOnTheWire() async throws {
        _ = try await client.sendMessage(
            toUsers: [3], content: "hi", echo: LocalEcho(queueID: "q", localID: "l")
        )
        #expect(StubProtocol.lastBody["queue_id"] == "q")
        #expect(StubProtocol.lastBody["local_id"] == "l")
        #expect(StubProtocol.lastBody["to"] == "[3]")
    }

    @Test func anUntaggedSendLeavesTheEchoOff() async throws {
        _ = try await client.sendMessage(toChannel: 7, topic: "t", content: "c")
        #expect(StubProtocol.lastBody["queue_id"] == nil)
        #expect(StubProtocol.lastBody["local_id"] == nil)
        #expect(StubProtocol.lastBody["content"] == "c")
    }
}
