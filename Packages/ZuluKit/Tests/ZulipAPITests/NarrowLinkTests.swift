import Foundation
import Testing
@testable import ZulipAPI

struct NarrowLinkTests {
    private let realm = URL(string: "https://chat.example.com")!

    private func link(_ href: String) -> NarrowLink? {
        URL(string: href, relativeTo: realm).flatMap { NarrowLink($0, realm: realm) }
    }

    @Test func channelLinkOpensTheChannel() {
        #expect(link("/#narrow/channel/12-core-infra-meta") == NarrowLink(place: .channel(12)))
    }

    @Test func oldStreamLinksStillOpen() {
        #expect(link("/#narrow/stream/12-core-infra-meta/subject/Codex")
            == NarrowLink(place: .topic(channelID: 12, name: "Codex")))
    }

    @Test func topicLinkOpensTheTopic() {
        #expect(link("/#narrow/channel/12-core-infra-meta/topic/Codex")
            == NarrowLink(place: .topic(channelID: 12, name: "Codex")))
    }

    @Test func topicNamesAreHashDecoded() {
        #expect(link("/#narrow/channel/12-ops/topic/v1.2E2.20release.20.2F.20notes")
            == NarrowLink(place: .topic(channelID: 12, name: "v1.2 release / notes")))
    }

    @Test func nonASCIITopicNamesDecode() {
        #expect(link("/#narrow/channel/12-ops/topic/caf.C3.A9")
            == NarrowLink(place: .topic(channelID: 12, name: "café")))
    }

    @Test func messageLinkCarriesItsMessage() {
        #expect(link("/#narrow/channel/12-ops/topic/deploys/near/4567")
            == NarrowLink(place: .topic(channelID: 12, name: "deploys"), messageID: 4567))
        #expect(link("/#narrow/channel/12-ops/topic/deploys/with/4567")
            == NarrowLink(place: .topic(channelID: 12, name: "deploys"), messageID: 4567))
    }

    @Test func messageOnlyLinkHasNoPlace() {
        #expect(link("/#narrow/id/4567") == NarrowLink(place: nil, messageID: 4567))
    }

    @Test func directMessageLinkListsItsPeople() {
        #expect(link("/#narrow/dm/8,12-group") == NarrowLink(place: .dm(userIDs: [8, 12])))
        #expect(link("/#narrow/dm/8-Alice-Smith/near/99") == NarrowLink(place: .dm(userIDs: [8]), messageID: 99))
        #expect(link("/#narrow/pm-with/8,12-pm") == NarrowLink(place: .dm(userIDs: [8, 12])))
    }

    @Test func absoluteLinkToTheRealmCounts() {
        #expect(link("https://chat.example.com/#narrow/channel/12-ops") == NarrowLink(place: .channel(12)))
    }

    @Test func otherRealmsAreNotOurs() {
        #expect(link("https://other.example.com/#narrow/channel/12-ops") == nil)
    }

    @Test func ordinaryLinksAreNotNarrows() {
        #expect(link("https://chat.example.com/user_uploads/1/ab/file.pdf") == nil)
        #expect(link("/#settings/profile") == nil)
    }

    @Test func narrowsThatAreNotPlacesAreLeftToTheBrowser() {
        #expect(link("/#narrow/channel/12-ops/search/deploy") == nil)
        #expect(link("/#narrow/is/starred") == nil)
        #expect(link("/#narrow/-channel/12-ops") == nil)
        #expect(link("/#narrow/channel/core-infra") == nil)
        #expect(link("/#narrow/topic/Codex") == nil)
        #expect(link("/#narrow/channel/12-ops/topic") == nil)
    }
}
