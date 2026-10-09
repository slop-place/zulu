// PROTOTYPE — throwaway. Variant A: what the app ships today. The list and manager are
// copied from App/Sources/ConversationView.swift and Shared/Sources/ConversationScroll.swift
// (with the observation fix), using the real ConversationFollow.
import SwiftUI
import ZuluScroll

extension ConversationLayout {
    init(_ geometry: ScrollGeometry) {
        let end = geometry.contentSize.height + geometry.contentInsets.bottom
        self.init(
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            distanceFromBottom: end - geometry.visibleRect.maxY
        )
    }
}

@MainActor
@Observable
final class CurrentScrollManager {
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
            apply(nil)
        case .decelerating:
            break
        @unknown default:
            break
        }
    }

    func layoutChanged(to layout: ConversationLayout) {
        apply(follow.layoutChanged(to: layout))
    }

    func didSend() {
        readout.log("send → pin")
        apply(follow.pin())
    }

    func jumpToNewest() {
        withAnimation(.snappy) { apply(follow.pin()) }
    }

    private func apply(_ scroll: ConversationFollow.Scroll?) {
        if showsJumpToNewest != follow.showsJumpToNewest { showsJumpToNewest = follow.showsJumpToNewest }
        readout.mode = "\(follow.mode)"
        switch scroll {
        case .toBottom:
            readout.log("scroll edge .bottom")
            withMutation(keyPath: \.position) {
                scrolledPosition = ScrollPosition(idType: Int.self, edge: .bottom)
            }
        case .toMessage(let id):
            withMutation(keyPath: \.position) {
                scrolledPosition.scrollTo(id: id, anchor: .top)
            }
        case nil:
            break
        }
    }
}

struct CurrentVariantList: View {
    let store: ChatStore
    let readout: ScrollReadout

    @State private var scroll: CurrentScrollManager

    init(store: ChatStore, readout: ScrollReadout) {
        self.store = store
        self.readout = readout
        _scroll = State(initialValue: CurrentScrollManager(readout: readout))
    }

    var body: some View {
        @Bindable var scroll = scroll
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }
                ForEach(store.messages) { message in
                    MessageRowView(message: message, store: store)
                        .onAppear { if message.id == store.messages.first?.id { store.loadOlder() } }
                        .id(message.id)
                }
                // Pending rows are unidentified, as in the app.
                ForEach(store.pending) { message in
                    MessageRowView(message: message, store: store)
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
