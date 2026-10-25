import SwiftUI

/// Everything that is about the app rather than about one channel, in one place. The
/// list header's menu keeps the actions that belong to the list on show.
struct SettingsView: View {
    /// A sheet has Done; a tab of its own has nowhere to be dismissed to.
    var showsDone = true

    @Environment(AppModel.self) private var model
    @Environment(NotificationServiceSettings.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    @State private var showingNotifications = false
    @State private var showingHidden = false
    @State private var confirmingMarkAllRead = false
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if let account = model.account {
                    Section("Account") {
                        LabeledContent("Server", value: account.realmURL.host() ?? account.realmURL.absoluteString)
                        LabeledContent("Signed in as", value: account.email)
                    }
                }

                Section {
                    Button {
                        showingNotifications = true
                    } label: {
                        Label("Push notifications", systemImage: "bell.badge")
                    }
                    Button {
                        showingHidden = true
                    } label: {
                        Label("Hidden channels", systemImage: "eye.slash")
                    }
                } footer: {
                    Text("Groups, renames and hidden channels stay on your devices. Zulip never sees them.")
                }

                Section {
                    Button {
                        confirmingMarkAllRead = true
                    } label: {
                        Label("Mark all as read…", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Label("Sign out…", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .sheet(isPresented: $showingNotifications) { NotificationSettingsView() }
            .sheet(isPresented: $showingHidden) { HiddenChannelsView() }
            .confirmationDialog(
                "Mark every message as read?",
                isPresented: $confirmingMarkAllRead,
                titleVisibility: .visible
            ) {
                Button("Mark All as Read", role: .destructive) {
                    Task { await model.markAllRead() }
                }
            } message: {
                Text("Every channel, topic and direct message, here and on the server. This can't be undone.")
            }
            .confirmationDialog(
                "Sign out of \(model.account?.email ?? "this account")?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    Task {
                        // The push service holds the account's key and would keep pushing for it.
                        await notifications.signOut()
                        await model.signOut()
                    }
                }
            } message: {
                Text("Your channel groups, renames and hidden channels on this device are removed with it.")
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}
