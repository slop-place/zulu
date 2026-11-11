import Testing
import ZulipAPI
@testable import ZuluGIFs

struct GIFConfigurationTests {

    private static let options: [String: GIFRatingPolicyOption] = [
        "disabled": .init(id: 0, name: "Disabled"),
        "g": .init(id: 1, name: "G"),
        "pg": .init(id: 2, name: "PG"),
        "pg-13": .init(id: 3, name: "PG-13"),
        "r": .init(id: 4, name: "R"),
    ]

    private func realm(giphy: String = "", klipy: String = "", policy: Int? = 1) -> RealmGIFSettings {
        RealmGIFSettings(
            giphyAPIKey: giphy, klipyAPIKey: klipy, ratingPolicy: policy, ratingPolicyOptions: Self.options
        )
    }

    @Test func theServersKLIPYKeyComesFirst() {
        let configuration = GIFConfiguration(realm: realm(giphy: "g", klipy: "s"), bundledKLIPYKey: "b")
        #expect(configuration?.provider == .klipy(apiKey: "s"))
    }

    @Test func theServersGIPHYKeyBeatsTheBundledOne() {
        let configuration = GIFConfiguration(realm: realm(giphy: "g"), bundledKLIPYKey: "b")
        #expect(configuration?.provider == .giphy(apiKey: "g"))
    }

    @Test func theBundledKeyCoversAServerWithNone() {
        let configuration = GIFConfiguration(realm: realm(), bundledKLIPYKey: "b")
        #expect(configuration?.provider == .klipy(apiKey: "b"))
    }

    @Test func noKeyAnywhereMeansNoGIFs() {
        #expect(GIFConfiguration(realm: realm(), bundledKLIPYKey: "") == nil)
        #expect(GIFConfiguration(realm: realm(), bundledKLIPYKey: nil) == nil)
    }

    @Test func aRealmThatDisabledGIFsGetsNone() {
        #expect(GIFConfiguration(realm: realm(klipy: "s", policy: 0), bundledKLIPYKey: "b") == nil)
    }

    @Test func theRealmsPolicyIsTheRating() {
        #expect(GIFConfiguration(realm: realm(policy: 3), bundledKLIPYKey: "b")?.rating == .pg13)
        #expect(GIFConfiguration(realm: realm(policy: 4), bundledKLIPYKey: "b")?.rating == .r)
    }

    @Test func anUnknownPolicyFallsBackToG() {
        #expect(GIFConfiguration(realm: realm(policy: 99), bundledKLIPYKey: "b")?.rating == .g)
        #expect(GIFConfiguration(realm: realm(policy: nil), bundledKLIPYKey: "b")?.rating == .g)
    }
}
