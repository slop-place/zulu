import GRDB
import SwiftUI
import ZuluStore
import ZuluSync

/// The drawer shell, wired to the store. Structure follows the nav-shell prototype:
/// a rail, a channel list, and a message page that slides off them.
///
/// Where there is room for both, the open inner display of a foldable or an iPad, the
/// drawer docks beside the page instead. It is the same drawer and the same page either
/// way, so folding or unfolding keeps the conversation, its scroll position and its draft.
struct ShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationServiceSettings.self) private var notifications
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Section: Equatable, Hashable {
        /// Every conversation that moved lately, newest first, whichever section it is in.
        case recent
        case dms
        case group(String)
        /// Channels no group has claimed, so filing is optional rather than required.
        case unfiled
    }

    @State private var section: Section = .unfiled
    @State private var visibleChannels: [ChannelSummary] = []
    @State private var visiblePromoted: [PromotedTopicSummary] = []
    /// Resolved once per change rather than per render: each row's preview is a parse of
    /// rendered HTML.
    @State private var recentEntries: [RecentEntry] = []
    @State private var confirmingMarkAllRead = false
    /// Hidden channels with a mention waiting, surfaced so the rail's count can be answered.
    @State private var mentionedHidden: [ChannelSummary] = []
    @State private var renamingChannel: ChannelSummary?
    @State private var aliasDraft = ""
    @State private var promotedTask: Task<Void, Never>?
    @State private var mentionedHiddenTask: Task<Void, Never>?
    @State private var showingHidden = false
    @State private var showingNotifications = false
    @State private var showingSettings = false
    @State private var mutedTopicsChannel: ChannelSummary?
    @State private var showingReorder = false
    @State private var reorderingGroups = false
    @State private var renamingPromoted: PromotedTopicSummary?
    @State private var editingGroup: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var confirmingSignOut = false
    @State private var open = true
    @State private var drag: CGFloat = 0
    @State private var drawerVisible = true
    @State private var path: [ConversationView.Source] = []
    @State private var space = ShellSpace()
    /// Docked, the sidebar can still be put away to read a conversation full width.
    @State private var sidebarCollapsed = false
    /// Set from inside the page, where the toolbar environment is.
    @State private var barsRunDownTheSide = false

    private let railW: CGFloat = 80
    private let listW: CGFloat = 236
    private var drawerW: CGFloat { railW + listW }

    /// How far the page has slid off the drawer. Always zero while docked, where the page
    /// sits beside the drawer rather than on top of it.
    private var offset: CGFloat {
        guard !docked else { return 0 }
        return min(max((open ? slideDistance : 0) + drag, 0), slideDistance)
    }

    /// Filling the screen, the drawer pushes the page all the way off it, past the bars
    /// down its side as well, or a strip of the page would show through under them.
    private var slideDistance: CGFloat {
        drawerFillsScreen ? sidebarWidth + space.trailing : sidebarWidth
    }

    /// The page casts a shadow on the drawer while it is aside. Pushed right off a screen
    /// the drawer fills, it fades out on the way, or it would linger along the edge.
    private var pageShadowOpacity: Double {
        guard offset > 0 else { return 0 }
        guard drawerFillsScreen, slideDistance > 0 else { return 0.28 }
        return 0.28 * max(0, 1 - offset / slideDistance)
    }

    /// Where the page's bars run down the side of the screen, as on a foldable's closed
    /// outer display, a strip of conversation left beside the drawer would sit under them.
    /// The drawer takes the whole screen there instead: the channel list or the
    /// conversation, one at a time.
    private var drawerFillsScreen: Bool { !docked && barsRunDownTheSide }

    /// Narrower than this, a conversation beside the sidebar wraps like a phone held
    /// sideways, and the drawer serves better.
    private static let minimumDockedPageWidth: CGFloat = 420

    /// Both size classes regular, so a phone in landscape keeps its drawer: only its width
    /// is regular there, and its height has no room to spare for a second column's chrome.
    private var docked: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
            && space.width >= drawerW + Self.minimumDockedPageWidth
    }

    private var sidebarShown: Bool { docked && !sidebarCollapsed }

    /// Whether the drawer is on screen to be used, docked or slid out.
    private var drawerShown: Bool { docked ? !sidebarCollapsed : drawerVisible }

    /// The fold, when the device is folded like a book and the fold leaves a sensible
    /// sidebar on one side and a sensible page on the other.
    private var bookFold: ClosedRange<CGFloat>? {
        guard docked, let fold = space.fold,
              fold.lowerBound >= drawerW,
              space.width - fold.upperBound >= Self.minimumDockedPageWidth * 0.8
        else { return nil }
        return fold
    }

    /// Folded like a book, the sidebar takes the left page and the conversation the right,
    /// so the fold divides them instead of running through the middle of the messages.
    private var sidebarWidth: CGFloat {
        if drawerFillsScreen, space.width > drawerW { return space.width }
        return bookFold?.lowerBound ?? drawerW
    }

    private var pageLeading: CGFloat {
        guard sidebarShown else { return 0 }
        return bookFold?.upperBound ?? sidebarWidth
    }

    private static let slide = Animation.snappy(duration: 0.24, extraBounce: 0)

    private func setOpen(_ value: Bool) {
        if value {
            drawerVisible = true
            dismissKeyboard()
        }
        withAnimation(Self.slide, completionCriteria: .removed) {
            open = value
            drag = 0
        } completion: {
            if !open { drawerVisible = false }
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
        // Measured on a view that only ever takes the space offered, with the shell laid
        // over it. The shell grows to fit its widest child, the drawer, which is sized from
        // this measurement: measured on the shell, a drawer as wide as the unfolded screen
        // held the shell at that width once the phone was folded again.
        Color.clear
            .onGeometryChange(for: ShellSpace.self) { ShellSpace($0) } action: { space = $0 }
            .overlay(alignment: .leading) { shell }
            // Simultaneous, not exclusive: a plain `.gesture` loses the opening swipe to the
            // conversation's own scroll view, which claims the touch first. On the whole
            // shell rather than the page, so a drawer filling the screen, with no page left
            // beside it to swipe, still closes with a swipe across itself.
            .simultaneousGesture(drawerDrag, including: docked ? .subviews : .all)
            .onChange(of: docked) { _, docked in
                guard !docked else { return }
                // Folding the phone shut: back to whatever was being read, or to the list
                // when nothing was. The drawer's last state was from before it docked.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    drag = 0
                    open = model.destination == nil
                    drawerVisible = open
                }
            }
            // Observed from here rather than from the list: a list observing only while
            // open showed its last state for a moment every time the drawer came back.
            .task(id: section) { await observeChannels() }
    }

    private var shell: some View {
        ZStack(alignment: .leading) {
            Color(.systemBackground).ignoresSafeArea()
            // Kept mounted so the swipe that reveals it doesn't stall on rebuilding the list.
            drawer
                .opacity(docked || drawerVisible ? 1 : 0)
                .allowsHitTesting(drawerShown)
                .accessibilityHidden(!drawerShown)
                .offset(x: docked && sidebarCollapsed ? -(sidebarWidth + 1) : 0)
            // One page in every layout, only moved and resized, so changing layout never
            // rebuilds the conversation on it.
            content
                .environment(\.pageSideInsets, HorizontalInsets(
                    leading: pageLeading > 0 ? 0 : space.leading,
                    trailing: space.trailing
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: offset > 0 ? 28 : 0)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(pageShadowOpacity), radius: 20, x: -8)
                        .ignoresSafeArea()
                }
                .offset(x: offset)
                .overlay {
                    if offset > sidebarWidth * 0.4 {
                        Color.black.opacity(0.001)
                            .onTapGesture { setOpen(false) }
                            .offset(x: offset)
                    }
                }
                .padding(.leading, pageLeading)
        }
    }

    private var drawerDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // Left-to-right belongs to the drawer; right-to-left is left
                // alone so row swipe actions keep it.
                guard open || value.translation.width > 0 else { return }
                if value.translation.width > 0, !drawerVisible {
                    drawerVisible = true
                    dismissKeyboard()
                }
                drag = value.translation.width
            }
            .onEnded { value in
                let projected = offset + value.predictedEndTranslation.width * 0.4
                setOpen(projected > slideDistance / 2)
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
            list.frame(width: sidebarWidth - railW - 1)
        }
        .frame(width: sidebarWidth)
        // Docked, the page needs the same hard edge the rail has. Against a fold it has
        // one already.
        .overlay(alignment: .trailing) {
            if docked, bookFold == nil {
                Rectangle()
                    .fill(DrawerPalette.edge)
                    .frame(width: 1)
                    .ignoresSafeArea(edges: .vertical)
            }
        }
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 12) {
                railButton(
                    active: section == .recent,
                    unread: model.dms.contains { $0.unreadCount > 0 }
                        || model.groups.contains { $0.unreadCount > 0 }
                        || model.unfiledHasUnread,
                    // Counted on the rows that own them, not again here.
                    mentions: 0
                ) { section = .recent } label: {
                    RailIcon(systemImage: "clock.fill", active: section == .recent)
                }
                .contextMenu {
                    Button("Mark all as read…", systemImage: "checkmark.circle") {
                        confirmingMarkAllRead = true
                    }
                }

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
        // Pinned under the groups, however many there are, where every chat app keeps it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(TextTone.secondary)
                    .frame(width: 46, height: 46)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(DrawerPalette.rail.ignoresSafeArea(edges: .bottom))
        }
        // Liquid Glass morphs beyond a controls bounds, and a ScrollView clips by
        // default, which shears the animation off mid-flight.
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .frame(width: railW)
        // Under whatever sits beside it too: a toolbar moved to the left edge in split
        // screen, or a phone's sensor housing in landscape.
        .background(DrawerPalette.rail.ignoresSafeArea(edges: [.vertical, .leading]))
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
        case .recent: "Recent"
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
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    Divider()
                    Button("Reorder channels", systemImage: "arrow.up.arrow.down") {
                        showingReorder = true
                    }
                    Button("Hidden channels", systemImage: "eye.slash") { showingHidden = true }
                    Button("Notifications", systemImage: "bell") { showingNotifications = true }
                    Divider()
                    Button("Sign out…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmingSignOut = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote)
                        .foregroundStyle(TextTone.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DrawerPalette.listHeader.ignoresSafeArea(edges: drawerFillsScreen ? .trailing : []))

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
        }
        // Filling the screen, the list runs on under the status bar beside it rather than
        // leaving a strip of a different colour there.
        .background(DrawerPalette.list.ignoresSafeArea(edges: drawerFillsScreen ? [.vertical, .trailing] : .vertical))
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
        case .group: "No channels in this group yet. Long-press its icon to edit."
        default: "Every channel is filed into a group."
        }
    }

    private func observeChannels() async {
        guard section != .dms else { return }
        if section == .recent {
            await observeRecent()
            return
        }
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
        if let hidden = model.mentionedHiddenChannelObservation(inGroup: groupID) {
            mentionedHiddenTask?.cancel()
            mentionedHiddenTask = Task {
                do {
                    for try await rows in hidden.removeDuplicates().values(in: writer) { mentionedHidden = rows }
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let conversation = destination.conversation {
                OpenInNewWindowButton(source: conversation)
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
            if let conversation = destination.conversation {
                OpenInNewWindowButton(source: conversation)
            }
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

    private func recentRow(_ entry: RecentEntry) -> some View {
        Button {
            model.destination = entry.destination
            path = []
            setOpen(false)
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

    // MARK: content

    private var content: some View {
        NavigationStack(path: $path) {
            destinationView
                .background { VerticalBarProbe { barsRunDownTheSide = $0 } }
                .navigationDestination(for: ConversationView.Source.self) { source in
                    ConversationView(source: source)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if docked {
                            Button(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.leading") {
                                withAnimation(Self.slide) { sidebarCollapsed.toggle() }
                            }
                        } else {
                            Button("Channels", systemImage: "line.3.horizontal") { setOpen(!open) }
                        }
                    }
                }
        }
        .sheet(isPresented: $showingHidden) { HiddenChannelsView() }
        .sheet(isPresented: $showingNotifications) { NotificationSettingsView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
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
        .confirmationDialog(
            "Sign out of \(model.account?.email ?? "this account")?",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task {
                    // The push service holds the account's key and would keep pushing for it.
                    await notifications.signOut()
                    await model.signOut()
                }
            }
        } message: {
            Text("Your channel groups, renames and hidden channels on this device are removed with it.")
        }
        .confirmationDialog(
            "Mark every message as read?",
            isPresented: $confirmingMarkAllRead,
            titleVisibility: .visible
        ) {
            Button("Mark All as Read", role: .destructive) {
                Task { await model.markAllRead() }
            }
        } message: {
            Text("Every channel, topic and direct message, here and on the server. This can't be undone.")
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

/// Reports whether the navigation bars around it run down the side of the screen, as
/// they do on a foldable's outer display. Read from inside the navigation stack, the only
/// place the toolbar environment is set.
private struct VerticalBarProbe: View {
    let changed: (Bool) -> Void

    var body: some View {
        if #available(iOS 27.1, *) {
            Reader(changed: changed)
        } else {
            Color.clear
        }
    }

    @available(iOS 27.1, *)
    private struct Reader: View {
        let changed: (Bool) -> Void
        @Environment(\.toolbarVerticalEdge) private var edge

        var body: some View {
            Color.clear.onChange(of: edge != nil, initial: true) { _, vertical in changed(vertical) }
        }
    }
}

/// The room the shell has, and where a fold divides it.
struct ShellSpace: Equatable {
    var width: CGFloat = 0
    /// The safe area's sides: what bars and sensor housings cover beside the shell.
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// The band the hinge occupies while the device is folded partway like a book, in the
    /// shell's own coordinates. Nil when it lies flat, is closed, or folds top to bottom:
    /// only a fold running down the screen can separate a sidebar from a page.
    var fold: ClosedRange<CGFloat>?

    init() {}

    init(_ proxy: GeometryProxy) {
        width = proxy.size.width
        leading = proxy.safeAreaInsets.leading
        trailing = proxy.safeAreaInsets.trailing
        if #available(iOS 27.1, *) {
            fold = proxy.reservedRegions(kind: .division)
                .map(\.frame)
                .first { $0.height > $0.width }
                .map { $0.minX...$0.maxX }
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
