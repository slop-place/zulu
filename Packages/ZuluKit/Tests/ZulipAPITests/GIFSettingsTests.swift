import Foundation
import Testing
@testable import ZulipAPI

struct GIFSettingsTests {

    @Test func theRegisterSnapshotNamesTheRealmsGIFPolicy() throws {
        let json = """
        {"last_event_id": -1, "giphy_api_key": "", "klipy_api_key": "k", "realm_gif_rating_policy": 2,
         "gif_rating_policy_options": {"disabled": {"id": 0, "name": "Off"}, "pg": {"id": 2, "name": "PG"}}}
        """
        let settings = try JSONDecoder().decode(RegisterResponse.self, from: Data(json.utf8)).gifSettings
        #expect(settings.klipyAPIKey == "k")
        #expect(settings.giphyAPIKey.isEmpty)
        #expect(settings.ratingPolicyName == "pg")
    }

    @Test func aServerThatSendsNoKeysHasEmptyOnes() throws {
        let settings = try JSONDecoder().decode(RegisterResponse.self, from: Data(#"{"last_event_id": -1}"#.utf8)).gifSettings
        #expect(settings.klipyAPIKey.isEmpty)
        #expect(settings.ratingPolicyName == nil)
    }
}
