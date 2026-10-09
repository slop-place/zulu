// PROTOTYPE — throwaway. Variant C: the list turned upside down, as Stream Chat's SwiftUI
// list does. The newest message sits at offset 0, which is exact no matter how wrong the
// lazy stack's row estimates are, and older history grows away from it.
// The composer sits under the list instead of in a safe-area bar: a flipped scroll view
// would put a bottom inset at the top.
import SwiftUI
import ZuluScroll

private extension View {
    func flipped() -> some View { scaleEffect(x: 1, y: -1) }
}

@MainActor
@Observable
final class FlippedScrollManager {
    var position: ScrollPosition {
        get {
            access(keyPath: \.position)
            return scrolledPosition
        }
        set { scrolledPosition = newValue }
    }
    @ObservationIgnored private var scrolledPosition = ScrollPosition(idType: Int.self)
    private(set) var showsJumpToNewest = false
    @ObservationIgnored private var follow = ConversationFollow(opensAt: nil)
    @ObservationIgnored private let readout: ScrollReadout

    init(readout: ScrollReadout) {
        self.readout = readout
    }

    func scrollPhaseChanged(to phase: ScrollPhase) {
        readout.log("phase \(phase)")
        switch phase {
        case .tracking, .interacting:
            follow.userBeganScrolling()
        case .idle, .animating:
            follow.userFinishedScrolling()
        case .decelerating:
            break
        @unknown default:
            break
        }
        publish()
    }

    func layoutChanged(to layout: ConversationLayout) {
        _ = follow.layoutChanged(to: layout)
        publish()
    }

    /// A row landing above offset 0 would otherwise stay hidden above the newest one on screen.
    func rowsChanged() {
        readout.log("rows changed")
        guard follow.isPinned else { return }
        toNewest(animated: false)
    }

    func didSend() {
        _ = follow.pin()
        readout.log("send → pin")
        publish()
        toNewest(animated: false)
    }

    func jumpToNewest() {
        _ = follow.pin()
        publish()
        toNewest(animated: true)
    }

    private func toNewest(animated: Bool) {
        readout.log("scroll edge .top (flipped)")
        let move = { self.withMutation(keyPath: \.position) { self.scrolledPosition.scrollTo(edge: .top) } }
        if animated { withAnimation(.snappy, move) } else { move() }
    }

    private func publish() {
        if showsJumpToNewest != follow.showsJumpToNewest { showsJumpToNewest = follow.showsJumpToNewest }
        readout.mode = "\(follow.mode)"
    }
}

struct FlippedVariantList: View {
    let store: ChatStore
    let readout: ScrollReadout

    @State private var scroll: FlippedScrollManager
    @State private var topBarHeight: CGFloat = 0

    init(store: ChatStore, readout: ScrollReadout) {
        self.store = store
        self.readout = readout
        _scroll = State(initialValue: FlippedScrollManager(readout: readout))
    }

    var body: some View {
        VStack(spacing: 0) {
            list
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topBarHeight = $0 }
            ComposerView(store: store)
        }
    }

    private var list: some View {
        @Bindable var scroll = scroll
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.rows.reversed(), id: \.rowID) { message in
                    MessageRowView(message: message, store: store)
                        .flipped()
                        .onAppear { if message.rowID == store.rows.first?.rowID { store.loadOlder() } }
                }
                if store.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($scroll.position)
        // The navigation bar's edge effect belongs to the top edge, which is the visual bottom here.
        .scrollEdgeEffectHidden(true, for: .top)
        .flipped()
        // The navigation bar's inset would land at the visual bottom once flipped, so it is
        // dropped and given back as a margin on the far (visually top) end.
        .ignoresSafeArea(.container, edges: .top)
        .contentMargins(.bottom, topBarHeight, for: .scrollContent)
        .onScrollPhaseChange { _, phase in scroll.scrollPhaseChanged(to: phase) }
        .onScrollGeometryChange(for: ConversationLayout.self) { geometry in
            Self.layout(geometry)
        } action: { _, layout in
            scroll.layoutChanged(to: layout)
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            readout.record(geometry, distanceFromNewest: Self.layout(geometry).distanceFromBottom)
        }
        .overlay(alignment: .bottomTrailing) {
            if scroll.showsJumpToNewest {
                Button("Newest", systemImage: "chevron.down") { scroll.jumpToNewest() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(16)
            }
        }
        .onChange(of: store.rows.last?.rowID) { scroll.rowsChanged() }
        .onChange(of: store.sentCount) { old, new in
            guard new > old else { return }
            scroll.didSend()
        }
    }

    private static func layout(_ geometry: ScrollGeometry) -> ConversationLayout {
        ConversationLayout(
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            distanceFromBottom: geometry.contentOffset.y + geometry.contentInsets.top
        )
    }
}
