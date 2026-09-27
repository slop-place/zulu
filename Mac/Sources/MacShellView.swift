import AppKit
import GRDB
import SwiftUI
import ZuluStore

/// The Mac shell: a group rail and a channel list in one sidebar, a conversation beside
/// them.
///
/// The iOS drawer exists because a phone has room for one column at a time. A Mac window
/// does not have that problem, so the same information is laid out rather than stacked —
/// which is why this is its own view and not the drawer with the gesture taken out.
struct MacShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    @State private var channels: [ChannelSummary] = []
    @State private var promoted: [PromotedTopicSummary] = []
    @State private var promotedTask: Task<Void, Never>?
    @State private var expanded: Set<Int> = []
    @State private var columns: NavigationSplitViewVisibility = .all

    @State private var renamingChannel: ChannelSummary?
    @State private var renamingPromoted: PromotedTopicSummary?
    @State private var aliasDraft = ""
    @State private var newGroupName = ""
    @State private var sectionFollowedDestination = false

    var body: some View {
        alerts(sheets(split))
    }

    /// The split view and the state it keeps in step. Its presentations hang off it in
    /// two further steps, because one chain of fifteen modifiers is more than the type
    /// checker will take in a single expression.
    private var split: some View {
        @Bindable var ui = ui
        return NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 480)
        } detail: {
            MacDetailView()
        }
        .task(id: ui.section) { await observe() }
        // The remembered destination comes back before the groups do, so the section
        // follows it once the groups are known — and only once, or switching sections
        // by hand would keep snapping back.
        .onChange(of: model.groups.count, initial: true) {
            guard !sectionFollowedDestination, let destination = model.destination else { return }
            ui.section = section(for: destination)
            // The first pass runs before the groups observation has delivered anything,
            // and lands every channel in "unfiled". Only a pass that could see the groups
            // settles it; if the realm has none, nothing ever changes the count again.
            sectionFollowedDestination = !model.groups.isEmpty
        }
        .onChange(of: model.pendingGroupToEdit) { _, id in
            guard let id else { return }
            ui.section = .group(id)
            ui.editingGroup = MacUIState.GroupBox(id: id)
            model.pendingGroupToEdit = nil
        }
        .onChange(of: dockBadge, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
    }

    private func sheets(_ content: some View) -> some View {
        @Bindable var ui = ui
        return content
            .sheet(isPresented: $ui.showingQuickSwitcher) { MacQuickSwitcher() }
            .sheet(isPresented: $ui.showingNewMessage) { MacNewMessageSheet() }
            .sheet(isPresented: $ui.showingHidden) { MacHiddenChannelsSheet() }
            .sheet(item: $ui.newTopicChannel) { box in MacNewTopicSheet(channel: box.channel) }
            .sheet(item: $ui.mutedTopicsChannel) { box in MacMutedTopicsSheet(channel: box.channel) }
            .sheet(item: $ui.editingGroup) { box in MacGroupEditor(groupID: box.id) }
    }

    private func alerts(_ content: some View) -> some View {
        @Bindable var ui = ui
        return content
            .alert("New Group", isPresented: $ui.showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Cancel", role: .cancel) { newGroupName = "" }
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    newGroupName = ""
                    guard !name.isEmpty else { return }
                    model.createGroup(named: name)
                }
            } message: {
                Text("Group channels however you like. Groups stay on your devices — Zulip never learns they exist.")
            }
            .alert("Rename for Me", isPresented: Binding(
                get: { renamingChannel != nil },
                set: { if !$0 { renamingChannel = nil } }
            )) {
                TextField("Name", text: $aliasDraft)
                Button("Cancel", role: .cancel) {}
                if let channel = renamingChannel, model.alias(forChannel: channel.id) != nil {
                    Button("Use Real Name", role: .destructive) {
                        model.setAlias(nil, forChannel: channel.id)
                    }
                }
                Button("Save") {
                    if let channel = renamingChannel { model.setAlias(aliasDraft, forChannel: channel.id) }
                }
            } message: {
                Text("Only you see this name. Mentions and links still use the real one.")
            }
            .alert("Rename for Me", isPresented: Binding(
                get: { renamingPromoted != nil },
                set: { if !$0 { renamingPromoted = nil } }
            )) {
                TextField("Name", text: $aliasDraft)
                Button("Cancel", role: .cancel) {}
                Button("Use Real Name", role: .destructive) {
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
            .confirmationDialog(
                "Sign out of \(model.account?.email ?? "this account")?",
                isPresented: $ui.confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    ui.forgetSectionDestinations()
                    Task { await model.signOut() }
                }
            } message: {
                Text("Your channel groups, renames and hidden channels on this Mac are removed with it.")
            }
    }

    /// Mentions and direct messages only: a number for every unread message in every
    /// channel turns the dock into a nag.
    private var dockBadge: Int {
        model.dms.reduce(0) { $0 + $1.unreadCount }
            + model.allChannels.reduce(0) { $0 + $1.mentionCount }
    }

    // MARK: sidebar

    private var sidebar: some View {
        HStack(spacing: 0) {
            MacRail()
            Divider()
            VStack(spacing: 0) {
                list
                Divider()
                MacSidebarFooter()
            }
        }
        .onChange(of: model.destination) { _, destination in
            guard let destination else { return }
            ui.remember(destination, in: section(for: destination))
        }
        .onChange(of: ui.section) { _, section in
            guard model.destination.map(self.section(for:)) != section else { return }
            model.destination = ui.lastDestination(in: section)
        }
    }

    /// Rows carry a `tag`, not a `NavigationLink`. In a `List(selection:)` driving a
    /// split view's detail column, a link has nothing to push onto and the row simply
    /// does not respond.
    private var list: some View {
        List(selection: destinationBinding) {
            // A direct message that needs an answer is pinned above whatever section is
            // showing, so it is never hidden behind a rail switch. It stays while it is
            // the open conversation, rather than vanishing the moment it is read.
            if ui.section != .dms, !pinnedDMs.isEmpty {
                Section("Direct Messages") {
                    ForEach(pinnedDMs) { dm in dmRow(dm) }
                }
            }
            // The column's navigation title does not render on macOS 26, so the section
            // says what it is at the top of the list, the way Mail's sidebar does.
            Section(listTitle) {
                sectionRows
            }
        }
        .listStyle(.sidebar)
        // A DM row moving from the DM section into the pinned section leaves a stale
        // copy drawn over the first channel. A fresh list per section has nothing to move.
        .id(ui.section)
    }

    private var pinnedDMs: [DMSummary] {
        model.dms.filter { $0.unreadCount > 0 || model.destination == .dm($0.dmKey) }
    }

    private func dmRow(_ dm: DMSummary) -> some View {
        MacDMRow(dm: dm)
            .tag(AppModel.Destination.dm(dm.dmKey))
            .contextMenu {
                Button("Mark as Read") {
                    Task { await model.markConversationRead(.dm(key: dm.dmKey)) }
                }
                .disabled(dm.unreadCount == 0)
            }
    }

    @ViewBuilder
    private var sectionRows: some View {
        if ui.section == .dms {
            if model.dms.isEmpty {
                Text("No direct messages yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(model.dms) { dm in dmRow(dm) }
        } else {
            ForEach(entries) { entry in
                switch entry {
                case .promoted(let topic):
                    promotedRow(topic)
                case .channel(let channel):
                    channelRow(channel)
                }
            }
            .onMove { source, destination in
                var ordered = entries
                ordered.move(fromOffsets: source, toOffset: destination)
                model.reorderSidebar(ordered.map(\.slot))
            }
            if entries.isEmpty {
                Text(emptyListMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
    }

    /// The list writes straight into the model, so the rail, the menu bar and the quick
    /// switcher all move the same selection. Deselecting is ignored: an empty detail
    /// column is never what a click on blank sidebar meant.
    private var destinationBinding: Binding<AppModel.Destination?> {
        Binding(
            get: { model.destination },
            set: { if let destination = $0 { model.destination = destination } }
        )
    }

    /// A forum's row opens its general chat — the conversation people mean when they
    /// say the channel's name — not a list to pick from first. The topic page is one
    /// click further: the "All topics" row underneath, or the toolbar of any topic in it.
    @ViewBuilder
    private func channelRow(_ channel: ChannelSummary) -> some View {
        if channel.rendersAsForum {
            DisclosureGroup(isExpanded: binding(forChannel: channel.id)) {
                MacTopicRows(channel: channel, groupID: currentGroupID)
            } label: {
                MacSidebarRow(
                    title: channel.name,
                    symbol: "bubble.left.and.text.bubble.right",
                    restricted: channel.isRestricted,
                    unread: channel.rowUnreadCount,
                    mentions: channel.rowMentionCount
                )
            }
            .tag(model.forumRowDestination(for: channel))
            .contextMenu { channelMenu(channel) }
            // Collapsing a forum hides what was read, never what is waiting.
            if !expanded.contains(channel.id) {
                ForEach(unreadTopics(in: channel)) { topic in
                    MacTopicRow(topic: topic, channel: channel, groupID: currentGroupID)
                        .padding(.leading, Self.collapsedTopicIndent)
                        .moveDisabled(true)
                }
            }
        } else {
            MacSidebarRow(
                title: channel.name,
                symbol: "number",
                restricted: channel.isRestricted,
                unread: channel.unreadCount,
                mentions: channel.rowMentionCount
            )
            .tag(AppModel.Destination.channel(channel.id))
            .contextMenu { channelMenu(channel) }
        }
    }

    /// Lines a collapsed forum's unread topics up with the rows it shows when open.
    private static let collapsedTopicIndent: CGFloat = 16

    private func unreadTopics(in channel: ChannelSummary) -> [TopicSummary] {
        let generalChat = model.generalChatTopic(inChannel: channel.id)
        return (model.recentTopics[channel.id] ?? [])
            .filter { $0.unreadCount > 0 && $0.name != generalChat }
    }

    @ViewBuilder
    private func channelMenu(_ channel: ChannelSummary) -> some View {
        Button("Mark as Read") { Task { await model.markChannelRead(channel.id) } }
            .disabled(channel.unreadCount == 0)
        if channel.rendersAsForum {
            Button("All Topics") { model.destination = .channel(channel.id) }
            Button("New Topic…") { ui.newTopicChannel = ChannelSummaryBox(channel: channel) }
        }
        Divider()
        Button("Rename for Me…") {
            aliasDraft = model.alias(forChannel: channel.id) ?? ""
            renamingChannel = channel
        }
        Button("Hide Channel") { model.setHidden(true, forChannel: channel.id) }
        Button("Muted Topics…") { ui.mutedTopicsChannel = ChannelSummaryBox(channel: channel) }
        NotificationLevelMenu.channel(channel.id, model: model)
        Divider()
        Menu("Move to Group") {
            Button("Unfiled") { model.moveChannel(channel.id, toGroup: nil) }
                .disabled(currentGroupID == nil)
            ForEach(model.groups) { group in
                Button(group.name) { model.moveChannel(channel.id, toGroup: group.id) }
                    .disabled(currentGroupID == group.id)
            }
        }
        Picker("Show As", selection: Binding(
            get: { model.modeOverride(forChannel: channel.id) },
            set: { model.setMode($0, forChannel: channel.id) }
        )) {
            Text("Automatic").tag(ChannelMode?.none)
            ForEach(ChannelMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(ChannelMode?.some(mode))
            }
        }
    }

    /// A promoted topic gets exactly the row a channel gets. It is a channel as far as
    /// the sidebar is concerned; its origin rides underneath because the name alone
    /// rarely says where it lives.
    private func promotedRow(_ promoted: PromotedTopicSummary) -> some View {
        MacSidebarRow(
            title: promoted.displayName,
            subtitle: "#\(promoted.channelName)",
            symbol: "number",
            restricted: promoted.isRestricted,
            unread: promoted.unreadCount,
            mentions: promoted.mentionCount
        )
        .tag(AppModel.Destination.topic(
            channelID: promoted.channelID, name: promoted.topic, channelName: promoted.channelName
        ))
        .contextMenu {
            Button("Mark as Read") {
                Task {
                    await model.markConversationRead(.topic(
                        channelID: promoted.channelID, name: promoted.topic,
                        channelName: promoted.channelName
                    ))
                }
            }
            .disabled(promoted.unreadCount == 0)
            Divider()
            Button("Rename for Me…") {
                aliasDraft = promoted.displayName
                renamingPromoted = promoted
            }
            Button("Remove from Sidebar") {
                model.demote(topic: promoted.topic, inChannel: promoted.channelID)
            }
            NotificationLevelMenu.topic(promoted.topic, inChannel: promoted.channelID, model: model)
            Divider()
            Menu("Move to Group") {
                Button("Unfiled") {
                    model.setGroup(nil, forPromotedTopic: promoted.topic, inChannel: promoted.channelID)
                }
                .disabled(currentGroupID == nil)
                ForEach(model.groups) { group in
                    Button(group.name) {
                        model.setGroup(group.id, forPromotedTopic: promoted.topic, inChannel: promoted.channelID)
                    }
                    .disabled(currentGroupID == group.id)
                }
            }
        }
    }

    private var entries: [SidebarEntry] {
        SidebarEntry.merged(channels: channels, promoted: promoted)
    }

    private var listTitle: String {
        switch ui.section {
        case .dms: "Direct Messages"
        case .unfiled: model.groups.isEmpty ? "Channels" : "Unfiled"
        case .group(let id): model.groups.first { $0.id == id }?.name ?? "Channels"
        }
    }

    private var emptyListMessage: String {
        switch ui.section {
        case .group: "No channels in this group yet. Right-click its icon on the rail to edit it."
        case .unfiled: model.allChannels.isEmpty ? "Syncing your channels…" : "Every channel is filed into a group."
        case .dms: ""
        }
    }

    private var currentGroupID: String? {
        if case .group(let id) = ui.section { id } else { nil }
    }

    /// A forum stays open once opened, because on a Mac the list is on screen the whole
    /// time and re-opening it on every visit would be busywork.
    private func binding(forChannel id: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func observe() async {
        guard ui.section != .dms, let writer = model.databaseWriter else { return }
        let groupID = currentGroupID

        promotedTask?.cancel()
        if let observation = model.promotedTopicObservation(inGroup: groupID) {
            promotedTask = Task {
                do {
                    for try await rows in observation.removeDuplicates().values(in: writer) { promoted = rows }
                } catch {}
            }
        }
        guard let observation = model.channelObservation(inGroup: groupID) else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) { channels = rows }
        } catch {
            // Observation ends when the section changes; nothing to recover.
        }
    }

    /// Where a destination lives in the rail, so opening something from outside the
    /// sidebar — the quick switcher, a notification — shows it selected rather than
    /// leaving the sidebar on an unrelated group.
    private func section(for destination: AppModel.Destination) -> SidebarSection {
        MacShellView.section(for: destination, model: model)
    }

    static func section(for destination: AppModel.Destination, model: AppModel) -> SidebarSection {
        switch destination {
        case .dm:
            return .dms
        case .channel(let id):
            return model.group(containingChannel: id).map(SidebarSection.group) ?? .unfiled
        case .topic(let channelID, let name, _):
            if let promotion = model.promotedTopics.first(where: {
                $0.channelID == channelID && $0.topic == name
            }) {
                return promotion.groupID.map(SidebarSection.group) ?? .unfiled
            }
            return model.group(containingChannel: channelID).map(SidebarSection.group) ?? .unfiled
        }
    }
}

// MARK: - Rows

/// One line of the Mac sidebar. A lock rides after the name rather than as a badge on an
/// icon, which at this size collided with the icon it was meant to annotate.
struct MacSidebarRow: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var restricted = false
    var unread = 0
    var mentions = 0

    /// Read rows sit back in gray and an unread one lights up with a dot beside it, so
    /// what is new stands out without a column of counts.
    private var isUnread: Bool { unread > 0 }

    var body: some View {
        HStack(spacing: 7) {
            UnreadDot(visible: isUnread)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isUnread ? Color.primary : SidebarTone.readIcon)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.body.weight(isUnread ? .semibold : .regular))
                        .foregroundStyle(isUnread ? Color.primary : SidebarTone.readTitle)
                        .lineLimit(1)
                    if restricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Only a mention is counted: it is addressed to you.
            if mentions > 0 {
                Badge(count: mentions, mention: true)
            }
        }
        .padding(.vertical, 1)
    }
}

struct MacDMRow: View {
    let dm: DMSummary
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 9) {
            SenderAvatar(
                name: model.title(forDM: dm.dmKey),
                userID: model.soleParticipant(inDM: dm.dmKey),
                size: 30
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(forDM: dm.dmKey))
                    .font(.body.weight(dm.unreadCount > 0 ? .semibold : .regular))
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
        .padding(.vertical, 2)
    }
}

private struct MacTopicRow: View {
    let topic: TopicSummary
    let channel: ChannelSummary
    let groupID: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        MacSidebarRow(
            title: topic.name.isEmpty ? "general chat" : topic.name,
            unread: topic.unreadCount
        )
        .tag(AppModel.Destination.topic(
            channelID: channel.id, name: topic.name, channelName: channel.name
        ))
        .contextMenu {
            Button("Mark as Read") {
                Task {
                    await model.markConversationRead(.topic(
                        channelID: channel.id, name: topic.name, channelName: channel.name
                    ))
                }
            }
            .disabled(topic.unreadCount == 0)
            Button("Promote to Sidebar") {
                model.promote(topic: topic.name, inChannel: channel.id, toGroup: groupID)
            }
            NotificationLevelMenu.topic(topic.name, inChannel: channel.id, model: model)
        }
    }
}

/// The topics under one forum channel, nested in the sidebar rather than pushed onto a
/// second screen. Only the most recent few: the channel's own page lists them all.
private struct MacTopicRows: View {
    let channel: ChannelSummary
    let groupID: String?

    @Environment(AppModel.self) private var model
    @State private var topics: [TopicSummary] = []
    @State private var loaded = false

    private static let shown = 8

    var body: some View {
        Group {
            if topics.isEmpty {
                // A placeholder, not nothing: the observation hangs off this view, and a
                // `ForEach` over an empty array produces no view to hang it on — so with
                // nothing here an expanded forum never loads its own topics.
                Text(loaded ? "No topics yet" : "Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            } else {
                ForEach(shownTopics) { topic in
                    MacTopicRow(topic: topic, channel: channel, groupID: groupID)
                }
                if topics.count > Self.shown {
                    Button {
                        model.destination = .channel(channel.id)
                    } label: {
                        Text("All \(topics.count) topics…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
            }
        }
        .task(id: channel.id) { await observe() }
    }

    /// The most recent few, plus any older topic still unread. The channel's own row is
    /// general chat, so it is not listed again here.
    private var shownTopics: [TopicSummary] {
        let generalChat = model.generalChatTopic(inChannel: channel.id)
        let listed = topics.filter { $0.name != generalChat }
        return Array(listed.prefix(Self.shown))
            + listed.dropFirst(Self.shown).filter { $0.unreadCount > 0 }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.topics(inChannel: channel.id)
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                topics = rows
                loaded = true
            }
        } catch {}
    }
}

// MARK: - Rail

/// Direct messages, then the groups, then whatever is unfiled, then a plus — the same
/// order the phone's rail has, drawn narrower.
struct MacRail: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @State private var dropTarget: String?

    static let width: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                railButton(
                    active: ui.section == .dms,
                    unread: model.dms.contains { $0.unreadCount > 0 },
                    // Every direct message is addressed to you, so each unread one counts.
                    mentions: model.dms.reduce(0) { $0 + $1.unreadCount }
                ) {
                    ui.section = .dms
                } label: {
                    MacRailIcon(systemImage: "bubble.left.and.bubble.right.fill", active: ui.section == .dms)
                }
                .help("Direct Messages  ⌘1")

                Divider().frame(width: 26)

                ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                    railButton(
                        active: ui.section == .group(group.id),
                        unread: group.unreadCount > 0,
                        mentions: group.mentionCount
                    ) {
                        ui.section = .group(group.id)
                    } label: {
                        MacGroupAvatar(name: group.name, icon: group.icon, active: ui.section == .group(group.id))
                    }
                    .help(index < 7 ? "\(group.name)  ⌘\(index + 3)" : group.name)
                    .draggable(group.id) {
                        MacGroupAvatar(name: group.name, icon: group.icon)
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first else { return false }
                        model.moveGroup(id, onto: group.id)
                        return true
                    } isTargeted: { targeted in
                        if targeted {
                            dropTarget = group.id
                        } else if dropTarget == group.id {
                            dropTarget = nil
                        }
                    }
                    .overlay {
                        if dropTarget == group.id {
                            RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .contextMenu {
                        Button("Edit Group…") { ui.editingGroup = MacUIState.GroupBox(id: group.id) }
                        NotificationLevelMenu.group(group.id, model: model)
                        Button("Delete Group", role: .destructive) {
                            if ui.section == .group(group.id) { ui.section = .unfiled }
                            model.deleteGroup(id: group.id)
                        }
                    }
                }

                if !model.groups.isEmpty { Divider().frame(width: 26) }

                railButton(
                    active: ui.section == .unfiled,
                    unread: model.unfiledHasUnread,
                    mentions: model.unfiledMentionCount
                ) {
                    ui.section = .unfiled
                } label: {
                    MacRailIcon(systemImage: "number", active: ui.section == .unfiled)
                }
                .help((model.groups.isEmpty ? "Channels" : "Unfiled Channels") + "  ⌘2")

                railButton(active: false, unread: false, mentions: 0) {
                    ui.showingNewGroup = true
                } label: {
                    MacRailIcon(systemImage: "plus")
                }
                .help("New Group  ⇧⌘G")
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        // The scroll view clips to its content, and a mention badge hangs off the
        // corner of a button on purpose; without this the count is cut in half.
        .scrollClipDisabled()
        .frame(width: Self.width)
        .scrollIndicators(.never)
        .background(.quaternary.opacity(0.35))
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
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 {
                        Text(mentions > 99 ? "99+" : "\(mentions)")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .fixedSize()
                            .offset(x: 4, y: 3)
                    }
                }
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: active ? 22 : (unread ? 8 : 0))
                        .offset(x: -12)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: active)
        .animation(.snappy(duration: 0.18), value: unread)
    }
}

struct MacRailIcon: View {
    let systemImage: String
    var active = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 40, height: 40)
            .background(
                active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: active ? 12 : 20)
            )
    }
}

/// The rail bubble for a group: its icon, or its initials when it has none.
struct MacGroupAvatar: View {
    let name: String
    let icon: Data?
    var size: CGFloat = 40
    var active = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: active ? size * 0.3 : size * 0.5)
        Group {
            if let icon, let image = Platform.image(from: icon) {
                image.resizable().scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            if active && icon != nil { shape.stroke(Color.accentColor, lineWidth: 2) }
        }
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

// MARK: - Footer

/// Who is signed in and whether the queue is live, at the bottom of the sidebar where
/// every Mac chat client keeps it.
struct MacSidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    var body: some View {
        HStack(spacing: 8) {
            SenderAvatar(name: selfName, userID: model.selfUserID, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(selfName).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    SyncDot(status: model.status)
                    Text(statusLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Hidden Channels…") { ui.showingHidden = true }
                SettingsLink { Text("Settings…") }
                Divider()
                Button("Sign Out…") { ui.confirmingSignOut = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Account and settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var selfName: String {
        model.selfUserID.flatMap { model.users[$0]?.fullName } ?? model.account?.email ?? "You"
    }

    private var statusLabel: String {
        switch model.status {
        case .live: model.account?.realmURL.host() ?? "Connected"
        case .connecting: "Connecting…"
        case .failed(let message): message
        case .idle: "Not connected"
        }
    }
}
