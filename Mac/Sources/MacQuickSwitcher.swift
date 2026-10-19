import SwiftUI
import ZuluStore

/// ⌘K: type a few letters, press Return, be there. Channels, promoted and recent
/// topics, direct messages, and anyone in the realm you have not messaged yet.
struct MacQuickSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private static let limit = 12

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(TextTone.secondary)
                TextField("Jump to a channel, topic or person", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(TextTone.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if items.isEmpty {
                Text(query.isEmpty ? "Nothing to jump to yet." : "Nothing matches “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(TextTone.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selected)
                                    .id(item.id)
                                    .onTapGesture { open(item) }
                                    .onHover { if $0 { selected = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selected) { _, index in
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id)
                    }
                }
            }
        }
        .frame(width: 560)
        .onChange(of: query) { selected = 0 }
        .task { focused = true }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let userID = item.userID {
                    SenderAvatar(name: item.title, userID: userID, size: 24)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TextTone.secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(TextTone.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.mentions > 0 {
                Badge(count: item.mentions, mention: true)
            } else if item.unread > 0 {
                Text("\(item.unread)").font(.caption.weight(.semibold)).foregroundStyle(TextTone.secondary)
            }
            if selected {
                Text("↩").font(.caption).foregroundStyle(TextTone.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    private func openSelected() {
        guard items.indices.contains(selected) else { return }
        open(items[selected])
    }

    private func open(_ item: Item) {
        ui.section = MacShellView.section(for: item.destination, model: model)
        model.destination = item.destination
        dismiss()
        ui.requestComposerFocus()
    }

    // MARK: candidates

    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let symbol: String
        let userID: Int?
        let unread: Int
        let mentions: Int
        let destination: AppModel.Destination
        /// Lower is earlier when the match quality is the same.
        let kind: Int
        /// Extra names the item answers to — a channel's real name under an alias.
        let aliases: [String]
    }

    private var items: [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = candidatesList
        guard !needle.isEmpty else {
            // Nothing typed: what needs attention first, then the rest in sidebar order.
            return Array(candidates
                .sorted { ($0.mentions, $0.unread) > ($1.mentions, $1.unread) }
                .prefix(Self.limit))
        }
        return candidates
            .compactMap { item -> (Item, Int)? in
                let names = [item.title] + item.aliases
                guard let score = names.compactMap({ Self.score(needle, in: $0) }).min() else { return nil }
                return (item, score)
            }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 < right.1 }
                if left.0.kind != right.0.kind { return left.0.kind < right.0.kind }
                return left.0.title.localizedCaseInsensitiveCompare(right.0.title) == .orderedAscending
            }
            .prefix(Self.limit)
            .map(\.0)
    }

    /// Prefix beats word-start beats anywhere. Anything else is not a match.
    private static func score(_ needle: String, in name: String) -> Int? {
        let haystack = name.lowercased()
        if haystack.hasPrefix(needle) { return 0 }
        if haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) {
            return 1
        }
        if haystack.contains(needle) { return 2 }
        return nil
    }

    private var candidatesList: [Item] {
        var items: [Item] = []
        let selfID = model.selfUserID

        for channel in model.allChannels {
            let real = model.realName(forChannel: channel.id)
            items.append(Item(
                id: "c\(channel.id)",
                title: channel.name,
                subtitle: real != nil && real != channel.name ? "#\(real!)" : (channel.rendersAsForum ? "Forum" : "Channel"),
                symbol: channel.rendersAsForum ? "bubble.left.and.text.bubble.right" : "number",
                userID: nil,
                unread: channel.unreadCount,
                mentions: channel.mentionCount,
                destination: channel.rendersAsForum ? model.forumRowDestination(for: channel) : .channel(channel.id),
                kind: 0,
                aliases: real.map { [$0] } ?? []
            ))
        }

        let channelsByID = Dictionary(uniqueKeysWithValues: model.allChannels.map { ($0.id, $0) })
        for promotion in model.promotedTopics {
            guard let channel = channelsByID[promotion.channelID],
                  !model.isMuted(topic: promotion.topic, inChannel: promotion.channelID)
            else { continue }
            items.append(Item(
                id: "p\(promotion.id)",
                title: promotion.topic.isEmpty ? "general chat" : promotion.topic,
                subtitle: "#\(channel.name)",
                symbol: "number",
                userID: nil,
                unread: 0,
                mentions: 0,
                destination: .topic(channelID: channel.id, name: promotion.topic, channelName: channel.name),
                kind: 0,
                aliases: []
            ))
        }

        for (channelID, topics) in model.recentTopics {
            guard let channel = channelsByID[channelID], channel.rendersAsForum else { continue }
            for topic in topics {
                items.append(Item(
                    id: "t\(topic.id)",
                    title: topic.name.isEmpty ? "general chat" : topic.name,
                    subtitle: "#\(channel.name)",
                    symbol: "text.bubble",
                    userID: nil,
                    unread: topic.unreadCount,
                    mentions: 0,
                    destination: .topic(channelID: channel.id, name: topic.name, channelName: channel.name),
                    kind: 1,
                    aliases: []
                ))
            }
        }

        var directPeople = Set<Int>()
        for dm in model.dms {
            let sole = model.soleParticipant(inDM: dm.dmKey)
            if let sole { directPeople.insert(sole) }
            items.append(Item(
                id: "d\(dm.dmKey)",
                title: model.title(forDM: dm.dmKey),
                subtitle: sole == nil ? "Group direct message" : "Direct message",
                symbol: "person.2",
                userID: sole,
                unread: dm.unreadCount,
                mentions: dm.unreadCount,
                destination: .dm(dm.dmKey),
                kind: 1,
                aliases: []
            ))
        }

        for user in model.users.values where user.id != selfID && !directPeople.contains(user.id) {
            guard let key = model.dmKey(with: [user.id]) else { continue }
            items.append(Item(
                id: "u\(user.id)",
                title: user.fullName,
                subtitle: user.isBot ? "Bot" : "Start a direct message",
                symbol: "person",
                userID: user.id,
                unread: 0,
                mentions: 0,
                destination: .dm(key),
                kind: user.isBot ? 3 : 2,
                aliases: user.email.map { [$0] } ?? []
            ))
        }

        return items
    }
}
