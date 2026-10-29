import Foundation
import Testing
@testable import ZulipAPI

struct LocalEchoTests {

    private let echo = LocalEcho(queueID: "q-1", localID: "L-1")

    @Test func aTaggedChannelSendNamesTheQueueAndTheLocalID() {
        let parameters = ZulipClient.channelMessageParameters(
            channelID: 7, topic: "lunch", content: "hi", echo: echo
        )
        #expect(parameters == [
            "type": "stream", "to": "7", "topic": "lunch", "content": "hi",
            "queue_id": "q-1", "local_id": "L-1", "read_by_sender": "true",
        ])
    }

    @Test func aTaggedDirectSendNamesTheQueueAndTheLocalID() {
        let parameters = ZulipClient.directMessageParameters(userIDs: [3, 4], content: "hi", echo: echo)
        #expect(parameters["queue_id"] == "q-1")
        #expect(parameters["local_id"] == "L-1")
        #expect(parameters["type"] == "private")
        #expect(parameters["to"] == "[3,4]")
    }

    @Test func anUntaggedSendCarriesNeitherField() {
        let channel = ZulipClient.channelMessageParameters(channelID: 7, topic: "t", content: "c", echo: nil)
        let direct = ZulipClient.directMessageParameters(userIDs: [3], content: "c", echo: nil)
        for parameters in [channel, direct] {
            #expect(parameters["queue_id"] == nil)
            #expect(parameters["local_id"] == nil)
        }
    }

    /// The echo cannot overwrite what the message says, whatever it is called.
    @Test func theEchoNeverReplacesTheMessage() {
        let parameters = ZulipClient.channelMessageParameters(
            channelID: 7, topic: "t", content: "real", echo: LocalEcho(queueID: "q", localID: "l")
        )
        #expect(parameters["content"] == "real")
        #expect(parameters.count == 7)
    }

    /// The server leaves a message unread for its sender unless the client is an official app.
    @Test func everySendIsReadBySender() {
        let channel = ZulipClient.channelMessageParameters(channelID: 7, topic: "t", content: "c", echo: nil)
        let direct = ZulipClient.directMessageParameters(userIDs: [3], content: "c", echo: echo)
        for parameters in [channel, direct] {
            #expect(parameters["read_by_sender"] == "true")
        }
    }

    // MARK: the echo coming back

    private func messageEvent(localID: String?) -> String {
        let field = localID.map { #", "local_message_id": \#($0)"# } ?? ""
        return """
            {"id": 12, "type": "message", "flags": []\(field),
             "message": {"id": 900, "sender_id": 5, "sender_full_name": "Ana",
                         "sender_email": "ana@example.com", "type": "stream",
                         "content": "<p>hi</p>", "content_type": "text/html",
                         "subject": "lunch", "timestamp": 1700000000, "stream_id": 7,
                         "is_me_message": false, "reactions": [],
                         "display_recipient": "general"}}
            """
    }

    private func decode(_ json: String) throws -> ZulipEvent {
        try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)).decoded()
    }

    @Test func anEchoCarriesItsLocalID() throws {
        guard case .message(let message, let localID) = try decode(messageEvent(localID: #""L-1""#)) else {
            Issue.record("not a message event")
            return
        }
        #expect(message.id == 900)
        #expect(localID == "L-1")
    }

    @Test func aMessageFromElsewhereHasNoLocalID() throws {
        guard case .message(_, let localID) = try decode(messageEvent(localID: nil)) else {
            Issue.record("not a message event")
            return
        }
        #expect(localID == nil)
    }

    @Test func aNumericLocalIDStillMatches() throws {
        guard case .message(_, let localID) = try decode(messageEvent(localID: "42")) else {
            Issue.record("not a message event")
            return
        }
        #expect(localID == "42")
    }

    @Test func aLocalIDOfTheWrongTypeDoesNotLoseTheMessage() throws {
        guard case .message(let message, let localID) = try decode(messageEvent(localID: "true")) else {
            Issue.record("not a message event")
            return
        }
        #expect(message.id == 900)
        #expect(localID == nil)
    }

    @Test func aNullLocalIDReadsAsNone() throws {
        guard case .message(_, let localID) = try decode(messageEvent(localID: "null")) else {
            Issue.record("not a message event")
            return
        }
        #expect(localID == nil)
    }
}
