import SwiftUI
import ZuluStore

@main
struct ZuluMacApp: App {
    @State private var model = AppModel()
    @State private var ui = MacUIState()
    @State private var notifier = MacNotifier()
    @NSApplicationDelegateAdaptor private var appDelegate: ZuluMacAppDelegate

    var body: some Scene {
        // One window, not a group: a chat client with two identical windows open is a
        // question ("which one is live?") with no good answer.
        Window("Zulu", id: "main") {
            MacRootView()
                .environment(model)
                .environment(ui)
                .task {
                    notifier.attach(model: model, ui: ui)
                    await model.bootstrap()
                }
                .frame(minWidth: 880, minHeight: 540)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands { MacCommands(model: model, ui: ui) }

        Settings {
            MacSettingsView()
                .environment(model)
                .environment(ui)
        }
    }
}

/// Closing the window leaves Zulu running, so the event queue keeps delivering
/// notifications. Clicking the Dock icon brings the window back.
final class ZuluMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MacRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            MacSignInView()
        case .signedIn:
            MacShellView().attachmentPreviews()
        }
    }
}

/// Which part of the sidebar is showing. Lives outside the shell so a menu command can
/// switch it.
enum SidebarSection: Equatable, Hashable {
    case dms
    case group(String)
    /// Channels no group has claimed, so filing is optional rather than required.
    case unfiled

    private static let groupPrefix = "group:"

    var storageKey: String {
        switch self {
        case .dms: "dms"
        case .unfiled: "unfiled"
        case .group(let id): Self.groupPrefix + id
        }
    }
}

/// Everything the menu bar and the shell have to agree on: which sheets are up, which
/// section is showing, and the requests a command makes of whatever view is in front.
///
/// Commands live outside the view tree and cannot reach into a view's state, so the
/// state they need to touch lives here, where both sides can see it.
@MainActor
@Observable
final class MacUIState {
    var section: SidebarSection = .unfiled

    var showingQuickSwitcher = false
    var showingNewMessage = false
    var showingNewGroup = false
    var showingHidden = false
    var confirmingSignOut = false
    var newTopicChannel: ChannelSummaryBox?
    var mutedTopicsChannel: ChannelSummaryBox?
    var editingGroup: GroupBox?

    /// Counters rather than booleans: a request is an event, and firing the same one
    /// twice in a row still has to fire twice.
    var composerFocusRequests = 0
    var markReadRequests = 0

    func requestComposerFocus() { composerFocusRequests += 1 }
    func requestMarkRead() { markReadRequests += 1 }

    private static let sectionDestinationsKey = "com.bwees.zulu.sectionDestinations"

    /// The chat last open in each section, so switching sections picks up where that
    /// section was left.
    private var sectionDestinations: [String: [String: String]] =
        UserDefaults.standard.dictionary(forKey: sectionDestinationsKey) as? [String: [String: String]] ?? [:]

    func lastDestination(in section: SidebarSection) -> AppModel.Destination? {
        sectionDestinations[section.storageKey].flatMap(AppModel.Destination.init(encoded:))
    }

    func remember(_ destination: AppModel.Destination, in section: SidebarSection) {
        sectionDestinations[section.storageKey] = destination.encoded
        UserDefaults.standard.set(sectionDestinations, forKey: Self.sectionDestinationsKey)
    }

    func forgetSectionDestinations() {
        sectionDestinations = [:]
        UserDefaults.standard.removeObject(forKey: Self.sectionDestinationsKey)
    }

    /// `sheet(item:)` needs something Identifiable, and a bare String is not.
    struct GroupBox: Identifiable {
        let id: String
    }
}

/// Wraps a channel summary for `sheet(item:)`, keeping the summary's own identity.
struct ChannelSummaryBox: Identifiable {
    let channel: ChannelSummary
    var id: Int { channel.id }
}
