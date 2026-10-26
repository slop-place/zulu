import AppKit
import SwiftUI
import ZuluCompose
import ZuluScroll
import ZuluStore

// The Mac conversation is an `NSTableView` with a SwiftUI message in each cell, rather
// than a SwiftUI `LazyVStack`. Held to its newest message, the lazy stack measured its
// rows again backwards from the bottom on every frame, and that grew with every row it
// had ever shown: scrolling a long conversation went from 1 ms of main-thread time a
// frame to 50 ms within a minute of use. Here a row is measured once, before it scrolls
// into view, and scrolling only moves views that already exist.

/// One row of a conversation.
enum MacConversationRow: Equatable {
    /// Above the oldest message: a spinner while older history loads, the start of the
    /// conversation once it is all here, or just the list's top margin.
    case top(MacConversationTop)
    case message(GroupedMessage, reactions: [ReactionGroup], isFirstUnread: Bool)
    case pending(PendingEntry)

    enum ID: Hashable {
        case top
        case message(Int)
        case pending(UUID)
    }

    var id: ID {
        switch self {
        case .top: .top
        case .message(let entry, _, _): .message(entry.id)
        case .pending(let pending): .pending(pending.id)
        }
    }

    var messageID: Int? {
        if case .message(let entry, _, _) = self { entry.message.id } else { nil }
    }

    /// Cells are only reused for rows of the same kind, so a new row in a reused cell
    /// is a small change to the SwiftUI view in it rather than a different view.
    var reuseIdentifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .top: Self.topIdentifier
        case .message: Self.messageIdentifier
        case .pending: Self.pendingIdentifier
        }
    }

    private static let topIdentifier = NSUserInterfaceItemIdentifier("conversation.top")
    private static let messageIdentifier = NSUserInterfaceItemIdentifier("conversation.message")
    private static let pendingIdentifier = NSUserInterfaceItemIdentifier("conversation.pending")
}

enum MacConversationTop: Equatable {
    case loading
    case start(title: String)
    case margin
}

/// What a row reads from the window around it. Cells are hosted by AppKit, so none of
/// the conversation's SwiftUI environment reaches them unless it is handed over.
struct MacConversationCellContext {
    let model: AppModel
    let ui: MacUIState
    let previewer: AttachmentPreviewer
    let openURL: OpenURLAction
    let quickReactions: [QuickReaction]
    let source: ConversationSource
}

/// A row, as SwiftUI draws it.
struct MacConversationCellContent: View {
    let row: MacConversationRow
    let context: MacConversationCellContext

    static let horizontalPadding: CGFloat = 12
    static let topMargin: CGFloat = 12

    var body: some View {
        content
            .padding(.horizontal, Self.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(context.model)
            .environment(context.ui)
            .environment(context.previewer)
            .environment(\.openURL, context.openURL)
            .environment(\.macQuickReactions, context.quickReactions)
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .top(.margin):
            Color.clear.frame(height: Self.topMargin)
        case .top(.loading):
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .padding(.top, Self.topMargin)
        case .top(.start(let title)):
            MacConversationStart(title: title)
                .padding(.top, Self.topMargin)
        case .message(let entry, let reactions, let isFirstUnread):
            VStack(alignment: .leading, spacing: 0) {
                if entry.startsDay {
                    DayDivider(date: entry.message.date).padding(.top, 12)
                }
                if isFirstUnread {
                    UnreadDivider().padding(.top, 10)
                }
                MessageRow(message: entry.message, startsGroup: entry.startsGroup, reactions: reactions)
                    .padding(.top, entry.startsGroup ? 12 : 1)
                    .padding(.bottom, 1)
                    .macMessageActions(entry.message, in: context.source)
            }
        case .pending(let pending):
            PendingMessageRow(message: pending.entry, startsGroup: pending.startsGroup)
                .padding(.top, pending.startsGroup ? 12 : 1)
                .padding(.bottom, 1)
        }
    }
}

/// The top of history, so scrolling back ends at a statement rather than a blank.
struct MacConversationStart: View {
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkles").foregroundStyle(TextTone.tertiary)
            Text("This is the beginning of \(title).")
                .font(.callout)
                .foregroundStyle(TextTone.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// A row in its cell. It keeps its own height whatever the cell's, and says when that
/// height changes: an image arriving, a reaction landing, an edit.
private struct MacMeasuredRow: View {
    let content: MacConversationCellContent
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

final class MacConversationCell: NSTableCellView {
    private var host: NSHostingView<MacMeasuredRow>?
    private(set) var row: MacConversationRow?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        row: MacConversationRow,
        context: MacConversationCellContext,
        onHeight: @escaping (CGFloat) -> Void
    ) {
        self.row = row
        let content = MacMeasuredRow(content: MacConversationCellContent(row: row, context: context), onHeight: onHeight)
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            // The table decides the cell's size; the hosting view must not ask for one.
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.clipsToBounds = false
            addSubview(host)
            self.host = host
        }
        needsLayout = true
    }

    override func layout() {
        guard let host else { return }
        if host.frame != bounds { host.frame = bounds }
    }
}

/// Measures rows before they are shown, with one hosting controller kept for the
/// purpose so each measurement is a change to an existing view graph.
@MainActor
private final class MacRowMeasurer {
    private let controller = NSHostingController<MacConversationCellContent?>(rootView: nil)

    func height(of row: MacConversationRow, context: MacConversationCellContext, width: CGFloat) -> CGFloat {
        controller.rootView = MacConversationCellContent(row: row, context: context)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        controller.rootView = nil
        return max(1, ceil(size.height))
    }
}

/// Reports the reader's scrolling, which AppKit only announces for trackpad gestures and
/// the scroller: a mouse wheel scrolls without a word.
final class MacConversationScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

/// Holds the scroll view, and keeps its layout to itself while the reader scrolls.
///
/// A scroll marks the table for layout on every frame, and left alone that mark climbs
/// through every view above it into SwiftUI, which then lays out the whole window again:
/// sidebar, toolbar and all, once per frame. Stopped here, a scroll costs what the table
/// costs.
final class MacConversationContainer: NSView {
    let scrollView: MacConversationScrollView
    var isolatesLayout = false

    init(scrollView: MacConversationScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if newValue, isolatesLayout { return }
            super.needsLayout = newValue
        }
    }

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if newValue, isolatesLayout { return }
            super.needsUpdateConstraints = newValue
        }
    }

    /// SwiftUI gives the view its size; nothing inside should ask for another.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    override func layout() {
        super.layout()
        if scrollView.frame != bounds { scrollView.frame = bounds }
    }

    override var isFlipped: Bool { true }
}

/// What the conversation's SwiftUI chrome needs from the table, and the scrolls it asks
/// the table for.
@MainActor
@Observable
final class MacConversationScroll {
    /// Only changes when the button should appear or go.
    fileprivate(set) var showsJumpToNewest = false
    /// Close enough to the newest message to be reading it.
    fileprivate(set) var isNearBottom = false

    @ObservationIgnored fileprivate weak var coordinator: MacConversationTableCoordinator?

    func jumpToNewest() { coordinator?.followNewest(animated: true) }

    /// Sending always shows what was sent, even from partway up the history.
    func didSend() { coordinator?.followNewest(animated: false) }
}

struct MacConversationTable: NSViewRepresentable {
    let rows: [MacConversationRow]
    let context: MacConversationCellContext
    let scroll: MacConversationScroll
    let loader: MessageHistoryLoader
    let readTracker: ReadTracker?

    func makeCoordinator() -> MacConversationTableCoordinator {
        MacConversationTableCoordinator(
            context: context, scroll: scroll, loader: loader, readTracker: readTracker
        )
    }

    func makeNSView(context: Context) -> MacConversationContainer {
        let scrollView = MacConversationScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // SwiftUI already sizes the view to the space between the toolbar and the
        // composer; AppKit insetting it again for the window's safe area doubled it.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MacConversationTableCoordinator.bottomMargin, right: 0
        )

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.allowsColumnResizing = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        let container = MacConversationContainer(scrollView: scrollView)
        context.coordinator.attach(tableView: tableView, scrollView: scrollView, container: container)
        context.coordinator.apply(rows: rows)
        return container
    }

    func updateNSView(_ container: MacConversationContainer, context: Context) {
        context.coordinator.update(context: self.context)
        context.coordinator.apply(rows: rows)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacConversationContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ container: MacConversationContainer, coordinator: MacConversationTableCoordinator) {
        coordinator.detach()
    }
}

/// Owns the table: its rows, their heights, and where it is scrolled.
///
/// The decisions about following the newest message are `ConversationFollow`'s, shared
/// with the phone. This carries them out on an `NSTableView`, which, unlike a SwiftUI
/// scroll view, has no bottom anchor of its own: holding a followed list on its newest
/// message through every change is done here, as is holding a list being read on the
/// message at its top.
@MainActor
final class MacConversationTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let bottomMargin: CGFloat = 12

    var context: MacConversationCellContext
    private let scroll: MacConversationScroll
    private let loader: MessageHistoryLoader
    private let readTracker: ReadTracker?

    private weak var tableView: NSTableView?
    private weak var scrollView: MacConversationScrollView?
    private weak var container: MacConversationContainer?
    /// Measuring and the table changes it leads to wait for the end of the current pass:
    /// asked for from inside one of the table's own, they are re-entrant.
    private var measureScheduled = false

    private var rows: [MacConversationRow] = []
    /// Measured heights, at `measuredWidth`. A row without one is drawn at an estimate
    /// until it comes near the screen.
    private var heights: [MacConversationRow.ID: CGFloat] = [:]
    /// Measured, but changed while off screen since.
    private var stale: Set<MacConversationRow.ID> = []
    private var measuredWidth: CGFloat = 0
    private let measurer = MacRowMeasurer()

    private var follow: ConversationFollow
    private var isUserScrolling = false
    private var scrollEndTimer: Timer?
    /// Set while the coordinator moves the list itself, so the move is not read as the
    /// layout changing under it.
    private var isAdjusting = false
    private var reportedRead: Set<Int> = []
    private var reportedHeights: [MacConversationRow.ID: CGFloat] = [:]
    private var heightFlushScheduled = false
    private var observers: [any NSObjectProtocol] = []
    /// The first scroll waits for the table to have a size to measure rows against.
    private var hasOpened = false

    init(
        context: MacConversationCellContext,
        scroll: MacConversationScroll,
        loader: MessageHistoryLoader,
        readTracker: ReadTracker?
    ) {
        self.context = context
        self.scroll = scroll
        self.loader = loader
        self.readTracker = readTracker
        follow = ConversationFollow(opensAt: loader.firstUnreadID)
        super.init()
        scroll.coordinator = self
    }

    func attach(tableView: NSTableView, scrollView: MacConversationScrollView, container: MacConversationContainer) {
        self.tableView = tableView
        self.scrollView = scrollView
        self.container = container
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.onUserScroll = { [weak self] in self?.userScrolled() }

        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibleAreaMoved() }
            },
            // Posted from inside the table's own layout, where changing the table is
            // re-entrant: answered once that pass is over.
            center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleResize() }
            },
            // The scroller's knob and trackpad gestures announce themselves.
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled() }
            },
        ]
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollEndTimer?.invalidate()
    }

    // MARK: rows

    func apply(rows newRows: [MacConversationRow]) {
        guard let tableView else {
            rows = newRows
            return
        }
        if rows.isEmpty {
            rows = newRows
            tableView.reloadData()
            // Scrolled where it opens as soon as there is a size to measure against.
            DispatchQueue.main.async { [weak self] in self?.settleOpening() }
            return
        }
        guard newRows != rows else { return }

        let anchor = readingAnchor()
        let oldIDs = rows.map(\.id)
        let newIDs = newRows.map(\.id)
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = newRows
        // Off screen, a changed row keeps its measured height as a good guess and is
        // measured again before it shows.
        for row in newRows where heights[row.id] != nil {
            if let old = previous[row.id], old != row { stale.insert(row.id) }
        }

        if oldIDs != newIDs {
            let difference = newIDs.difference(from: oldIDs)
            var removals = IndexSet()
            var insertions = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): insertions.insert(offset)
                }
            }
            let live = Set(newIDs)
            heights = heights.filter { live.contains($0.key) }
            withoutAnimation {
                tableView.beginUpdates()
                if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: []) }
                if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: []) }
                tableView.endUpdates()
            }
        }

        refreshVisibleCells()
        measureNearViewport()
        hold(anchor)
    }

    /// Rows on screen whose content changed are redrawn in place, and say themselves if
    /// that changed their height.
    private func refreshVisibleCells(force: Bool = false) {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for index in visible.location..<min(visible.location + visible.length, rows.count) {
            guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacConversationCell,
                  force || cell.row != rows[index]
            else { continue }
            configure(cell, for: rows[index])
            stale.remove(rows[index].id)
        }
    }

    /// The quick reactions are the one part of the context that changes, after the
    /// viewer reacts; every row on screen shows them.
    func update(context: MacConversationCellContext) {
        let reactionsChanged = context.quickReactions != self.context.quickReactions
        self.context = context
        if reactionsChanged { refreshVisibleCells(force: true) }
    }

    private func configure(_ cell: MacConversationCell, for row: MacConversationRow) {
        let id = row.id
        cell.configure(row: row, context: context) { [weak self] height in
            self?.rowReported(height: height, for: id)
        }
    }

    // MARK: heights

    private var tableWidth: CGFloat { tableView?.bounds.width ?? 0 }

    private func estimate(_ row: MacConversationRow) -> CGFloat {
        switch row {
        case .top(.margin): return MacConversationCellContent.topMargin
        case .top(.loading): return 48
        case .top(.start): return 96
        case .pending: return 40
        case .message(let entry, let reactions, let isFirstUnread):
            let html = entry.message.renderedContent
            // Markup is roughly a third of the rendered HTML.
            let characters = CGFloat(html.count) * 0.65
            let charactersPerLine = max(20, (tableWidth - 90) / 7.5)
            var height = max(1, (characters / charactersPerLine).rounded(.up)) * 20
            if entry.startsGroup { height += 12 + 20 }
            if entry.startsDay { height += 30 }
            if isFirstUnread { height += 24 }
            if !reactions.isEmpty { height += 30 }
            if html.contains("<img") { height += 180 }
            return height + 2
        }
    }

    private func measure(_ index: Int) -> Bool {
        let row = rows[index]
        let width = tableWidth
        guard width > 0 else { return false }
        let height = measurer.height(of: row, context: context, width: width)
        stale.remove(row.id)
        let old = heights[row.id]
        heights[row.id] = height
        return old.map { abs($0 - height) > 0.5 } ?? (abs(estimate(row) - height) > 0.5)
    }

    /// Measures the rows about to come into view, a screen's height either side, so a row
    /// is drawn at its real height rather than corrected after it shows.
    private func measureNearViewport(limit: Int = 24) {
        guard let tableView, let scrollView, tableWidth > 0, !rows.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let reach = visible.insetBy(dx: 0, dy: -visible.height)
        let range = tableView.rows(in: reach)
        guard range.length > 0 else { return }
        // Nearest the screen first, below before above when equally near.
        let candidates = (range.location..<min(range.location + range.length, rows.count))
            .filter { heights[rows[$0].id] == nil || stale.contains(rows[$0].id) }
            .sorted { distance(of: $0, from: visible) < distance(of: $1, from: visible) }
        var changed = IndexSet()
        for index in candidates.prefix(limit) where measure(index) {
            changed.insert(index)
        }
        noteHeights(changed)
    }

    private func distance(of index: Int, from visible: NSRect) -> CGFloat {
        guard let tableView else { return 0 }
        let rect = tableView.rect(ofRow: index)
        if rect.maxY < visible.minY { return visible.minY - rect.maxY }
        if rect.minY > visible.maxY { return rect.minY - visible.maxY }
        return 0
    }

    private func rowReported(height: CGFloat, for id: MacConversationRow.ID) {
        guard height > 0 else { return }
        // Rounded the way the measurer rounds, or the two would disagree by a fraction
        // of a point and correct each other forever.
        reportedHeights[id] = max(1, ceil(height))
        guard !heightFlushScheduled else { return }
        heightFlushScheduled = true
        // Reported from inside a layout pass: the table cannot be told about it there.
        DispatchQueue.main.async { [weak self] in self?.flushReportedHeights() }
    }

    private func flushReportedHeights() {
        heightFlushScheduled = false
        let reports = reportedHeights
        reportedHeights = [:]
        var changed = IndexSet()
        for (index, row) in rows.enumerated() {
            guard let height = reports[row.id] else { continue }
            stale.remove(row.id)
            if let old = heights[row.id], abs(old - height) <= 0.5 { continue }
            heights[row.id] = height
            changed.insert(index)
        }
        guard !changed.isEmpty else { return }
        let anchor = readingAnchor()
        noteHeights(changed)
        hold(anchor)
    }

    private func noteHeights(_ indexes: IndexSet) {
        guard let tableView, !indexes.isEmpty else { return }
        let anchor = readingAnchor()
        withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: indexes) }
        hold(anchor)
    }

    // MARK: holding still

    /// The row at the top of the screen and how far into it the screen starts, while the
    /// reader is reading rather than following.
    private struct Anchor {
        let id: MacConversationRow.ID
        let offset: CGFloat
    }

    private func readingAnchor() -> Anchor? {
        // While the reader scrolls, even away from a followed bottom, what is under the
        // pointer stays put.
        guard let tableView, let scrollView, !follow.isPinned || isUserScrolling else { return nil }
        let top = scrollView.contentView.bounds.minY
        let index = tableView.row(at: NSPoint(x: 1, y: max(0, top)))
        guard index >= 0, index < rows.count else { return nil }
        return Anchor(id: rows[index].id, offset: tableView.rect(ofRow: index).minY - top)
    }

    /// Following, back on the newest message; reading, the same message where it was.
    private func hold(_ anchor: Anchor?) {
        if follow.isPinned, !isUserScrolling {
            scrollToBottom(animated: false)
        } else if let anchor, let tableView,
                  let index = rows.firstIndex(where: { $0.id == anchor.id }) {
            scrollTo(y: tableView.rect(ofRow: index).minY - anchor.offset)
        }
    }

    // MARK: scrolling

    private func scrollTo(y: CGFloat, animated: Bool = false) {
        guard let scrollView, let tableView else { return }
        let clip = scrollView.contentView
        let maxY = max(-scrollView.contentInsets.top,
                       tableView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        let target = NSPoint(x: 0, y: min(max(y, -scrollView.contentInsets.top), maxY))
        guard abs(target.y - clip.bounds.origin.y) > 0.25 else { return }
        isAdjusting = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                clip.animator().setBoundsOrigin(target)
            } completionHandler: {
                MainActor.assumeIsolated { scrollView.reflectScrolledClipView(clip) }
            }
        } else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
        isAdjusting = false
    }

    private func scrollToBottom(animated: Bool) {
        guard let tableView else { return }
        scrollTo(y: tableView.frame.height, animated: animated)
    }

    func followNewest(animated: Bool) {
        guard follow.pin() == .toBottom else { return }
        measureNearViewport()
        scrollToBottom(animated: animated)
        publish()
    }

    /// The first scroll, once the rows exist: to the first unread message, or to the
    /// newest one.
    private func settleOpening() {
        guard !hasOpened, let tableView, let scrollView,
              tableWidth > 0, scrollView.contentView.bounds.height > 0
        else { return }
        hasOpened = true
        measuredWidth = tableWidth
        let target: Int? = if case .opening(let unread) = follow.mode {
            rows.firstIndex { $0.messageID == unread }
        } else {
            nil
        }
        // Only the first screen is measured before the first frame; the rest of the way
        // is measured as it comes near.
        let viewport = scrollView.contentView.bounds.height
        var measured = IndexSet()
        if let target {
            // From the unread message down, then put on top.
            var covered: CGFloat = 0
            var index = target
            while index < rows.count, covered < viewport {
                if measure(index) { measured.insert(index) }
                covered += heights[rows[index].id] ?? 0
                index += 1
            }
            withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: measured) }
            layoutChanged()
        } else {
            _ = follow.pin()
            // From the newest message up.
            var covered: CGFloat = 0
            var index = rows.count - 1
            while index >= 0, covered < viewport {
                if measure(index) { measured.insert(index) }
                covered += heights[rows[index].id] ?? 0
                index -= 1
            }
            withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: measured) }
            scrollToBottom(animated: false)
        }
        measureNearViewport()
        hold(readingAnchor())
        visibleAreaMoved()
    }

    private func perform(_ scroll: ConversationFollow.Scroll) {
        switch scroll {
        case .toBottom:
            scrollToBottom(animated: false)
        case .toMessage(let id):
            guard let tableView, let index = rows.firstIndex(where: { $0.messageID == id }) else { return }
            scrollTo(y: tableView.rect(ofRow: index).minY)
        }
    }

    private var layout: ConversationLayout? {
        guard let tableView, let scrollView else { return nil }
        let clip = scrollView.contentView.bounds
        let end = tableView.frame.height + scrollView.contentInsets.bottom
        return ConversationLayout(
            contentHeight: tableView.frame.height,
            containerHeight: clip.height,
            distanceFromBottom: end - clip.maxY
        )
    }

    private func layoutChanged() {
        guard let layout else { return }
        if let scroll = follow.layoutChanged(to: layout) {
            perform(scroll)
            // Landing on the unread message is itself a layout change worth answering:
            // with little below it, the list is at the bottom and should follow.
            if let settled = self.layout, let next = follow.layoutChanged(to: settled) {
                perform(next)
            }
        }
        publish()
    }

    private func visibleAreaMoved() {
        guard hasOpened, !isAdjusting else { return }
        // Moved up by something other than the wheel or a gesture, the keyboard or a
        // click in the scroller's track say, the reader is scrolling all the same, or the
        // next change would put a followed list straight back on its newest message.
        let origin = scrollView?.contentView.bounds.origin.y ?? 0
        if origin < lastOrigin - 0.5, !isUserScrolling { userScrolled() }
        lastOrigin = origin
        scheduleMeasure()
        layoutChanged()
        noteVisibleRows()
    }

    private func scheduleMeasure() {
        guard !measureScheduled else { return }
        measureScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            measureScheduled = false
            measureNearViewport()
        }
    }

    private var resizeScheduled = false
    private var lastOrigin: CGFloat = 0

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resizeScheduled = false
            viewportResized()
        }
    }

    private func viewportResized() {
        guard let tableView else { return }
        guard hasOpened else {
            settleOpening()
            return
        }
        if abs(tableWidth - measuredWidth) > 0.5 {
            measuredWidth = tableWidth
            // Every wrap changes with the width; what was measured is now an estimate.
            stale.formUnion(heights.keys)
            let anchor = readingAnchor()
            withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
            measureNearViewport()
            hold(anchor)
        } else if follow.isPinned, !isUserScrolling {
            scrollToBottom(animated: false)
        }
        layoutChanged()
    }

    // MARK: the reader scrolling

    private func userScrolled() {
        scrollEndTimer?.invalidate()
        if !isUserScrolling {
            isUserScrolling = true
            container?.isolatesLayout = true
            follow.userBeganScrolling()
            loader.noteScrollPhase(.interacting)
            publish()
        }
        // A wheel scrolls in separate notches and a flick coasts on its own events; the
        // scroll is over once neither has come for a moment.
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.userStoppedScrolling() }
        }
    }

    private func userStoppedScrolling() {
        isUserScrolling = false
        container?.isolatesLayout = false
        container?.needsLayout = true
        loader.noteScrollPhase(.idle)
        if let layout { _ = follow.layoutChanged(to: layout) }
        follow.userFinishedScrolling()
        publish()
    }

    private func noteVisibleRows() {
        guard let tableView else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        var visibleMessages: [Int] = []
        for index in range.location..<min(range.location + range.length, rows.count) {
            guard let id = rows[index].messageID else { continue }
            visibleMessages.append(id)
            if reportedRead.insert(id).inserted { readTracker?.sawMessage(id: id) }
        }
        loader.noteVisible(visibleMessages)
    }

    private func publish() {
        if scroll.showsJumpToNewest != follow.showsJumpToNewest {
            scroll.showsJumpToNewest = follow.showsJumpToNewest
        }
        let near = layout.map { $0.isMeasured && $0.isNearBottom } ?? false
        if scroll.isNearBottom != near { scroll.isNearBottom = near }
    }

    private func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        return heights[rows[row].id] ?? estimate(rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let model = rows[row]
        let cell = tableView.makeView(withIdentifier: model.reuseIdentifier, owner: nil) as? MacConversationCell
            ?? MacConversationCell(identifier: model.reuseIdentifier)
        if cell.row != model { configure(cell, for: model) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// A message's hover bar rises into the row above, so each row draws past its top
    /// and over the one before it.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.clipsToBounds = false
        rowView.wantsLayer = true
        rowView.layer?.zPosition = CGFloat(row)
    }
}
