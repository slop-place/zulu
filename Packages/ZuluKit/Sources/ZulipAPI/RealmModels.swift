import Foundation

/// A realm custom emoji, as `realm_emoji` in the register snapshot lists it.
public struct RealmEmoji: Decodable, Sendable, Equatable, Identifiable {
    /// The map key repeated. This is the `emoji_code` a `realm_emoji` reaction carries.
    public let id: String
    public let name: String
    /// A path relative to the realm, or a full URL on deployments backed by S3. Never
    /// build this path: the filename is a salted hash of the id, not the id.
    public let source_url: String
    /// The first frame of an animated emoji. Absent — not merely null — on animated
    /// emoji uploaded before Zulip 5, which the schema does not admit.
    public let still_url: String?
    /// Deactivated emoji stay listed so old reactions still resolve.
    public let deactivated: Bool?
    public let author_id: Int?
}

/// A group of people that `@` can mention.
public struct RealmUserGroup: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String?
    public let members: [Int]?
    public let direct_subgroup_ids: [Int]?
    public let is_system_group: Bool?
    /// Who may mention this group out loud. Either a group id, or an anonymous group
    /// spelled out inline.
    public let can_mention_group: GroupSetting?

    /// Which groups this person may mention without silencing the mention.
    ///
    /// The server rejects a message that mentions a group the sender is not permitted
    /// to mention, so offering one in autocomplete would produce a message that cannot
    /// be sent. Silent mentions have no such restriction.
    public static func mentionable(among groups: [RealmUserGroup], by userID: Int) -> Set<Int> {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A group's membership includes everyone in its subgroups, so belonging is
        // resolved transitively before anything is asked about it.
        var belongsTo: Set<Int> = []
        var pending = groups.filter { $0.members?.contains(userID) ?? false }.map(\.id)
        while let id = pending.popLast() {
            guard belongsTo.insert(id).inserted else { continue }
            for group in groups where group.direct_subgroup_ids?.contains(id) ?? false {
                pending.append(group.id)
            }
        }

        func admits(_ setting: GroupSetting?) -> Bool {
            switch setting {
            case .none: return false
            case .group(let id):
                guard let named = byID[id] else { return false }
                return belongsTo.contains(id) || named.members?.contains(userID) ?? false
            case .anonymous(let members, let subgroups):
                return members.contains(userID) || subgroups.contains(where: belongsTo.contains)
            }
        }

        return Set(groups.filter { admits($0.can_mention_group) }.map(\.id))
    }
}

/// A group-valued realm setting. Zulip sends either the id of a named group or, when the
/// permission was granted to an ad-hoc set of people, the set itself.
public enum GroupSetting: Decodable, Sendable, Equatable {
    case group(Int)
    case anonymous(members: [Int], subgroups: [Int])

    private struct Anonymous: Decodable {
        let direct_members: [Int]?
        let direct_subgroups: [Int]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let id = try? container.decode(Int.self) {
            self = .group(id)
            return
        }
        let anonymous = try container.decode(Anonymous.self)
        self = .anonymous(
            members: anonymous.direct_members ?? [],
            subgroups: anonymous.direct_subgroups ?? []
        )
    }
}

/// One choice in `gif_rating_policy_options`, keyed in the map by its rating, such as
/// `pg-13`, or by `disabled`.
public struct GIFRatingPolicyOption: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the server says about GIFs. The keys are not secrets: Zulip hands them to every
/// client, since the providers expect them to ship in apps anyway.
public struct RealmGIFSettings: Sendable, Equatable {
    /// Empty when the server has no key for that provider.
    public let giphyAPIKey: String
    public let klipyAPIKey: String
    public let ratingPolicy: Int?
    public let ratingPolicyOptions: [String: GIFRatingPolicyOption]

    public init(
        giphyAPIKey: String, klipyAPIKey: String,
        ratingPolicy: Int?, ratingPolicyOptions: [String: GIFRatingPolicyOption]
    ) {
        self.giphyAPIKey = giphyAPIKey
        self.klipyAPIKey = klipyAPIKey
        self.ratingPolicy = ratingPolicy
        self.ratingPolicyOptions = ratingPolicyOptions
    }

    /// The name of the realm's policy, such as `g` or `disabled`.
    public var ratingPolicyName: String? {
        ratingPolicyOptions.first { $0.value.id == ratingPolicy }?.key
    }
}
