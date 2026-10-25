import GRDB
import SwiftUI
import ZuluStore

/// One part of the viewer's channels: what the rail picks on a phone, and a tab on a
/// foldable.
enum ShellSection: Hashable {
    /// Every conversation that moved lately, newest first, whichever section it is in.
    case recent
    case dms
    case group(String)
    /// Channels no group has claimed, so filing is optional rather than required.
    case unfiled
    /// Every channel, in a group or not.
    case all

    var groupID: String? {
        if case .group(let id) = self { id } else { nil }
    }

    /// The channels the section lists, for the sections that list channels.
    var scope: SidebarScope {
        switch self {
        case .all: .everything
        case .group(let id): .group(id)
        default: .ungrouped
        }
    }
}

extension AppModel {
    func title(of section: ShellSection) -> String {
        switch section {
        case .recent: "Recent"
        case .dms: "Direct Messages"
        case .unfiled: "Channels"
        case .all: "All Channels"
        case .group(let id): groups.first { $0.id == id }?.name ?? "Channels"
        }
    }
}

/// A section's channels, topics or conversations, and everything a row offers.
///
/// Shared by both shells, which differ only in what opening a row does: the drawer
/// slides shut on the conversation, a split view shows it beside the list or pushes it.
struct SectionList: View {
    let section: ShellSection
    /// Opens a conversation, or a channel's topics, the way the shell around the list does.
    let open: (AppModel.Destination) -> Void
    @Binding var showingReorder: Bool

    @Environment(AppModel.self) private var model

    @State private var visibleChannels: [ChannelSummary] = []
    @State private var visiblePromoted: [PromotedTopicSummary] = []
    /// Resolved once per change rather than per render: each row's preview is a parse of
    /// rendered HTML.
    @State private var recentEntries: [RecentEntry] = []
    /// Hidden channels with a mention waiting, surfaced so the rail's count can be answered.
    @State private var mentionedHidden: [ChannelSummary] = []
    @State private var promotedTask: Task<Void, Never>?
    @State private var mentionedHiddenTask: Task<Void, Never>?
    @State private var renamingChannel: ChannelSummary?
    @State private var renamingPromoted: PromotedTopicSummary?
    @State private var aliasDraft = ""
    @State private var mutedTopicsChannel: ChannelSummary?
    @State private var newTopicChannel: ChannelSummary?

    var body: some View {
        ScrollView {
            // Channels are headers with their topics hanging under them, so the gap
            // between one channel's group and the next has to be bigger than the gap
            // inside one. At equal spacing the whole list reads as one flat run.
            VStack(alignment: .leading, spacing: 0) {
                if section == .recent {
                    ForEach(recentEntries) { entry in recentRow(entry) }
                    if recentEntries.isEmpty {
                        Text(emptyListMessage)
                            .font(.footnote)
                            .foregroundStyle(TextTone.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                    }
                } else if section == .dms {
                    ForEach(model.dms) { dm in dmRow(dm) }
                } else {
                    ForEach(sidebarEntries) { entry in
                        switch entry {
                        case .promoted(let promoted):
                            promotedRow(promoted)
                        case .channel(let channel):
                            VStack(alignment: .leading, spacing: 0) {
                                channelRow(channel)
                                if channel.rendersAsForum {
                                    topicBranch(under: channel)
                                }
                            }
                            .padding(.bottom, 6)
                        }
                    }
                    if visibleChannels.isEmpty {
                        Text(emptyListMessage)
                            .font(.footnote)
                            .foregroundStyle(TextTone.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                    }
                    if !mentionedHidden.isEmpty {
                        hiddenSection
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .refreshable { await model.refreshTopics() }
        // Observed by the list, which both shells keep mounted: one observing only while
        // shown showed its last state for a moment every time it came back.
        .task(id: section) { await observe() }
        .sheet(item: $mutedTopicsChannel) { channel in MutedTopicsView(channel: channel) }
        .sheet(item: $newTopicChannel) { channel in NewTopicSheet(channel: channel) }
        .sheet(isPresented: $showingReorder) { ReorderChannelsView(entries: sidebarEntries) }
        .alert(
            "Rename for me",
            isPresented: Binding(
                get: { renamingPromoted != nil },
                set: { if !$0 { renamingPromoted = nil } }
            )
        ) {
            TextField("Name", text: $aliasDraft)
            Button("Cancel", role: .cancel) {}
            Button("Use real name", role: .destructive) {
                if let p = renamingPromoted {
                    model.setAlias(nil, forPromotedTopic: p.topic, inChannel: p.channelID)
                }
            }
            Button("Save") {
                if let p = renamingPromoted {
                    model.setAlias(aliasDraft, forPromotedTopic: p.topic, inChannel: p.channelID)
                }
            }
        } message: {
            Text("Only you see this name.")
        }
        .alert(
            "Rename for me",
            isPresented: Binding(
                get: { renamingChannel != nil },
                set: { if !$0 { renamingChannel = nil } }
            )
        ) {
            TextField("Name", text: $aliasDraft)
            Button("Cancel", role: .cancel) {}
            if model.alias(forChannel: renamingChannel?.id ?? 0) != nil {
                Button("Use real name", role: .destructive) {
                    if let channel = renamingChannel { model.setAlias(nil, forChannel: channel.id) }
                }
            }
            Button("Save") {
                if let channel = renamingChannel { model.setAlias(aliasDraft, forChannel: channel.id) }
            }
        } message: {
            Text("Only you see this name. Mentions and links still use the real one.")
        }
    }

    private var sidebarEntries: [SidebarEntry] {
        SidebarEntry.merged(channels: visibleChannels, promoted: visiblePromoted)
    }

    /// A hidden channel someone mentioned you in, listed until the mention is read. The
    /// heading says why a channel that was hidden is back.
    private var hiddenSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hidden")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TextTone.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(mentionedHidden) { channel in
                VStack(alignment: .leading, spacing: 0) {
                    channelRow(channel)
                    if channel.rendersAsForum {
                        topicBranch(under: channel)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var emptyListMessage: String {
        switch section {
        case .recent: model.allChannels.isEmpty ? "Syncing your channels…" : "Nothing has happened yet."
        case .group: "No channels in this group yet. Edit the group to add some."
        case .all: "No channels yet."
        default: "Every channel is filed into a group."
        }
    }

    private func observe() async {
        guard section != .dms else { return }
        if section == .recent {
            await observeRecent()
            return
        }
        let scope = section.scope
        guard let writer = model.databaseWriter else { return }
        if let promoted = model.promotedTopicObservation(in: scope) {
            promotedTask?.cancel()
            promotedTask = Task {
                do {
                    for try await rows in promoted.removeDuplicates().values(in: writer) { visiblePromoted = rows }
                } catch {}
            }
        }
        if let hidden = model.mentionedHiddenChannelObservation(in: scope) {
            mentionedHiddenTask?.cancel()
            mentionedHiddenTask = Task {
                do {
                    for try await rows in hidden.removeDuplicates().values(in: writer) { mentionedHidden = rows }
                } catch {}
            }
        }
        guard let observation = model.channelObservation(in: scope) else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                visibleChannels = rows
            }
        } catch {
            // Observation ends when the section changes; nothing to recover.
        }
    }

    private func observeRecent() async {
        guard let writer = model.databaseWriter,
              let observation = model.recentConversationObservation()
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                recentEntries = RecentEntry.resolve(rows, model: model)
            }
        } catch {
            // Observation ends when the section changes; nothing to recover.
        }
    }

    /// A forum's row opens its general chat, not the topic list. The list is one tap
    /// further, from the toolbar of any topic in it.
    private func channelRow(_ channel: ChannelSummary) -> some View {
        let destination = channel.rendersAsForum
            ? model.forumRowDestination(for: channel)
            : AppModel.Destination.channel(channel.id)
        return Button {
            open(destination)
        } label: {
            HStack(spacing: 7) {
                UnreadDot(visible: channel.rowUnreadCount > 0)
                ChannelIcon(
                    isForum: channel.rendersAsForum, restricted: channel.isRestricted, size: 15
                )
                .foregroundStyle(channel.rowUnreadCount > 0 ? Color.primary : SidebarTone.readIcon)
                .frame(width: 22, alignment: .leading)
                Text(channel.name)
                    .font(.subheadline.weight(channel.rowUnreadCount > 0 ? .semibold : .medium))
                    .foregroundStyle(channel.rowUnreadCount > 0 ? Color.primary : SidebarTone.readTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if channel.pinned {
                    PinMark()
                }
                Badge(count: channel.rowMentionCount, mention: true)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                model.destination == destination ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let conversation = destination.conversation {
                OpenInNewWindowButton(source: conversation)
            }
            Button(channel.pinned ? "Unpin" : "Pin to top", systemImage: channel.pinned ? "pin.slash" : "pin") {
                Task { await model.setPinned(!channel.pinned, forChannel: channel.id) }
            }
            if mentionedHidden.contains(where: { $0.id == channel.id }) {
                Button("Unhide channel", systemImage: "eye") {
                    model.setHidden(false, forChannel: channel.id)
                }
            } else {
                Button("Hide channel", systemImage: "eye.slash") {
                    model.setHidden(true, forChannel: channel.id)
                }
            }
            Button("New topic…", systemImage: "square.and.pencil") {
                newTopicChannel = channel
            }
            Button("Rename for me…", systemImage: "pencil") {
                aliasDraft = model.alias(forChannel: channel.id) ?? ""
                renamingChannel = channel
            }
            Button("Muted topics…", systemImage: "bell.slash") {
                mutedTopicsChannel = channel
            }
            Divider()
            NotificationLevelMenu.channel(channel.id, model: model)
            Picker("Show as", selection: Binding(
                get: { model.modeOverride(forChannel: channel.id) },
                set: { model.setMode($0, forChannel: channel.id) }
            )) {
                Text("Automatic").tag(ChannelMode?.none)
                ForEach(ChannelMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(ChannelMode?.some(mode))
                }
            }
        }
    }

    /// A forum channel's live conversations, hung under it so a topic is one tap away
    /// instead of two. Only the few most recent, or the sidebar becomes the conversation
    /// list.
    ///
    /// One quiet rule down the side rather than an elbow per row: at this density the
    /// brackets drew more attention than the names they were pointing at.
    @ViewBuilder
    private func topicBranch(under channel: ChannelSummary) -> some View {
        // The channel's own row is general chat, so it is not listed again here.
        let generalChat = model.generalChatTopic(inChannel: channel.id)
        let topics = (model.recentTopics[channel.id] ?? []).filter { $0.name != generalChat }
        if !topics.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.leading, 18)
                    .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(topics) { topic in
                        topicRow(topic, in: channel)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    private func topicRow(_ topic: TopicSummary, in channel: ChannelSummary) -> some View {
        let destination = AppModel.Destination.topic(
            channelID: channel.id, name: topic.name, channelName: channel.name
        )
        let isOpen = model.destination == destination
        return Button {
            // Straight to the conversation. Pushing it onto the channel's stack
            // meant the back gesture landed on a topic list nobody asked for.
            open(destination)
        } label: {
            HStack(spacing: 6) {
                UnreadDot(visible: topic.unreadCount > 0)
                Text(topic.name.isEmpty ? "general chat" : topic.name)
                    .font(.subheadline.weight(topic.unreadCount > 0 ? .semibold : .regular))
                    .foregroundStyle(topic.unreadCount > 0 ? Color.primary : SidebarTone.readTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                isOpen ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let conversation = destination.conversation {
                OpenInNewWindowButton(source: conversation)
            }
            // Lands in the group the list is showing, rather than always in the unfiled pile.
            Button("Promote to sidebar", systemImage: "arrow.up.left") {
                model.promote(topic: topic.name, inChannel: channel.id, toGroup: section.groupID)
            }
            NotificationLevelMenu.topic(topic.name, inChannel: channel.id, model: model)
        }
    }

    /// A topic lifted out of its channel to sit at channel level. It shows the channel
    /// it came from underneath, because the name alone rarely says where it lives.
    /// A promoted topic gets exactly the row a channel gets. It is a channel as far
    /// as the sidebar is concerned, and giving it its own treatment made the list
    /// look like two lists stapled together.
    private func promotedRow(_ promoted: PromotedTopicSummary) -> some View {
        let destination = AppModel.Destination.topic(
            channelID: promoted.channelID, name: promoted.topic,
            channelName: promoted.channelName
        )
        return Button {
            open(destination)
        } label: {
            HStack(spacing: 7) {
                UnreadDot(visible: promoted.unreadCount > 0)
                // A promoted topic is one conversation, not a list of them, so it takes
                // the plain channel icon — and the lock if its parent channel is private.
                ChannelIcon(isForum: false, restricted: promoted.isRestricted, size: 15)
                    .foregroundStyle(promoted.unreadCount > 0 ? Color.primary : SidebarTone.readIcon)
                    .frame(width: 22, alignment: .leading)
                Text(promoted.displayName)
                    .font(.subheadline.weight(promoted.unreadCount > 0 ? .semibold : .medium))
                    .foregroundStyle(promoted.unreadCount > 0 ? Color.primary : SidebarTone.readTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(count: promoted.mentionCount, mention: true)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                model.destination == destination ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let conversation = destination.conversation {
                OpenInNewWindowButton(source: conversation)
            }
            Button("Rename for me…", systemImage: "pencil") {
                aliasDraft = promoted.displayName
                renamingPromoted = promoted
            }
            Button("Remove from sidebar", systemImage: "arrow.down.right") {
                model.demote(topic: promoted.topic, inChannel: promoted.channelID)
            }
            NotificationLevelMenu.topic(promoted.topic, inChannel: promoted.channelID, model: model)
            Menu("Move to group", systemImage: "folder") {
                Button("Unfiled") {
                    model.setGroup(nil, forPromotedTopic: promoted.topic, inChannel: promoted.channelID)
                }
                ForEach(model.groups) { group in
                    Button(group.name) {
                        model.setGroup(group.id, forPromotedTopic: promoted.topic, inChannel: promoted.channelID)
                    }
                }
            }
        }
    }

    private func recentRow(_ entry: RecentEntry) -> some View {
        Button {
            open(entry.destination)
        } label: {
            // A row whose entry has not changed is not laid out again.
            RecentRow(entry: entry, isOpen: model.destination == entry.destination)
                .equatable()
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let conversation = entry.destination.conversation {
                OpenInNewWindowButton(source: conversation)
            }
            Button("Mark as read", systemImage: "checkmark.circle") {
                Task { await model.markRead(entry) }
            }
            .disabled(entry.unreadCount == 0)
            if case .topic(let channelID, let name, _) = entry.destination {
                NotificationLevelMenu.topic(name, inChannel: channelID, model: model)
            } else if case .channel(let id) = entry.destination {
                NotificationLevelMenu.channel(id, model: model)
            }
        }
    }

    private func dmRow(_ dm: DMSummary) -> some View {
        Button {
            open(.dm(dm.dmKey))
        } label: {
            HStack(spacing: 9) {
                SenderAvatar(
                    name: model.title(forDM: dm.dmKey),
                    userID: model.soleParticipant(inDM: dm.dmKey),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(forDM: dm.dmKey))
                        .font(.subheadline.weight(dm.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if let preview = model.preview(forDM: dm) {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(TextTone.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Badge(count: dm.unreadCount, mention: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                model.destination == .dm(dm.dmKey) ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            OpenInNewWindowButton(source: .dm(key: dm.dmKey))
            Button("Mark as read", systemImage: "checkmark.circle") {
                Task { await model.markConversationRead(.dm(key: dm.dmKey)) }
            }
            .disabled(dm.unreadCount == 0)
        }
    }
}

/// The conversation, channel or prompt a destination calls for: the page of either shell.
struct DestinationView: View {
    let destination: AppModel.Destination?
    /// What nothing open asks for: a channel, or in direct messages, a person.
    var prompt = "Pick a channel to start reading."
    @Environment(AppModel.self) private var model

    var body: some View {
        switch destination {
        case .channel(let id):
            if let channel = model.channel(id) {
                ChannelView(channel: channel).id(id)
            } else {
                EmptyStateView(text: "That channel is no longer available.")
            }
        // Identified by conversation, so moving between two of them starts the scroll
        // position, the loader and the draft fresh instead of carrying them across.
        case .topic(let channelID, let name, let channelName):
            let source = ConversationView.Source.topic(
                channelID: channelID, name: name, channelName: channelName
            )
            ConversationView(source: source).id(source)
        case .dm(let key):
            let source = ConversationView.Source.dm(key: key)
            ConversationView(source: source).id(source)
        case nil:
            EmptyStateView(text: model.allChannels.isEmpty ? "Syncing your channels…" : prompt)
        }
    }
}
