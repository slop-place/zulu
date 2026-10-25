import SwiftUI
import ZuluStore

/// Picks the shell for the device. A foldable gets the native one: the system's tab bar,
/// which its displays run down the side, and a split view that sits the list beside the
/// conversation when open and pushes one onto the other when closed. Every other phone
/// keeps the drawer unless the tab bar layout is turned on in Settings.
///
/// A foldable is known by its hinge, and only once one has reported, so the choice is
/// remembered: the first launch on a foldable shows the drawer for a moment, later ones
/// open straight onto the native shell.
struct ShellChooser: View {
    @AppStorage(ShellLayout.foldableKey) private var hasHinge = false
    @AppStorage(ShellLayout.tabBarKey) private var prefersTabBar = false

    var body: some View {
        Group {
            if hasHinge || prefersTabBar {
                NativeShellView()
            } else {
                ShellView()
            }
        }
        .background { HingeProbe { hasHinge = true } }
    }
}

private struct HingeProbe: View {
    let found: () -> Void

    var body: some View {
        if #available(iOS 27.1, *) {
            Color.clear.onHingeChange { _, context in
                if context.hinge != nil { found() }
            }
        }
    }
}

/// The native shell.
///
/// Each tab is one section of the drawer's rail and keeps its own conversation, the way
/// each mailbox in Mail keeps its own message: switching to Direct Messages and back
/// finds the channel conversation where it was left.
///
/// All groups share one tab, so the bar never grows past five: a tab bar holds no more
/// on an ordinary iPhone, and a tab per group ran on for as long as groups were added.
/// The tab shows one group at a time and is named after it; a button in its list's bar
/// switches to another. A tab cannot open a menu itself: long-pressing one in the bar
/// down a foldable's side shows its name enlarged instead.
struct NativeShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationServiceSettings.self) private var notifications
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale

    enum ShellTab: Hashable {
        case section(ShellSection)
        /// Whichever group the Groups tab is showing.
        case groups
        /// Every channel, or only those in no group, as Settings chooses.
        case channels
        case settings
    }

    @AppStorage(ChannelsTabMode.storageKey) private var channelsTab = ChannelsTabMode.standard

    private var channelsSection: ShellSection { channelsTab == .all ? .all : .unfiled }

    /// The group the Groups tab shows, kept across launches.
    @AppStorage("shell.currentGroup") private var currentGroupID = ""

    @State private var selection: ShellTab = .channels
    /// The conversation each section was last showing.
    @State private var opened: [ShellSection: AppModel.Destination] = [:]
    /// Closed, whether each section is showing its list or its conversation.
    @State private var compactColumns: [ShellSection: NavigationSplitViewColumn] = [:]
    /// Topics opened from a channel's topic list, on top of the section's conversation.
    @State private var paths: [ShellSection: [ConversationView.Source]] = [:]

    @State private var showingReorderChannels = false
    @State private var reorderingGroups = false
    @State private var editingGroup: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var confirmingMarkAllRead = false
    @State private var deletingGroup: ChannelGroupSummary?

    /// The chosen group, or the first one when that has been deleted or none was chosen.
    private var currentGroup: ChannelGroupSummary? {
        model.groups.first { $0.id == currentGroupID } ?? model.groups.first
    }

    private var currentSection: ShellSection? {
        switch selection {
        case .section(let section): section
        case .groups: currentGroup.map { .group($0.id) }
        case .channels: channelsSection
        case .settings: nil
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Recent", systemImage: "clock", value: ShellTab.section(.recent)) {
                split(.recent)
            }
            .contextMenu {
                Button("Mark all as read…", systemImage: "checkmark.circle") { confirmingMarkAllRead = true }
            }

            Tab("Direct Messages", systemImage: "bubble.left.and.bubble.right", value: ShellTab.section(.dms)) {
                split(.dms)
            }
            // Every direct message is addressed to you, so each unread one counts.
            .badge(model.dms.reduce(0) { $0 + $1.unreadCount })

            if let group = currentGroup {
                Tab(value: ShellTab.groups) {
                    split(.group(group.id))
                } label: {
                    // Named after the group it shows, so the bar says where the tab leads.
                    Label {
                        Text(group.name)
                    } icon: {
                        Image(uiImage: GroupTabIcon.image(for: group))
                    }
                }
                // Every group's mentions, the hidden ones' included: the tab is the only
                // way to them.
                .badge(model.groups.reduce(0) { $0 + $1.mentionCount })
            }

            Tab(title(of: channelsSection), systemImage: "number", value: ShellTab.channels) {
                split(channelsSection)
            }
            .badge(channelsBadge)

            Tab("Settings", systemImage: "gearshape", value: ShellTab.settings) {
                SettingsView(showsDone: false)
            }
        }
        .onAppear {
            // Whatever was open when the app last closed, in the section it opens on.
            if let destination = model.destination, let section = currentSection, opened[section] == nil {
                opened[section] = destination
            }
        }
        .onChange(of: currentSection) { _, section in
            // The model's destination is the conversation on screen: the tab's own, or
            // none while Settings is up.
            guard let section else {
                model.destination = nil
                return
            }
            if model.destination != opened[section] { model.destination = opened[section] }
        }
        // Opened from outside the list: a tapped notification, a link, "All topics".
        .onChange(of: model.destination) { _, destination in
            guard let destination else { return }
            let section = currentSection ?? .recent
            if currentSection == nil { selection = .section(section) }
            guard opened[section] != destination else { return }
            paths[section] = []
            opened[section] = destination
            compactColumns[section] = .detail
        }
        .confirmationDialog(
            "Delete “\(deletingGroup?.name ?? "")”?",
            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible,
            presenting: deletingGroup
        ) { group in
            Button("Delete Group", role: .destructive) { model.deleteGroup(id: group.id) }
        } message: { _ in
            Text("Its channels are kept. Nothing changes on the server.")
        }
        // The last group gone, its tab goes too; whoever was on it lands on the channels.
        .onChange(of: model.groups.isEmpty) { _, isEmpty in
            if isEmpty, selection == .groups { selection = .channels }
        }
        .onChange(of: model.pendingGroupToEdit) { _, id in
            guard let id else { return }
            editingGroup = id
            show(group: id)
            model.pendingGroupToEdit = nil
        }
        .sheet(isPresented: $reorderingGroups) { ReorderGroupsView(groups: model.groups) }
        .sheet(item: Binding(get: { editingGroup.map(IdentifiedGroup.init) },
                             set: { editingGroup = $0?.id })) { group in
            GroupEditor(groupID: group.id)
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
    }

    /// One section: its list, and the conversation it has open.
    private func split(_ section: ShellSection) -> some View {
        NavigationSplitView(preferredCompactColumn: compactColumn(for: section)) {
            SectionList(
                section: section,
                open: { open($0, in: section) },
                showingReorder: $showingReorderChannels
            )
            .navigationTitle(title(of: section))
            .navigationSubtitle(syncSubtitle)
            // The large title on the row the bar's buttons sit on, rather than a row of its
            // own below them, which left a band of nothing above every list.
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { listMenu(for: section) }
            // Black like the conversation beside it, rather than the system's grey
            // sidebar, with a hairline where one ends and the other begins.
            .background(Platform.canvas.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                // Closed, the list has the screen to itself and there is nothing to divide.
                if horizontalSizeClass == .regular {
                    Rectangle()
                        .fill(DrawerPalette.edge)
                        .frame(width: 1 / displayScale)
                        .ignoresSafeArea()
                }
            }
        } detail: {
            // One stack for the section's whole life, with only the conversation in it
            // replaced. A new stack per conversation was laid out once as if the sidebar
            // were not there, and every message jumped sideways on its first frame.
            NavigationStack(path: path(for: section)) {
                DestinationView(
                    destination: opened[section],
                    prompt: section == .dms ? "Pick a conversation to start reading." : "Pick a channel to start reading."
                )
                .navigationDestination(for: ConversationView.Source.self) { source in
                    ConversationView(source: source)
                }
            }
            .modifier(MeasuresPageSideInsets())
            .environment(\.isCoveredByList, coversWithList(section))
            // Closed, a conversation has the screen to itself: the tabs belong to the
            // list it was opened from, and are a back swipe away. Only while it shows:
            // the collapsed split view carries the detail's bars onto the list as well.
            .toolbar(conversationCoversList(in: section) ? .hidden : .automatic, for: .tabBar)
        }
    }

    /// Closed, with the list on screen over the conversation behind it.
    private func coversWithList(_ section: ShellSection) -> Bool {
        horizontalSizeClass == .compact && compactColumns[section] != .detail
    }

    private func conversationCoversList(in section: ShellSection) -> Bool {
        horizontalSizeClass == .compact && compactColumns[section] == .detail && opened[section] != nil
    }

    /// Every group, to switch to, and what can be done to them.
    @ViewBuilder
    private var groupMenu: some View {
        Picker("Group", selection: Binding(
            get: { currentGroup?.id ?? "" },
            set: { show(group: $0) }
        )) {
            ForEach(model.groups) { group in
                // What is waiting in each, so the one to go to next is plain from here.
                Label {
                    Text(group.name)
                    if group.mentionCount > 0 {
                        Text(group.mentionCount == 1 ? "1 mention" : "\(group.mentionCount) mentions")
                    } else if group.unreadCount > 0 {
                        Text("Unread")
                    }
                } icon: {
                    Image(uiImage: GroupTabIcon.image(for: group))
                }
                .tag(group.id)
            }
        }
        .pickerStyle(.inline)
        Section {
            Button("New Group…", systemImage: "folder.badge.plus") {
                newGroupName = ""
                creatingGroup = true
            }
            if let group = currentGroup {
                Button("Edit “\(group.name)”…", systemImage: "pencil") { editingGroup = group.id }
            }
            Button("Reorder Groups…", systemImage: "arrow.up.arrow.down") { reorderingGroups = true }
                .disabled(model.groups.count < 2)
        }
        if let group = currentGroup {
            Section {
                Button("Delete “\(group.name)”…", systemImage: "trash", role: .destructive) {
                    deletingGroup = group
                }
            }
        }
    }

    /// Channels in no group are "Ungrouped" beside a Groups tab; with no groups, they are
    /// simply the channels.
    private func title(of section: ShellSection) -> String {
        if section == .unfiled, !model.groups.isEmpty { return "Ungrouped" }
        return model.title(of: section)
    }

    private var channelsBadge: Int {
        switch channelsTab {
        case .all: model.allChannels.reduce(0) { $0 + $1.mentionCount }
        case .ungrouped: model.unfiledMentionCount
        }
    }

    private func show(group id: String) {
        currentGroupID = id
        selection = .groups
    }

    private func path(for section: ShellSection) -> Binding<[ConversationView.Source]> {
        Binding(
            get: { paths[section] ?? [] },
            set: { paths[section] = $0 }
        )
    }

    private func compactColumn(for section: ShellSection) -> Binding<NavigationSplitViewColumn> {
        Binding(
            get: { compactColumns[section] ?? .sidebar },
            set: { compactColumns[section] = $0 }
        )
    }

    /// A conversation opened, or a topic opened from a channel's list, starts the stack
    /// over rather than pushing onto whatever was there.
    private func open(_ destination: AppModel.Destination, in section: ShellSection) {
        paths[section] = []
        opened[section] = destination
        compactColumns[section] = .detail
        model.destination = destination
    }

    /// Said only when it is not live, the way Mail says it is checking for mail.
    private var syncSubtitle: String {
        switch model.status {
        case .live: ""
        case .connecting: "Connecting…"
        case .failed: "Offline"
        case .idle: "Not connected"
        }
    }

    @ToolbarContentBuilder
    private func listMenu(for section: ShellSection) -> some ToolbarContent {
        if case .group = section {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Groups", systemImage: "square.stack") { groupMenu }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                if case .group = section, let group = currentGroup {
                    Button("Edit “\(group.name)”…", systemImage: "pencil") { editingGroup = group.id }
                    Button("Delete “\(group.name)”…", systemImage: "trash", role: .destructive) {
                        deletingGroup = group
                    }
                }
                Button("New group…", systemImage: "folder.badge.plus") {
                    newGroupName = ""
                    creatingGroup = true
                }
                if section != .recent, section != .dms {
                    Button("Reorder channels", systemImage: "arrow.up.arrow.down") { showingReorderChannels = true }
                }
                Button("Reorder groups", systemImage: "arrow.up.arrow.down.square") { reorderingGroups = true }
                    .disabled(model.groups.count < 2)
                Divider()
                Button("Mark all as read…", systemImage: "checkmark.circle") { confirmingMarkAllRead = true }
            }
        }
    }

    /// `sheet(item:)` needs something Identifiable, and a bare String is not.
    private struct IdentifiedGroup: Identifiable {
        let id: String
    }
}

/// A group's mark in the tab bar: its icon in a circle, or its initials in an outlined
/// square tinted like the system's own symbols.
@MainActor
enum GroupTabIcon {
    private static var cache: [String: UIImage] = [:]
    private static let side: CGFloat = 26

    static func image(for group: ChannelGroupSummary) -> UIImage {
        let key = "\(group.id)|\(group.name)|\(group.icon?.hashValue ?? 0)"
        if let cached = cache[key] { return cached }
        let image = group.icon.flatMap(UIImage.init(data:)).map(photo) ?? initials(group.initials)
        cache[key] = image
        return image
    }

    private static func photo(_ source: UIImage) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let image = UIGraphicsImageRenderer(size: rect.size).image { _ in
            UIBezierPath(ovalIn: rect).addClip()
            let scale = max(side / source.size.width, side / source.size.height)
            let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                   width: size.width, height: size.height))
        }
        // A photo stays a photo; the tab bar would otherwise flatten it to a silhouette.
        return image.withRenderingMode(.alwaysOriginal)
    }

    private static func initials(_ text: String) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let image = UIGraphicsImageRenderer(size: rect.size).image { _ in
            let frame = UIBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 7)
            frame.lineWidth = 2
            UIColor.black.setStroke()
            frame.stroke()
            let font = UIFont.systemFont(ofSize: text.count > 1 ? 10 : 12, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2),
                withAttributes: attributes
            )
        }
        // Tinted like every other tab, selected or not.
        return image.withRenderingMode(.alwaysTemplate)
    }
}

extension EnvironmentValues {
    /// True while a closed foldable shows the list in front of this conversation, whose
    /// toolbar items would otherwise show over the list.
    @Entry var isCoveredByList = false
}

/// What the channels tab lists, chosen in Settings.
enum ChannelsTabMode: String, CaseIterable, Identifiable {
    /// Every channel, grouped or not, so there is one place to browse them all.
    case all
    /// Only the channels no group has claimed, so each channel has one home.
    case ungrouped

    static let storageKey = "shell.channelsTab"
    static let standard = ChannelsTabMode.all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All channels"
        case .ungrouped: "Channels in no group"
        }
    }
}

/// Where the choice of shell is kept.
enum ShellLayout {
    /// Set once a hinge has been seen: a foldable always gets the tab bar layout.
    static let foldableKey = "shell.nativeOnFoldable"
    /// The tab bar layout on a phone without a hinge, from Settings.
    static let tabBarKey = "shell.tabBarLayout"
}
