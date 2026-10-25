import SwiftUI

/// One conversation in a window of its own, so two can be read side by side: on a
/// foldable's open inner display, or on an iPad.
///
/// Only the conversation, not a second shell: the shell's open conversation lives on the
/// model and is shared, so a second shell would follow every choice made in the first.
struct ConversationWindow: View {
    static let id = "conversation"

    let source: ConversationSource?
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .signedOut:
            EmptyStateView(text: "Sign in to Zulu to read this conversation.")
        case .signedIn:
            // There is no close button: iOS refuses to let an iPhone app end its own
            // scenes, foldable included, so closing is left to the system's controls.
            NavigationStack {
                if let source {
                    ConversationView(source: source)
                        .id(source)
                        .environment(\.isStandaloneConversation, true)
                } else {
                    EmptyStateView(text: "That conversation is no longer available.")
                }
            }
            .modifier(MeasuresPageSideInsets())
            .attachmentPreviews()
        }
    }
}

/// Opens a conversation in a window of its own, where another window can open.
///
/// A foldable opens new windows only on its inner display, and the environment's
/// `supportsMultipleWindows` stays true once it is closed, so both size classes being
/// regular, which only the open inner display and an iPad give, decides it.
struct OpenInNewWindowButton: View {
    let source: ConversationSource

    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if supportsMultipleWindows, horizontalSizeClass == .regular, verticalSizeClass == .regular {
            Button("Open in new window", systemImage: "plus.rectangle.on.rectangle") {
                openWindow(id: ConversationWindow.id, value: source)
            }
        }
    }
}

extension EnvironmentValues {
    /// Set inside a conversation's own window, where the shell's actions, like jumping to
    /// the channel's topic list, have nowhere to go.
    @Entry var isStandaloneConversation = false
}

/// Measures the bars down the sides of a page that stays put, for the conversation list
/// on it. See `pageSideInsets`.
struct MeasuresPageSideInsets: ViewModifier {
    @State private var insets = HorizontalInsets()

    private static let minimumMeasuredSize: CGFloat = 200

    func body(content: Content) -> some View {
        content
            .environment(\.pageSideInsets, insets)
            .onGeometryChange(for: HorizontalInsets?.self) { proxy in
                // Laid out at a placeholder size before the split view sizes its columns;
                // a conversation built then would take its insets from nothing.
                guard proxy.size.width >= Self.minimumMeasuredSize, proxy.size.height >= Self.minimumMeasuredSize else {
                    return nil
                }
                return HorizontalInsets(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
            } action: { measured in
                if let measured { insets = measured }
            }
    }
}
