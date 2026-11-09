import Foundation
import Testing
@testable import ZulipAPI

struct ReadFlagEventTests {

    private func decode(_ json: String) throws -> ZulipEvent {
        try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)).decoded()
    }

    @Test func aReadOnAnotherDeviceNamesItsMessages() throws {
        let event = try decode("""
            {"type": "update_message_flags", "op": "add", "operation": "add",
             "flag": "read", "messages": [63, 64], "all": false, "id": 0}
            """)

        guard case .flags(let operation, let flag, let messageIDs, let all) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(operation == "add")
        #expect(flag == "read")
        #expect(messageIDs == [63, 64])
        #expect(!all)
    }

    @Test func markingEverythingReadComesWithNoIDs() throws {
        let event = try decode("""
            {"type": "update_message_flags", "op": "add", "operation": "add",
             "flag": "read", "messages": [], "all": true, "id": 1}
            """)

        guard case .flags(_, _, let messageIDs, let all) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(messageIDs.isEmpty)
        #expect(all)
    }

    private func messageEvent(flags: [String]) -> String {
        """
        {"id": 3, "type": "message", "flags": \(flags),
         "message": {"id": 900, "sender_id": 5, "sender_full_name": "Ana",
                     "sender_email": "ana@example.com", "type": "stream",
                     "content": "<p>hi</p>", "content_type": "text/html",
                     "subject": "lunch", "timestamp": 1700000000, "stream_id": 7,
                     "is_me_message": false, "reactions": [],
                     "display_recipient": "general"}}
        """
    }

    @Test func aNewMessageTakesItsFlagsFromTheEvent() throws {
        guard case .message(let message, _) = try decode(messageEvent(flags: ["read", "mentioned"])) else {
            Issue.record("not a message event")
            return
        }
        #expect(message.isRead)
        #expect(message.isMentioned)
    }

    @Test func aNewMessageWithNoFlagsIsUnread() throws {
        guard case .message(let message, _) = try decode(messageEvent(flags: [])) else {
            Issue.record("not a message event")
            return
        }
        #expect(!message.isRead)
        #expect(!message.isMentioned)
    }

    @Test func markingUnreadStillDecodes() throws {
        let event = try decode("""
            {"type": "update_message_flags", "op": "remove", "operation": "remove",
             "flag": "read", "messages": [63],
             "message_details": {"63": {"type": "stream", "stream_id": 22, "topic": "lunch"}},
             "all": false, "id": 2}
            """)

        guard case .flags(let operation, _, let messageIDs, _) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(operation == "remove")
        #expect(messageIDs == [63])
    }
}
