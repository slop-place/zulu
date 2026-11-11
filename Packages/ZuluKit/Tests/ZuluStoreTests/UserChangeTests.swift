import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

struct UserChangeTests {

    private func storeWithAda() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try UserRecord(id: 10, fullName: "Ada", avatarURL: "/a.png?version=1").save(db)
        }
        return store
    }

    private func user(_ id: Int, in store: ZuluStore) throws -> UserRecord? {
        try store.writer.read { db in try UserRecord.fetchOne(db, key: id) }
    }

    @Test func aNewPictureKeepsTheName() throws {
        let store = try storeWithAda()

        try store.apply(UserChange(userID: 10, avatarURL: "/a.png?version=2"))

        let ada = try user(10, in: store)
        #expect(ada?.avatarURL == "/a.png?version=2")
        #expect(ada?.fullName == "Ada")
    }

    @Test func aRenameKeepsThePicture() throws {
        let store = try storeWithAda()

        try store.apply(UserChange(userID: 10, fullName: "Ada Lovelace"))

        let ada = try user(10, in: store)
        #expect(ada?.fullName == "Ada Lovelace")
        #expect(ada?.avatarURL == "/a.png?version=1")
    }

    @Test func aChangeForSomeoneUnknownIsIgnored() throws {
        let store = try ZuluStore(url: nil)

        try store.apply(UserChange(userID: 99, avatarURL: "/b.png?version=1"))

        #expect(try user(99, in: store) == nil)
    }
}
