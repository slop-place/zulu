// PROTOTYPE — throwaway. Variant E: the flipped list of C, with the composer back in the
// glass safe-area bar so history scrolls underneath it.
// A flipped scroll view would put the composer's inset at the visual top and the
// navigation bar's at the visual bottom, so it ignores the safe area and takes the insets
// back as content margins on the swapped edges.
import SwiftUI
import ZuluScroll

private extension View {
    func flippedGlass() -> some View { scaleEffect(x: 1, y: -1) }
}

struct FlippedGlassVariantList: View {
    let store: ChatStore
    let readout: ScrollReadout

    @State private var scroll: FlippedScrollManager
    @State private var insets = EdgeInsets()

    init(store: ChatStore, readout: ScrollReadout) {
        self.store = store
        self.readout = readout
        _scroll = State(initialValue: FlippedScrollManager(readout: readout))
    }

    var body: some View {
        @Bindable var scroll = scroll
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.rows.reversed(), id: \.rowID) { message in
                    MessageRowView(message: message, store: store)
                        .flippedGlass()
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
        // Flipped, the scroll view's top is the visual bottom: the composer's edge.
        .contentMargins(.top, insets.bottom, for: .scrollContent)
        .contentMargins(.bottom, insets.top, for: .scrollContent)
        .contentMargins(.top, insets.bottom, for: .scrollIndicators)
        .contentMargins(.bottom, insets.top, for: .scrollIndicators)
        // The system effect cannot place itself on a turned-over scroll view; left on, it
        // blurs the whole list. EdgeBlur stands in for it.
        .scrollEdgeEffectHidden(true, for: .all)
        .flippedGlass()
        .ignoresSafeArea(.all, edges: .vertical)
        // Read on the view that ignores the safe area; inside it every inset is zero.
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        .overlay {
            VStack(spacing: 0) {
                EdgeBlur(edge: .top, barHeight: insets.top)
                Spacer(minLength: 0)
                EdgeBlur(edge: .bottom, barHeight: insets.bottom)
            }
            .ignoresSafeArea()
        }
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

/// Blur under a bar, with no colour of its own: the list turns to a soft blur toward the
/// screen edge and deepens a little into the background colour, the way the system
/// edge effect reads.
struct EdgeBlur: View {
    let edge: VerticalEdge
    let barHeight: CGFloat

    static let fadeLength: CGFloat = 32
    /// How far toward the background colour the very edge goes.
    static let edgeShade = 0.3
    static let blurRadius: CGFloat = 8

    var body: some View {
        ZStack {
            UntintedBlur()
            LinearGradient(
                colors: [Color(.systemBackground).opacity(Self.edgeShade), .clear],
                startPoint: edge == .top ? .top : .bottom,
                endPoint: edge == .top ? .bottom : .top
            )
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: barHeight / (barHeight + Self.fadeLength)),
                    .init(color: .clear, location: 1),
                ],
                startPoint: edge == .top ? .top : .bottom,
                endPoint: edge == .top ? .bottom : .top
            )
        }
        .frame(height: barHeight + Self.fadeLength)
        .allowsHitTesting(false)
    }
}

/// A system blur with nothing but the blur. Every public blur style runs a brightness
/// curve and a saturation boost ahead of the blur, which is what turns black grey, so
/// the backdrop keeps only its gaussian blur.
struct UntintedBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        BlurOnlyView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}

    private final class BlurOnlyView: UIVisualEffectView {
        static let blurFilterName = "gaussianBlur"
        static let radiusKey = "inputRadius"

        override func layoutSubviews() {
            super.layoutSubviews()
            for subview in subviews {
                guard let filters = subview.layer.value(forKey: "filters") as? [NSObject] else {
                    subview.isHidden = true
                    continue
                }
                let blurOnly = filters.filter { $0.value(forKey: "name") as? String == Self.blurFilterName }
                blurOnly.forEach { $0.setValue(EdgeBlur.blurRadius, forKey: Self.radiusKey) }
                subview.layer.setValue(blurOnly, forKey: "filters")
            }
        }
    }
}
