import Foundation
import Testing
@testable import ZulipAPI

struct SearchScopeTests {
    @Test func topicSearchStaysInItsTopic() {
        #expect(SearchScope.topic(channelID: 4, name: "release").narrow(for: "deploy") == [
            .channel(4), .topic("release"), .search("deploy"),
        ])
    }

    @Test func channelSearchCoversEveryTopic() {
        #expect(SearchScope.channel(4).narrow(for: "deploy") == [.channel(4), .search("deploy")])
    }

    @Test func conversationSearchStaysInTheDM() {
        #expect(SearchScope.conversation(dmUserIDs: [1, 2]).narrow(for: "lunch") == [.dm([1, 2]), .search("lunch")])
    }

    @Test func directMessageSearchCoversEveryDM() {
        #expect(SearchScope.directMessages.narrow(for: "lunch") == [.directMessages, .search("lunch")])
    }

    @Test func everywhereIsOnlyTheTerms() {
        #expect(SearchScope.everywhere.narrow(for: "deploy") == [.search("deploy")])
    }

    @Test func decodesHighlightsFromAHit() throws {
        let json = #"""
        {"id": 1, "sender_id": 2, "sender_full_name": "A", "sender_email": "a@x", "type": "stream",
         "content": "<p>deploy</p>", "content_type": "text/html", "subject": "ops", "timestamp": 0,
         "stream_id": 3, "avatar_url": null, "is_me_message": false, "reactions": [],
         "match_content": "<p><span class=\"highlight\">deploy</span></p>", "match_subject": "ops"}
        """#
        let message = try JSONDecoder().decode(ZulipMessage.self, from: Data(json.utf8))
        #expect(message.match_content == #"<p><span class="highlight">deploy</span></p>"#)
        #expect(message.match_subject == "ops")
    }
}
