// PROTOTYPE — throwaway. Variant B: keeps the bottom anchor, with the targeted fixes.
// - Pending and confirmed rows share one id, so confirming is a resize, not a swap.
// - Anchor roles split: bottom for the first offset and size changes, top alignment so a
//   short conversation sits at the top.
// - Sending scrolls to the newest row's id on the next main-actor turn, after the row is
//   in the list, instead of to the bottom edge in the same update that inserts it.
import SwiftUI
import ZuluScroll

@MainActor
@Observable
final class FixedScrollManager {
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

    func scrollPhaseChanged(to phase: ScrollPhase, newest: Int?) {
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

    func didSend(newest: Int?) {
        _ = follow.pin()
        readout.log("send → pin, deferred")
        publish()
        Task { @MainActor in scroll(to: newest, animated: false) }
    }

    func jumpToNewest(_ newest: Int?) {
        _ = follow.pin()
        publish()
        scroll(to: newest, animated: true)
    }

    private func scroll(to id: Int?, animated: Bool) {
        guard let id else { return }
        readout.log("scroll id \(id) .bottom")
        let move = { self.withMutation(keyPath: \.position) { self.scrolledPosition.scrollTo(id: id, anchor: .bottom) } }
        if animated { withAnimation(.snappy, move) } else { move() }
    }

    private func publish() {
        if showsJumpToNewest != follow.showsJumpToNewest { showsJumpToNewest = follow.showsJumpToNewest }
        readout.mode = "\(follow.mode)"
    }
}

struct FixedVariantList: View {
    let store: ChatStore
    let readout: ScrollReadout

    @State private var scroll: FixedScrollManager

    init(store: ChatStore, readout: ScrollReadout) {
        self.store = store
        self.readout = readout
        _scroll = State(initialValue: FixedScrollManager(readout: readout))
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
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollPhaseChange { _, phase in
            scroll.scrollPhaseChanged(to: phase, newest: store.rows.last?.rowID)
        }
        .onScrollGeometryChange(for: ConversationLayout.self) { geometry in
            ConversationLayout(geometry)
        } action: { _, layout in
            scroll.layoutChanged(to: layout)
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            readout.record(geometry, distanceFromNewest: ConversationLayout(geometry).distanceFromBottom)
        }
        .overlay(alignment: .bottomTrailing) {
            if scroll.showsJumpToNewest {
                Button("Newest", systemImage: "chevron.down") { scroll.jumpToNewest(store.rows.last?.rowID) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(16)
            }
        }
        .onChange(of: store.sentCount) { old, new in
            guard new > old else { return }
            scroll.didSend(newest: store.rows.last?.rowID)
        }
    }
}
