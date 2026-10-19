import SwiftUI
import ZuluStore

/// The menu bar. Every shortcut here is one a Mac chat client is expected to have;
/// anything more exotic waits until someone misses it.
struct MacCommands: Commands {
    let model: AppModel
    let ui: MacUIState

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Message…") { ui.showingNewMessage = true }
                .keyboardShortcut("n")
                .disabled(model.phase != .signedIn)

            Button("New Topic…") { newTopic() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(currentForumChannel == nil)

            Divider()

            Button("New Group…") { ui.showingNewGroup = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.phase != .signedIn)
        }

        CommandGroup(after: .appSettings) {
            Button("Sign Out…") { ui.confirmingSignOut = true }
                .disabled(model.phase != .signedIn)
        }

        CommandMenu("Go") {
            Button("Jump to…") { ui.showingQuickSwitcher = true }
                .keyboardShortcut("k")
                .disabled(model.phase != .signedIn)

            Divider()

            Button("Recent") { ui.section = .recent }
                .keyboardShortcut("0")
            Button("Direct Messages") { ui.section = .dms }
                .keyboardShortcut("1")
            Button(model.groups.isEmpty ? "Channels" : "Unfiled Channels") { ui.section = .unfiled }
                .keyboardShortcut("2")

            // ⌘3 through ⌘9 follow the rail's order, the way Slack numbers workspaces.
            ForEach(Array(model.groups.prefix(7).enumerated()), id: \.element.id) { index, group in
                Button(group.name) { ui.section = .group(group.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 3)")))
            }
        }

        CommandMenu("Conversation") {
            Button("Mark as Read") { ui.requestMarkRead() }
                .keyboardShortcut(.escape, modifiers: [.shift])
                .disabled(model.destination == nil)
            Button("Mark All as Read…") { ui.confirmingMarkAllRead = true }
                .keyboardShortcut(.escape, modifiers: [.command, .shift])
                .disabled(model.phase != .signedIn)

            Button("Focus Composer") { ui.requestComposerFocus() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.destination == nil)

            Divider()

            if case .topic(let channelID, let name, _) = model.destination {
                NotificationLevelMenu.topic(name, inChannel: channelID, model: model)
                let muted = model.isMuted(topic: name, inChannel: channelID)
                Button(muted ? "Unmute Topic" : "Mute Topic") {
                    Task { await model.setMuted(!muted, topic: name, inChannel: channelID) }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            } else {
                Button("Mute Topic") {}
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(true)
            }

            Divider()

            Button("Hidden Channels…") { ui.showingHidden = true }
                .disabled(model.phase != .signedIn)
        }
    }

    /// The forum channel a new topic would go in: the one open, or the one the open
    /// topic belongs to.
    private var currentForumChannel: ChannelSummary? {
        switch model.destination {
        case .channel(let id), .topic(let id, _, _):
            model.channel(id).flatMap { $0.rendersAsForum ? $0 : nil }
        default:
            nil
        }
    }

    private func newTopic() {
        guard let channel = currentForumChannel else { return }
        ui.newTopicChannel = ChannelSummaryBox(channel: channel)
    }
}

