// PROTOTYPE — throwaway. Row, composer and geometry readout shared by every variant.
import SwiftUI

struct MessageRowView: View {
    let message: ChatMessage
    let store: ChatStore

    @State private var imageLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.author).font(.caption.bold()).foregroundStyle(.secondary)
            Text(message.text).foregroundStyle(message.isPending ? .secondary : .primary)
            if message.hasImage {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.tint.opacity(0.25))
                    .frame(width: 220, height: imageLoaded ? 160 : 0)
            }
            // Confirmed rows are one line taller than pending ones, like the real app.
            if let sent = message.sent {
                Text(sent, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard message.hasImage, !imageLoaded else { return }
            if store.loadedImages.contains(message.id) { imageLoaded = true; return }
            try? await Task.sleep(for: .milliseconds(800))
            store.loadedImages.insert(message.id)
            imageLoaded = true
        }
    }
}

struct ComposerView: View {
    let store: ChatStore

    @State private var draft = ""
    @State private var replying = false
    @FocusState private var focused: Bool
    @State private var standInKeyboard = false
    /// The simulator here runs with a hardware keyboard, so the software one never shows.
    static let standInKeyboardHeight: CGFloat = 336

    var body: some View {
        VStack(spacing: 6) {
            if replying {
                HStack {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 28)
                    Text("Replying to alex").font(.caption.bold())
                    Spacer()
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.24)) { replying.toggle() }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left").frame(width: 32, height: 32)
                        .accessibilityLabel("Reply")
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if standInKeyboard {
                Color.gray.opacity(0.3).frame(height: Self.standInKeyboardHeight)
                    .overlay { Text("stand-in keyboard").foregroundStyle(.secondary) }
                    .transition(.move(edge: .bottom))
            }
        }
        .task {
            guard Autopilot.isEnabled, let readout else { return }
            await Autopilot.run(
                focus: { up in withAnimation(.snappy(duration: 0.3)) { standInKeyboard = up } },
                type: { draft = $0 },
                reply: { withAnimation(.snappy(duration: 0.24)) { replying = true } },
                send: send,
                store: store,
                readout: readout
            )
        }
    }

    @Environment(ScrollReadout.self) private var readout: ScrollReadout?

    /// Same order as the real composer: enqueue, clear, drop the reply banner.
    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        store.send(typed)
        draft = ""
        withAnimation(.snappy(duration: 0.2)) { replying = false }
    }
}

/// Everything the scroll view reports, so each variant can be judged by numbers as well
/// as by eye. Written from `onScrollGeometryChange`; only the readout reads it.
@MainActor
@Observable
final class ScrollReadout {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var visibleMaxY: CGFloat = 0
    /// How far the newest message is from where it belongs; negative is past the end.
    var distanceFromNewest: CGFloat = 0
    var mode = "—"
    var events: [String] = []
    var autopilotDone = false
    var corrections = 0
    var uikit = ""
    @ObservationIgnored var frames: [String] = []

    static let eventLimit = 6
    static let pastEndTolerance: CGFloat = 1

    var isPastEnd: Bool { distanceFromNewest < -Self.pastEndTolerance }

    func record(_ geometry: ScrollGeometry, distanceFromNewest: CGFloat) {
        offsetY = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        insetTop = geometry.contentInsets.top
        insetBottom = geometry.contentInsets.bottom
        visibleMaxY = geometry.visibleRect.maxY
        self.distanceFromNewest = distanceFromNewest
        if UserDefaults.standard.bool(forKey: "logFlick") {
            frames.append(String(format: "frame offset %.1f content %.1f\n", offsetY, contentHeight))
        }
    }

    func log(_ event: String) {
        events.append(event)
        if events.count > Self.eventLimit { events.removeFirst() }
        guard UserDefaults.standard.bool(forKey: "logFlick") else { return }
        let url = URL.documentsDirectory.appending(path: "events.log")
        let line = String(format: "%.3f %@  offset %.0f  from newest %.1f\n",
                          Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 100),
                          event as NSString, offsetY, distanceFromNewest)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + frames.joined() + line).write(to: url, atomically: true, encoding: .utf8)
        frames = []
    }
}

struct ScrollReadoutView: View {
    let readout: ScrollReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("mode \(readout.mode)")
            Text("offset \(f(readout.offsetY))  content \(f(readout.contentHeight))  container \(f(readout.containerHeight))")
            Text("inset top \(f(readout.insetTop)) bottom \(f(readout.insetBottom))  visibleMaxY \(f(readout.visibleMaxY))")
            Text("from newest \(f(readout.distanceFromNewest))\(readout.isPastEnd ? "  PAST END" : "")")
                .foregroundStyle(readout.isPastEnd ? .red : .primary)
                .bold(readout.isPastEnd)
            Text(readout.uikit)
            if readout.autopilotDone { Text("autopilot-done") }
            ForEach(Array(readout.events.enumerated()), id: \.offset) { _, event in
                Text(event).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .allowsHitTesting(false)
    }

    private func f(_ value: CGFloat) -> String { String(format: "%.0f", value) }
}

/// PROTOTYPE — throwaway. Reads the UIKit scroll view under the SwiftUI one, so SwiftUI's
/// geometry model can be checked against what UIKit actually holds.
struct UIKitScrollProbe: UIViewRepresentable {
    let readout: ScrollReadout

    func makeUIView(context: Context) -> UIView {
        let probe = Probe()
        probe.readout = readout
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Probe: UIView {
        var readout: ScrollReadout?
        private var timer: Timer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        }

        private func sample() {
            var candidate: UIView? = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    if UserDefaults.standard.string(forKey: "fix") == "never" {
                        scrollView.contentInsetAdjustmentBehavior = .never
                    }
                    let i = scrollView.contentInset, a = scrollView.adjustedContentInset
                    let s = scrollView.superview
                    readout?.uikit = String(
                        format: "uikit b%d inset %.0f/%.0f adjusted %.0f/%.0f offset %.0f frame y %.0f h %.0f bounds y %.0f safe %.0f/%.0f super %@ safe %.0f/%.0f h %.0f t %.1f/%.1f/%.1f",
                        scrollView.contentInsetAdjustmentBehavior.rawValue,
                        i.top, i.bottom, a.top, a.bottom, scrollView.contentOffset.y,
                        scrollView.frame.minY, scrollView.frame.height, scrollView.bounds.minY,
                        scrollView.safeAreaInsets.top, scrollView.safeAreaInsets.bottom,
                        String(describing: type(of: s!)) as NSString,
                        s?.safeAreaInsets.top ?? -1, s?.safeAreaInsets.bottom ?? -1, s?.bounds.height ?? -1,
                        scrollView.transform.d, scrollView.transform.ty, scrollView.layer.transform.m22
                    )
                    return
                }
                candidate = view.superview
            }
        }
    }
}
