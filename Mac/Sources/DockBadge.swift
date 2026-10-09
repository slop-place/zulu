/// What the dock icon says, the way Discord's does it: a count of what is addressed to
/// you, a dot when there is only something to read, nothing when there is nothing.
struct DockBadge: Equatable {
    /// Mentions and direct messages.
    var addressed: Int
    var hasUnread: Bool

    static let dot = "•"

    var label: String? {
        if addressed > 0 { return String(addressed) }
        return hasUnread ? Self.dot : nil
    }
}
