import MessagingUI
import SwiftUI
import ZuluStore

/// One row of a conversation: a loaded message, or one sent from here that has not
/// landed yet.
///
/// Equatable so the list can tell a row that changed, a reaction landing say, from a
/// row that is new. A change keeps the row's place.
enum ConversationEntry: Identifiable, Equatable {
    case message(GroupedMessage, reactions: [ReactionGroup], isFirstUnread: Bool)
    case pending(PendingEntry)

    enum ID: Hashable {
        case message(Int)
        case pending(UUID)
    }

    var id: ID {
        switch self {
        case .message(let grouped, _, _): .message(grouped.id)
        case .pending(let pending): .pending(pending.id)
        }
    }
}

/// The message list, oldest at the top and the newest message on the composer.
struct ConversationList: View {
    let source: ConversationSource
    let title: String
    let loader: MessageHistoryLoader
    let readTracker: ReadTracker?

    @Environment(AppModel.self) private var model
    @Environment(AttachmentPreviewer.self) private var previewer
    @Environment(\.openURL) private var openURL
    /// How far the bars beside the conversation reach over the list, as the conversation
    /// last measured it.
    let currentSideInsets: HorizontalInsets
    @State private var manager: ConversationListManager
    @State private var presenter = MessagePresenter()
    /// How far the bars beside the conversation reach over the list. Shared with the
    /// rows through an observable rather than handed to them: the list builds each row's
    /// content once and never asks again.
    @State private var sideInsets: SideInsets

    private static let listPadding: CGFloat = 12
    private static let loaderHeight: CGFloat = 44

    init(
        source: ConversationSource, title: String, loader: MessageHistoryLoader, readTracker: ReadTracker?,
        sideInsets: HorizontalInsets
    ) {
        // Known from the first row on, so no row is measured at one width and drawn at
        // another.
        currentSideInsets = sideInsets
        _sideInsets = State(initialValue: SideInsets(sideInsets))
        self.source = source
        self.title = title
        self.loader = loader
        self.readTracker = readTracker
        _manager = State(initialValue: ConversationListManager(opensAt: loader.firstUnreadID))
    }

    var body: some View {
        Group {
            // The bars are read only for the readout, and handed straight on rather than
            // kept in state, where every change to them laid the list out again.
            if ScrollDebugReadout.isEnabled {
                GeometryReader { proxy in list(bars: proxy.safeAreaInsets) }
            } else {
                list(bars: nil)
            }
        }
        // Folding or rotating moves the bars; the rows step in by the new amount.
        .onChange(of: currentSideInsets) { _, insets in sideInsets.update(insets) }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if manager.showsJumpToNewest {
                    Button {
                        manager.followNewest()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // Scoped to the button. On the whole list it also animated whatever else
            // changed in the same update, like a message landing.
            .animation(.snappy(duration: 0.2), value: manager.showsJumpToNewest)
        }
        .presentsMessageSheets(presenter)
        // Scrolling back down after reading history, and catching up on messages that
        // arrived while the conversation was open, both land here.
        .onChange(of: manager.isAtNewest) { _, isAtNewest in
            if isAtNewest {
                model.liveEdgeReached(in: source)
                Task { await model.markConversationRead(source) }
            } else {
                model.liveEdgeLeft(in: source)
            }
        }
        .onDisappear { model.liveEdgeLeft(in: source) }
        // Sending always shows what was sent, even from partway up the history.
        .onChange(of: model.outbox.count(in: source)) { old, new in
            guard new > old else { return }
            manager.followNewest()
        }
    }

    private func list(bars: EdgeInsets?) -> some View {
        @Bindable var manager = manager
        let host = ConversationCellHost(
            model: model,
            previewer: previewer,
            openURL: openURL,
            presenter: presenter,
            manager: manager,
            source: source,
            readTracker: readTracker,
            sideInsets: sideInsets
        )
        // The loader and the header are attached for good and only change what they show.
        // Attaching or detaching one is a batch update of the collection view, and the
        // list asserts when that lands in the same update as a change to the rows, which
        // is exactly when the held-back history goes in.
        return TiledView(items: entries, scrollPosition: $manager.scrollPosition) { entry in
            ConversationCell(item: entry, host: host)
        }
        .prependLoader(Loader.loader(
            perform: { [loader, manager] in
                guard loader.hasMoreOlder, !manager.isHoldingHistory else { return }
                Task { await loader.loadOlder() }
            },
            isProcessing: loader.isLoadingOlder
        ) {
            ProgressView().frame(maxWidth: .infinity).frame(height: Self.loaderHeight)
        })
        .headerContent(HeaderContent.header {
            ConversationStart(title: title, isShown: showsStart, sideInsets: sideInsets)
        })
        .revealConfiguration(.disabled)
        .additionalContentInset(EdgeInsets(top: Self.listPadding, leading: 0, bottom: Self.listPadding, trailing: 0))
        .onTiledScrollGeometryChange { geometry in
            manager.geometryChanged(geometry)
            if let bars { ScrollDebugReadout.shared.record(geometry, bars: bars) }
        }
        // The list runs the full width, under the sidebar and any bar down the side of
        // the screen, and its rows step in by `sideInsets`. Said outright rather than left
        // to the list, which extends itself only once it has been laid out: its first
        // frame drew every row a sidebar's width to the right. It also keeps the side
        // insets out of the list's own scrolling, which let a conversation slide sideways.
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private var entries: [ConversationEntry] {
        let messages = manager.shown(loader.grouped).map { grouped in
            ConversationEntry.message(
                grouped,
                reactions: loader.reactions[grouped.id] ?? [],
                isFirstUnread: grouped.id == loader.firstUnreadID
            )
        }
        let pending = model.pendingEntries(in: source, after: loader.messages).map(ConversationEntry.pending)
        return messages + pending
    }

    private var showsStart: Bool { !loader.hasMoreOlder && !manager.isHoldingHistory }
}

/// What a cell needs from the list around it. Cells are hosted by UIKit, so nothing in
/// the list's environment reaches them.
private struct ConversationCellHost {
    let model: AppModel
    let previewer: AttachmentPreviewer
    let openURL: OpenURLAction
    let presenter: MessagePresenter
    let manager: ConversationListManager
    let source: ConversationSource
    let readTracker: ReadTracker?
    let sideInsets: SideInsets
}

/// The part of the list's width that the sidebar and bars cover, on each side.
@MainActor
@Observable
final class SideInsets {
    private(set) var leading: CGFloat
    private(set) var trailing: CGFloat

    init(_ insets: HorizontalInsets) {
        leading = insets.leading
        trailing = insets.trailing
    }

    func update(_ insets: HorizontalInsets) {
        if leading != insets.leading { leading = insets.leading }
        if trailing != insets.trailing { trailing = insets.trailing }
    }
}

extension EnvironmentValues {
    /// How far bars reach over the sides of the page a conversation is on: the status
    /// bar and toolbar column of a foldable, or a phone's sensor housing in landscape.
    /// Measured by whatever holds the page still, because the page's own safe area
    /// changes on every frame of the drawer sliding it aside.
    @Entry var pageSideInsets = HorizontalInsets()
}

struct HorizontalInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

@MainActor
private struct ConversationCell: @MainActor TiledCellContent {
    let item: ConversationEntry
    let host: ConversationCellHost

    private static let horizontalPadding: CGFloat = 16
    private static let groupSpacing: CGFloat = 14
    private static let continuationSpacing: CGFloat = 2
    private static let unreadSpacing: CGFloat = 10

    func body(context: CellContext<Void>) -> some View {
        row
            .padding(.leading, Self.horizontalPadding + host.sideInsets.leading)
            .padding(.trailing, Self.horizontalPadding + host.sideInsets.trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConversationScrollProbe { [manager = host.manager] in manager.attach($0) }.frame(width: 0, height: 0))
            .environment(host.model)
            .environment(host.previewer)
            .environment(host.presenter)
            .environment(\.openURL, host.openURL)
    }

    @ViewBuilder
    private var row: some View {
        switch item {
        case .message(let entry, let reactions, let isFirstUnread):
            VStack(alignment: .leading, spacing: 0) {
                if entry.startsDay {
                    DayDivider(date: entry.message.date).padding(.top, Self.groupSpacing)
                }
                if isFirstUnread {
                    UnreadDivider().padding(.top, Self.unreadSpacing)
                }
                MessageRow(message: entry.message, startsGroup: entry.startsGroup, reactions: reactions)
                    .padding(.top, spacing(startsGroup: entry.startsGroup))
                    .swipeToReply { [source = host.source] in
                        ComposerInbox.shared.deliver(
                            reply: ReplyDraft(message: entry.message),
                            to: ConversationKey.of(source)
                        )
                    }
            }
            .onAppear { host.readTracker?.sawMessage(id: entry.message.id) }
        case .pending(let pending):
            PendingMessageRow(message: pending.entry, startsGroup: pending.startsGroup)
                .padding(.top, spacing(startsGroup: pending.startsGroup))
        }
    }

    private func spacing(startsGroup: Bool) -> CGFloat {
        startsGroup ? Self.groupSpacing : Self.continuationSpacing
    }
}

/// The top of history. Takes no room until the oldest message is known to be loaded.
private struct ConversationStart: View {
    let title: String
    let isShown: Bool
    let sideInsets: SideInsets

    private static let verticalPadding: CGFloat = 24

    var body: some View {
        if isShown {
            VStack(spacing: 4) {
                Image(systemName: "sparkles").foregroundStyle(TextTone.tertiary)
                Text("This is the beginning of \(title).")
                    .font(.callout)
                    .foregroundStyle(TextTone.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, sideInsets.leading)
            .padding(.trailing, sideInsets.trailing)
            .padding(.vertical, Self.verticalPadding)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
        }
    }
}
