import Foundation
import ZulipAPI

/// Which provider to ask for GIFs, and how strictly to filter them.
public struct GIFConfiguration: Sendable, Equatable {
    public enum Provider: Sendable, Equatable {
        case klipy(apiKey: String)
        case giphy(apiKey: String)
    }

    public let provider: Provider
    public let rating: GIFRating

    static let disabledPolicyName = "disabled"

    public init(provider: Provider, rating: GIFRating) {
        self.provider = provider
        self.rating = rating
    }

    /// `nil` when the realm turned GIFs off, or when nobody has a key.
    ///
    /// The server's own key wins, in Zulip's order: KLIPY, then GIPHY. Tenor comes first
    /// for Zulip, but Google shut its API down in June 2026. Zulu's KLIPY key covers
    /// servers with none.
    public init?(realm: RealmGIFSettings, bundledKLIPYKey: String?) {
        let policy = realm.ratingPolicyName
        guard policy != Self.disabledPolicyName else { return nil }

        let provider: Provider
        if !realm.klipyAPIKey.isEmpty {
            provider = .klipy(apiKey: realm.klipyAPIKey)
        } else if !realm.giphyAPIKey.isEmpty {
            provider = .giphy(apiKey: realm.giphyAPIKey)
        } else if let bundledKLIPYKey, !bundledKLIPYKey.isEmpty {
            provider = .klipy(apiKey: bundledKLIPYKey)
        } else {
            return nil
        }
        // Zulip's web app falls back to G for a policy it does not recognise.
        self.init(provider: provider, rating: policy.flatMap(GIFRating.init(rawValue:)) ?? .g)
    }

    public func source(locale: Locale = .current) -> any GIFSource {
        switch provider {
        case .klipy(let apiKey): KLIPYSource(apiKey: apiKey, rating: rating, locale: locale)
        case .giphy(let apiKey): GIPHYSource(apiKey: apiKey, rating: rating, locale: locale)
        }
    }
}
