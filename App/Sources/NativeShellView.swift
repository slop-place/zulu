import SwiftUI
import ZuluStore

/// Picks the shell for the device. A foldable gets the native one: the system's tab bar,
/// which its displays run down the side, and a split view that sits the list beside the
/// conversation when open and pushes one onto the other when closed. Every other phone
/// keeps the drawer for now.
///
/// A foldable is known by its hinge, and only once one has reported, so the choice is
/// remembered: the first launch on a foldable shows the drawer for a moment, later ones
/// open straight onto the native shell.
struct ShellChooser: View {
    @AppStorage("shell.nativeOnFoldable") private var hasHinge = false

    var body: some View {
        Group {
            if hasHinge {
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
struct NativeShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationServiceSettings.self) private var notifications
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum ShellTab: Hashable {
        case section(ShellSection)
        case settings
    }

    @State private var selection: ShellTab = .section(.unfiled)
    /// The conversation each section was last showing.
    @State private var opened: [ShellSection: AppModel.Destination] = [:]
    /// Closed, whether each section is showing its list or its conversation.
    @State private var compactColumns: [ShellSection: NavigationSplitViewColumn] = [:]

    @State private var showingReorderChannels = false
    @State private var reorderingGroups = false
    @State private var editingGroup: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var confirmingMarkAllRead = false

    private var currentSection: ShellSection? {
        if case .section(let section) = selection { section } else { nil }
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

            ForEach(model.groups) { group in
                Tab(value: ShellTab.section(.group(group.id))) {
                    split(.group(group.id))
                } label: {
                    Label {
                        Text(group.name)
                    } icon: {
                        Image(uiImage: GroupTabIcon.image(for: group))
                    }
                }
                .badge(group.mentionCount)
                .contextMenu {
                    Button("Edit group", systemImage: "pencil") { editingGroup = group.id }
                    NotificationLevelMenu.group(group.id, model: model)
                    Button("Reorder groups", systemImage: "arrow.up.arrow.down") { reorderingGroups = true }
                        .disabled(model.groups.count < 2)
                    Button("Delete group", systemImage: "trash", role: .destructive) {
                        if selection == .section(.group(group.id)) { selection = .section(.unfiled) }
                        model.deleteGroup(id: group.id)
                    }
                }
            }

            Tab(model.groups.isEmpty ? "Channels" : "Unfiled", systemImage: "number", value: ShellTab.section(.unfiled)) {
                split(.unfiled)
            }
            .badge(model.unfiledMentionCount)

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
        .onChange(of: selection) { _, selection in
            // The model's destination is the conversation on screen: the shell's own
            // tab's, or none while Settings is up.
            guard case .section(let section) = selection else {
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
            opened[section] = destination
            compactColumns[section] = .detail
        }
        .onChange(of: model.pendingGroupToEdit) { _, id in
            guard let id else { return }
            editingGroup = id
            selection = .section(.group(id))
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
            .navigationTitle(model.title(of: section))
            .navigationSubtitle(syncSubtitle)
            .toolbar { listMenu(for: section) }
        } detail: {
            let destination = opened[section]
            NavigationStack {
                DestinationView(
                    destination: destination,
                    prompt: section == .dms ? "Pick a conversation to start reading." : "Pick a channel to start reading."
                )
                    .navigationDestination(for: ConversationView.Source.self) { source in
                        ConversationView(source: source)
                    }
            }
            // A conversation opened, or a topic opened from a channel's list, starts the
            // stack over rather than pushing onto whatever was there.
            .id(destination)
            .modifier(MeasuresPageSideInsets())
            // Closed, a conversation has the screen to itself: the tabs belong to the
            // list it was opened from, and are a back swipe away. Only while it shows:
            // the collapsed split view carries the detail's bars onto the list as well.
            .toolbar(conversationCoversList(in: section) ? .hidden : .automatic, for: .tabBar)
        }
    }

    private func conversationCoversList(in section: ShellSection) -> Bool {
        horizontalSizeClass == .compact && compactColumns[section] == .detail && opened[section] != nil
    }

    private func compactColumn(for section: ShellSection) -> Binding<NavigationSplitViewColumn> {
        Binding(
            get: { compactColumns[section] ?? .sidebar },
            set: { compactColumns[section] = $0 }
        )
    }

    private func open(_ destination: AppModel.Destination, in section: ShellSection) {
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
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
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
