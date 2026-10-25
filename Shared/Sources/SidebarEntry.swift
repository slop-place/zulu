import ZuluStore

/// One top-level row of the sidebar. Channels and promoted topics are interleaved rather
/// than stacked in two blocks, because to the person reading the sidebar they are the same
/// kind of thing: a place to go.
enum SidebarEntry: Identifiable, Equatable {
    case channel(ChannelSummary)
    case promoted(PromotedTopicSummary)

    var id: String {
        switch self {
        case .channel(let channel): "c\(channel.id)"
        case .promoted(let promoted): "p\(promoted.id)"
        }
    }

    var name: String {
        switch self {
        case .channel(let channel): channel.name
        case .promoted(let promoted): promoted.displayName
        }
    }

    var isRestricted: Bool {
        switch self {
        case .channel(let channel): channel.isRestricted
        case .promoted(let promoted): promoted.isRestricted
        }
    }

    /// A promoted topic is one conversation, never a list of them, so it never draws the
    /// forum icon even when the channel it came from does.
    var rendersAsForum: Bool {
        switch self {
        case .channel(let channel): channel.rendersAsForum
        case .promoted: false
        }
    }

    var slot: SidebarSlot {
        switch self {
        case .channel(let channel): .channel(channel.id)
        case .promoted(let promoted): .promotedTopic(channelID: promoted.channelID, topic: promoted.topic)
        }
    }

    private var position: Int? {
        switch self {
        case .channel(let channel): channel.position
        case .promoted(let promoted): promoted.position
        }
    }

    var isPinned: Bool {
        if case .channel(let channel) = self { channel.pinned } else { false }
    }

    /// Merges the two queries into the order the sidebar draws.
    ///
    /// Pinned channels come first, whatever has been dragged where, the way Zulip itself
    /// keeps them at the top. Below them, rows nobody has dragged go last in the order
    /// their own query chose. Until the first drag every promoted topic is placed and no
    /// channel is, which reproduces the old layout of promotions above channels.
    static func merged(
        channels: [ChannelSummary], promoted: [PromotedTopicSummary]
    ) -> [SidebarEntry] {
        let pinned = channels.filter(\.pinned).map(SidebarEntry.channel)
        let rest = promoted.map(SidebarEntry.promoted) + channels.filter { !$0.pinned }.map(SidebarEntry.channel)
        return ordered(pinned) + ordered(rest)
    }

    private static func ordered(_ entries: [SidebarEntry]) -> [SidebarEntry] {
        entries.enumerated()
            .sorted { left, right in
                switch (left.element.position, right.element.position) {
                case let (l?, r?): l == r ? left.offset < right.offset : l < r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): left.offset < right.offset
                }
            }
            .map(\.element)
    }
}
