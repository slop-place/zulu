// PROTOTYPE — throwaway. Question: which list keeps the newest message on screen through
// sending, the keyboard and composer resizes, without overshooting past the end?
// Three variants of the conversation list, switched from the toolbar menu.
import SwiftUI

@main
struct ChatScrollApp: App {
    var body: some Scene {
        WindowGroup {
            if UserDefaults.standard.bool(forKey: "blurProbe") { BlurProbe() } else { PrototypeRoot() }
        }
    }
}

enum Variant: String, CaseIterable, Identifiable {
    case current = "A · Current"
    case fixed = "B · Fixed anchor"
    case flipped = "C · Flipped"
    case signal = "D · Signal-style"
    case flippedGlass = "E · Flipped + glass bar"
    case flippedGlassReader = "E2 · Glass bar, one pass"

    var id: String { rawValue }
}

struct PrototypeRoot: View {
    @State private var variant = Autopilot.launchVariant ?? .current
    @State private var store = ChatStore()
    @State private var readout = ScrollReadout()
    @State private var showsReadout = true

    var body: some View {
        NavigationStack {
            list
                .id(variant)
                .overlay(alignment: .top) {
                    if showsReadout { ScrollReadoutView(readout: readout) }
                }
                .navigationTitle(variant.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { controls }
        }
        .environment(readout)
        .task { if UserDefaults.standard.bool(forKey: "incoming") { store.incomingEnabled = true } }
        .onChange(of: variant) {
            store.incomingEnabled = false
            store = ChatStore()
            readout = ScrollReadout()
        }
    }

    @ViewBuilder private var list: some View {
        switch variant {
        case .current:
            CurrentVariantList(store: store, readout: readout)
                .safeAreaBar(edge: .bottom) { ComposerView(store: store) }
        case .fixed:
            FixedVariantList(store: store, readout: readout)
                .safeAreaBar(edge: .bottom) { ComposerView(store: store) }
        case .signal:
            SignalVariantList(store: store, readout: readout)
                .safeAreaBar(edge: .bottom) { ComposerView(store: store) }
        case .flippedGlassReader:
            FlippedGlassReaderVariantList(store: store, readout: readout)
                .safeAreaBar(edge: .bottom) { ComposerView(store: store) }
        case .flippedGlass:
            FlippedGlassVariantList(store: store, readout: readout)
                .safeAreaBar(edge: .bottom) { ComposerView(store: store) }
        case .flipped:
            FlippedVariantList(store: store, readout: readout)
        }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu("Variant", systemImage: "square.stack.3d.up") {
                Picker("Variant", selection: $variant) {
                    ForEach(Variant.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Test", systemImage: "slider.horizontal.3") {
                Toggle("Incoming every 2.5s", isOn: $store.incomingEnabled)
                Button("Receive one") { store.receiveOne() }
                Button("Send 3 quickly") { ["one", "two", "three"].forEach(store.send) }
                Picker("Confirm delay", selection: $store.confirmDelay) {
                    Text("Instant").tag(Duration.zero)
                    Text("700 ms").tag(Duration.milliseconds(700))
                    Text("3 s").tag(Duration.seconds(3))
                }
                Toggle("Geometry readout", isOn: $showsReadout)
            }
        }
    }
}
