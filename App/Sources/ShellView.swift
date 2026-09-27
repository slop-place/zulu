import GRDB
import SwiftUI
import ZuluStore
import ZuluSync

/// The drawer shell, wired to the store. Structure follows the nav-shell prototype:
/// a rail, a channel list, and a message page that slides off them.
struct ShellView: View {
    @Environment(AppModel.self) private var model

    private enum Section: Equatable, Hashable {
        case dms
        case group(String)
        /// Channels no group has claimed, so filing is optional rather than required.
        case unfiled
    }

    @State private var section: Section = .unfiled
    @State private var visibleChannels: [ChannelSummary] = []
    @State private var visiblePromoted: [PromotedTopicSummary] = []
    @State private var renamingChannel: ChannelSummary?
    @State private var aliasDraft = ""
    @State private var promotedTask: Task<Void, Never>?
    @State private var showingHidden = false
    @State private var showingNotifications = false
    @State private var mutedTopicsChannel: ChannelSummary?
    @State private var showingReorder = false
    @State private var reorderingGroups = false
    @State private var renamingPromoted: PromotedTopicSummary?
    @State private var editingGroup: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var open = true
    @State private var drag: CGFloat = 0
    @State private var drawerMounted = true
    @State private var path: [ConversationView.Source] = []

    private let railW: CGFloat = 80
    private let listW: CGFloat = 236
    private var drawerW: CGFloat { railW + listW }

    private var offset: CGFloat { min(max((open ? drawerW : 0) + drag, 0), drawerW) }

    private static let slide = Animation.snappy(duration: 0.24, extraBounce: 0)

    private func setOpen(_ value: Bool) {
        if value {
            drawerMounted = true
            dismissKeyboard()
        }
        withAnimation(Self.slide, completionCriteria: .removed) {
            open = value
            drag = 0
        } completion: {
            if !open { drawerMounted = false }
        }
    }

    /// The composer lives in a different view tree from the drawer, so its focus state
    /// cannot be reached from here.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color(.systemBackground).ignoresSafeArea()
            if drawerMounted { drawer }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: offset > 0 ? 28 : 0)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(offset > 0 ? 0.28 : 0), radius: 20, x: -8)
                        .ignoresSafeArea()
                }
                .offset(x: offset)
                .overlay {
                    if offset > drawerW * 0.4 {
                        Color.black.opacity(0.001)
                            .onTapGesture { setOpen(false) }
                            .offset(x: offset)
                    }
                }
                // Simultaneous, not exclusive: a plain `.gesture` loses the opening
                // swipe to the conversation's own scroll view, which claims the touch
                // first. Closing worked only because the dimming overlay sat on top.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            // Left-to-right belongs to the drawer; right-to-left is left
                            // alone so row swipe actions keep it.
                            guard open || value.translation.width > 0 else { return }
                            if value.translation.width > 0, !drawerMounted {
                                drawerMounted = true
                                dismissKeyboard()
                            }
                            drag = value.translation.width
                        }
                        .onEnded { value in
                            let projected = offset + value.predictedEndTranslation.width * 0.4
                            setOpen(projected > drawerW / 2)
                        }
                )
        }
    }

    // MARK: drawer

    private var drawer: some View {
        HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(DrawerPalette.edge)
                .frame(width: 1)
                .ignoresSafeArea(edges: .vertical)
            list.frame(width: listW)
        }
        .frame(width: drawerW)
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 12) {
                railButton(
                    active: section == .dms,
                    unread: model.dms.contains { $0.unreadCount > 0 },
                    // Every direct message is addressed to you, so each unread one counts.
                    mentions: model.dms.reduce(0) { $0 + $1.unreadCount }
                ) { section = .dms } label: {
                    RailIcon(systemImage: "bubble.left.and.bubble.right.fill", active: section == .dms)
                }

                Divider().frame(width: 28)

                ForEach(model.groups) { group in
                    railButton(
                        active: section == .group(group.id),
                        unread: group.unreadCount > 0,
                        mentions: group.mentionCount
                    ) {
                        section = .group(group.id)
                    } label: {
                        GroupAvatar(
                            name: group.name, icon: group.icon,
                            active: section == .group(group.id)
                        )
                    }
                    .contextMenu {
                        Button("Edit group", systemImage: "pencil") { editingGroup = group.id }
                        NotificationLevelMenu.group(group.id, model: model)
                        Button("Reorder groups", systemImage: "arrow.up.arrow.down") {
                            reorderingGroups = true
                        }
                        .disabled(model.groups.count < 2)
                        Button("Delete group", systemImage: "trash", role: .destructive) {
                            if section == .group(group.id) { section = .unfiled }
                            model.deleteGroup(id: group.id)
                        }
                    }
                }

                if !model.groups.isEmpty { Divider().frame(width: 28) }

                railButton(
                    active: section == .unfiled,
                    unread: model.unfiledHasUnread,
                    mentions: model.unfiledMentionCount
                ) { section = .unfiled } label: {
                    RailIcon(systemImage: "number", active: section == .unfiled)
                }

                railButton(active: false, unread: false, mentions: 0) {
                    newGroupName = ""
                    creatingGroup = true
                } label: {
                    RailIcon(systemImage: "plus")
                }
            }
            .padding(.vertical, 12)
        }
        // Liquid Glass morphs beyond a controls bounds, and a ScrollView clips by
        // default, which shears the animation off mid-flight.
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .frame(width: railW)
        .background(DrawerPalette.rail.ignoresSafeArea(edges: .vertical))
    }

    /// Unread is a pill on the rail's edge; a count only appears when something actually
    /// needs an answer. A number for every unread message turns the rail into noise.
    private func railButton<Face: View>(
        active: Bool,
        unread: Bool,
        mentions: Int,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Face
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 46, height: 46)
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 {
                        Text(mentions > 99 ? "99+" : "\(mentions)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .overlay(
                                Capsule().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2)
                            )
                            .fixedSize()
                            .offset(x: 4, y: 3)
                    }
                }
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 4, height: active ? 26 : (unread ? 10 : 0))
                        .offset(x: -15)
                }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: active)
        .animation(.snappy, value: unread)
    }

    private var listTitle: String {
        switch section {
        case .dms: "Direct Messages"
        case .unfiled: "Channels"
        case .group(let id): model.groups.first { $0.id == id }?.name ?? "Channels"
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(listTitle).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                SyncDot(status: model.status)
                Menu {
                    Button("Reorder channels", systemImage: "arrow.up.arrow.down") {
                        showingReorder = true
                    }
                    Button("Hidden channels", systemImage: "eye.slash") { showingHidden = true }
                    Button("Notifications", systemImage: "bell") { showingNotifications = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DrawerPalette.listHeader)

            ScrollView {
                // Channels are headers with their topics hanging under them, so the gap
                // between one channel's group and the next has to be bigger than the gap
                // inside one. At equal spacing the whole list reads as one flat run.
                VStack(alignment: .leading, spacing: 0) {
                    if section == .dms {
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
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .refreshable { await model.refreshTopics() }
        }
        .background(DrawerPalette.list.ignoresSafeArea(edges: .vertical))
        .task(id: section) { await observeChannels() }
    }

    private var sidebarEntries: [SidebarEntry] {
        SidebarEntry.merged(channels: visibleChannels, promoted: visiblePromoted)
    }

    private var emptyListMessage: String {
        switch section {
        case .group: "No channels in this group yet. Long-press its icon to edit."
        default: "Every channel is filed into a group."
        }
    }

    private func observeChannels() async {
        guard section != .dms else { return }
        let groupID: String? = if case .group(let id) = section { id } else { nil }
        guard let writer = model.databaseWriter else { return }
        if let promoted = model.promotedTopicObservation(inGroup: groupID) {
            promotedTask?.cancel()
            promotedTask = Task {
                do {
                    for try await rows in promoted.removeDuplicates().values(in: writer) { visiblePromoted = rows }
                } catch {}
            }
        }
        guard let observation = model.channelObservation(inGroup: groupID) else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                visibleChannels = rows
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
            model.destination = destination
            path = []
            setOpen(false)
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
                Badge(count: channel.rowMentionCount, mention: true)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                model.destination == destination ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Hide channel", systemImage: "eye.slash") {
                model.setHidden(true, forChannel: channel.id)
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
            model.destination = destination
            path = []
            setOpen(false)
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
            Button("Promote to sidebar", systemImage: "arrow.up.left") {
                model.promote(topic: topic.name, inChannel: channel.id, toGroup: currentGroupID)
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
            model.destination = destination
            path = []
            setOpen(false)
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

    private func dmRow(_ dm: DMSummary) -> some View {
        Button {
            model.destination = .dm(dm.dmKey)
            path = []
            setOpen(false)
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
                            .foregroundStyle(.secondary)
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
    }

    // MARK: content

    private var content: some View {
        NavigationStack(path: $path) {
            destinationView
                .navigationDestination(for: ConversationView.Source.self) { source in
                    ConversationView(source: source)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { setOpen(!open) } label: { Image(systemName: "line.3.horizontal") }
                    }
                }
        }
        .sheet(isPresented: $showingHidden) { HiddenChannelsView() }
        .sheet(isPresented: $showingNotifications) { NotificationSettingsView() }
        .sheet(item: $mutedTopicsChannel) { channel in MutedTopicsView(channel: channel) }
        .sheet(isPresented: $showingReorder) { ReorderChannelsView(entries: sidebarEntries) }
        .sheet(isPresented: $reorderingGroups) { ReorderGroupsView(groups: model.groups) }
        .sheet(item: Binding(get: { editingGroup.map(Identified.init) },
                             set: { editingGroup = $0?.value })) { wrapper in
            GroupEditor(groupID: wrapper.value)
        }
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
        .alert("New group", isPresented: $creatingGroup) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.createGroup(named: name)
            }
        } message: {
            Text("Group channels however you like. Groups stay on your devices — Zulip has no idea they exist.")
        }
        .onChange(of: model.pendingGroupToEdit) { _, id in
            guard let id else { return }
            editingGroup = id
            section = .group(id)
            model.pendingGroupToEdit = nil
        }
    }

    /// `sheet(item:)` needs something Identifiable, and a bare String is not.
    private struct Identified: Identifiable {
        let value: String
        var id: String { value }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.destination {
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
            EmptyStateView(text: model.allChannels.isEmpty
                ? "Syncing your channels…"
                : "Pick a channel to start reading.")
        }
    }
}

extension ShellView {
    /// The group the sidebar is currently showing, so a promotion lands where it was made
    /// rather than always in the unfiled pile.
    fileprivate var currentGroupID: String? {
        if case .group(let id) = section { id } else { nil }
    }
}
