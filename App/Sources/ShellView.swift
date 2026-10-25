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

    @State private var section: ShellSection = .unfiled
    @State private var confirmingMarkAllRead = false
    @State private var showingHidden = false
    @State private var showingNotifications = false
    @State private var showingSettings = false
    @State private var showingReorder = false
    @State private var reorderingGroups = false
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
    /// Where the page's navigation bar ends, from the top of the screen.
    @State private var pageBarBottom: CGFloat = 0

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

    /// The list's header is exactly as tall as the page's navigation bar, so the two read
    /// as one bar across the screen rather than two bars of different heights side by
    /// side. The bar's height changes with the display and the pose, so it is measured.
    private var headerHeight: CGFloat {
        guard pageBarBottom > space.top else { return Self.fallbackHeaderHeight }
        return max(Self.minimumHeaderHeight, pageBarBottom - space.top)
    }

    private static let minimumHeaderHeight: CGFloat = 44
    private static let fallbackHeaderHeight: CGFloat = 52
    private static let railButtonSize: CGFloat = 46

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
            // The first button sits on the line the header and the page's title share.
            .padding(.top, max(4, (headerHeight - Self.railButtonSize) / 2))
            .padding(.bottom, 12)
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

    private var listTitle: String { model.title(of: section) }

    /// Floats over the list the way the page's navigation bar floats over a conversation,
    /// at the same height, so the rows scroll under both alike.
    private var listHeader: some View {
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
        .frame(height: headerHeight)
    }

    private var list: some View {
        SectionList(section: section, open: openFromDrawer, showingReorder: $showingReorder)
            .safeAreaBar(edge: .top, spacing: 0) { listHeader }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Filling the screen, the list runs on under the status bar beside it rather than
            // leaving a strip of a different colour there.
            .background(DrawerPalette.list.ignoresSafeArea(edges: drawerFillsScreen ? [.vertical, .trailing] : .vertical))
    }

    /// Opening anything from the drawer slides it shut on what was opened.
    private func openFromDrawer(_ destination: AppModel.Destination) {
        model.destination = destination
        path = []
        setOpen(false)
    }

    // MARK: content

    private var content: some View {
        NavigationStack(path: $path) {
            DestinationView(destination: model.destination)
                .background {
                    PageBarProbe { bars in
                        barsRunDownTheSide = bars.runDownTheSide
                        pageBarBottom = bars.bottom
                    }
                }
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
        .sheet(isPresented: $reorderingGroups) { ReorderGroupsView(groups: model.groups) }
        .sheet(item: Binding(get: { editingGroup.map(Identified.init) },
                             set: { editingGroup = $0?.value })) { wrapper in
            GroupEditor(groupID: wrapper.value)
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

}

/// The page's navigation bars, as the shell needs them.
private struct PageBars: Equatable {
    /// Whether the bars run down the side of the screen, as on a foldable's outer display.
    var runDownTheSide = false
    /// Where the navigation bar ends, measured from the top of the screen.
    var bottom: CGFloat = 0
}

/// Reports the page's bars from inside the navigation stack, the only place the toolbar
/// environment is set and the bar's height shows in the safe area.
private struct PageBarProbe: View {
    let changed: (PageBars) -> Void
    @State private var bars = PageBars()

    var body: some View {
        Group {
            if #available(iOS 27.1, *) {
                EdgeReader { bars.runDownTheSide = $0 }
            }
        }
        // Spread over the whole page, so the top of its safe area is the bottom of the bar.
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { bars.bottom = $0 }
        }
        .onChange(of: bars, initial: true) { _, bars in changed(bars) }
    }

    @available(iOS 27.1, *)
    private struct EdgeReader: View {
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
    /// What the status bar or sensor housing covers above the shell.
    var top: CGFloat = 0
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
        top = proxy.safeAreaInsets.top
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
