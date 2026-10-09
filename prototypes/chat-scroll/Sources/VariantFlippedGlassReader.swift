// PROTOTYPE — throwaway. Variant E2: E, with the bar insets read by a GeometryReader and
// applied in the same layout pass. E writes them to state from onGeometryChange, which
// lays the list out once more for every change; during the keyboard's show animation
// the app looped there and never came back.
import SwiftUI
import ZuluScroll

struct FlippedGlassReaderVariantList: View {
    let store: ChatStore
    let readout: ScrollReadout

    @State private var scroll: FlippedScrollManager

    init(store: ChatStore, readout: ScrollReadout) {
        self.store = store
        self.readout = readout
        _scroll = State(initialValue: FlippedScrollManager(readout: readout))
    }

    static let fix = UserDefaults.standard.string(forKey: "fix") ?? "none"

    var body: some View {
        if Self.fix == "shrink" {
            // The keyboard shrinks the frame; only the bars become margins. The inner
            // reader ignores the keyboard, so the difference between the two is its height.
            GeometryReader { outer in
                GeometryReader { inner in
                    list(bars: inner.safeAreaInsets, keyboard: outer.safeAreaInsets.bottom - inner.safeAreaInsets.bottom)
                        .ignoresSafeArea(.container, edges: .vertical)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        } else {
            GeometryReader { proxy in
                list(bars: proxy.safeAreaInsets, keyboard: 0)
                    .ignoresSafeArea(.all, edges: .vertical)
            }
        }
    }

    private func list(bars: EdgeInsets, keyboard: CGFloat) -> some View {
        @Bindable var scroll = scroll
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.rows.reversed(), id: \.rowID) { message in
                    MessageRowView(message: message, store: store)
                        .scaleEffect(x: 1, y: -1)
                        .onAppear { if message.rowID == store.rows.first?.rowID { store.loadOlder() } }
                }
                if store.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UIKitScrollProbe(readout: readout).frame(width: 0, height: 0))
        }
        .scrollPosition($scroll.position)
        .contentMargins(.top, bars.bottom, for: .scrollContent)
        .contentMargins(.bottom, bars.top, for: .scrollContent)
        .contentMargins(.top, bars.bottom, for: .scrollIndicators)
        .contentMargins(.bottom, bars.top, for: .scrollIndicators)
        .scrollEdgeEffectHidden(true, for: .all)
        .ignoresSafeArea(.all, edges: Self.fix == "inner" ? .vertical : [])
        .scaleEffect(x: 1, y: -1)
        .overlay {
            VStack(spacing: 0) {
                EdgeBlur(edge: .top, barHeight: bars.top)
                Spacer(minLength: 0)
                EdgeBlur(edge: .bottom, barHeight: bars.bottom)
            }
        }
        .padding(.bottom, keyboard)
        .onScrollPhaseChange { _, phase in scroll.scrollPhaseChanged(to: phase) }
        .onScrollGeometryChange(for: ConversationLayout.self) { geometry in
            Self.layout(geometry)
        } action: { _, layout in
            scroll.layoutChanged(to: layout)
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            readout.record(geometry, distanceFromNewest: Self.layout(geometry).distanceFromBottom)
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
