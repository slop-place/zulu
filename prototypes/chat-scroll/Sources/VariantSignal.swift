// PROTOTYPE — throwaway. Variant D: Signal's approach in SwiftUI. The list stays the right
// way up and the composer stays in the glass safe-area bar. Instead of trusting
// `scrollTo(edge: .bottom)`, which overshoots by the bottom inset, the manager works out
// the bottom offset from the scroll geometry itself and scrolls to that exact y.
// After a send it keeps correcting for a short settle window, because the lazy stack
// re-measures the new row after the first scroll lands.
import SwiftUI
import ZuluScroll

@MainActor
@Observable
final class SignalScrollManager {
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
    @ObservationIgnored private var geometry: ScrollGeometry?
    @ObservationIgnored private var isUserScrolling = false
    @ObservationIgnored private let readout: ScrollReadout

    init(readout: ScrollReadout) {
        self.readout = readout
    }

    /// Signal's `maxContentOffsetY` in `scrollTo(y:)` terms, which measure from the top of
    /// the content rather than above the top inset. The container excludes both insets.
    static func bottomOffset(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height - geometry.containerSize.height
    }

    func scrollPhaseChanged(to phase: ScrollPhase) {
        readout.log("phase \(phase)")
        switch phase {
        case .tracking, .interacting:
            isUserScrolling = true
            follow.userBeganScrolling()
        case .idle, .animating:
            isUserScrolling = false
            follow.userFinishedScrolling()
        case .decelerating:
            break
        @unknown default:
            break
        }
        publish()
    }

    /// Signal holds a pinned list on the bottom through every size change. SwiftUI only
    /// reports the size after the frame, so this corrects one frame late.
    func geometryChanged(to geometry: ScrollGeometry) {
        self.geometry = geometry
        _ = follow.layoutChanged(to: ConversationLayout(geometry))
        publish()
        guard follow.isPinned, !isUserScrolling, !ConversationLayout(geometry).isSettledAtBottom else { return }
        toBottom(animated: false)
    }

    func didSend() {
        _ = follow.pin()
        readout.log("send → pin")
        publish()
        toBottom(animated: false)
    }

    func jumpToNewest() {
        _ = follow.pin()
        publish()
        toBottom(animated: true)
    }

    private func toBottom(animated: Bool) {
        guard let geometry else { return }
        let y = Self.bottomOffset(geometry)
        readout.log(String(format: "scroll y %.0f", y))
        readout.corrections += 1
        let move = { self.withMutation(keyPath: \.position) { self.scrolledPosition.scrollTo(y: y) } }
        if animated { withAnimation(.snappy, move) } else { move() }
    }

    private func publish() {
        if showsJumpToNewest != follow.showsJumpToNewest { showsJumpToNewest = follow.showsJumpToNewest }
        readout.mode = "\(follow.mode)"
    }
}

struct SignalVariantList: View {
    let store: ChatStore
    let readout: ScrollReadout

    @State private var scroll: SignalScrollManager

    init(store: ChatStore, readout: ScrollReadout) {
        self.store = store
        self.readout = readout
        _scroll = State(initialValue: SignalScrollManager(readout: readout))
    }

    var body: some View {
        @Bindable var scroll = scroll
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }
                ForEach(store.rows, id: \.rowID) { message in
                    MessageRowView(message: message, store: store)
                        .onAppear { if message.rowID == store.rows.first?.rowID { store.loadOlder() } }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($scroll.position, anchor: .bottom)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollPhaseChange { _, phase in scroll.scrollPhaseChanged(to: phase) }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            scroll.geometryChanged(to: geometry)
            readout.record(geometry, distanceFromNewest: ConversationLayout(geometry).distanceFromBottom)
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
        .onChange(of: store.sentCount) { old, new in
            guard new > old else { return }
            scroll.didSend()
        }
    }
}
