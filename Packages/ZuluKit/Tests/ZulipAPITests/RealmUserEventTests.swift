import Foundation
import Testing
@testable import ZulipAPI

struct RealmUserEventTests {

    private func decode(_ json: String) throws -> ZulipEvent {
        try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)).decoded()
    }

    @Test func aNewPictureCarriesItsVersionedURL() throws {
        let event = try decode("""
            {"type": "realm_user", "op": "update", "id": 6,
             "person": {"user_id": 10, "avatar_source": "U", "avatar_version": 3,
                        "avatar_url": "/user_avatars/2/abc.png?version=3",
                        "avatar_url_medium": "/user_avatars/2/abc-medium.png?version=3"}}
            """)

        guard case .userChanged(let change) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(change == UserChange(userID: 10, avatarURL: "/user_avatars/2/abc.png?version=3"))
    }

    @Test func aRenameCarriesOnlyTheName() throws {
        let event = try decode("""
            {"type": "realm_user", "op": "update", "id": 7,
             "person": {"user_id": 10, "full_name": "New Name"}}
            """)

        guard case .userChanged(let change) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(change == UserChange(userID: 10, fullName: "New Name"))
    }

    @Test func anUpdateToSomethingUnshownIsSkipped() throws {
        let event = try decode("""
            {"type": "realm_user", "op": "update", "id": 8,
             "person": {"user_id": 10, "timezone": "Europe/Paris"}}
            """)

        guard case .other = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
    }

    @Test func aNewMemberArrivesWhole() throws {
        let event = try decode("""
            {"type": "realm_user", "op": "add", "id": 9,
             "person": {"user_id": 11, "full_name": "Grace", "email": "g@example.com",
                        "avatar_url": "/user_avatars/2/g.png?version=1",
                        "is_bot": false, "is_active": true, "role": 400}}
            """)

        guard case .userAdded(let user) = event else {
            Issue.record("decoded as \(event.eventType)")
            return
        }
        #expect(user.user_id == 11)
        #expect(user.full_name == "Grace")
        #expect(user.avatar_url == "/user_avatars/2/g.png?version=1")
    }
}
