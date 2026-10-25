import SwiftUI
import ZuluStore

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
    @State private var editingGroup: GroupID?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var reorderingGroups = false
    @State private var deletingGroup: ChannelGroupSummary?

    var body: some View {
        NavigationStack {
            Form {
                if let account = model.account {
                    Section("Account") {
                        LabeledContent("Server", value: account.realmURL.host() ?? account.realmURL.absoluteString)
                        LabeledContent("Signed in as", value: account.email)
                    }
                }

                groupsSection

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
            .sheet(item: $editingGroup) { group in GroupEditor(groupID: group.id) }
            .sheet(isPresented: $reorderingGroups) { ReorderGroupsView(groups: model.groups) }
            .alert("New group", isPresented: $creatingGroup) {
                TextField("Name", text: $newGroupName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createGroup() }
            } message: {
                Text("Group channels however you like. Groups stay on your devices — Zulip has no idea they exist.")
            }
            .confirmationDialog(
                "Delete “\(deletingGroup?.name ?? "")”?",
                isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                titleVisibility: .visible,
                presenting: deletingGroup
            ) { group in
                Button("Delete Group", role: .destructive) { model.deleteGroup(id: group.id) }
            } message: { _ in
                Text("Its channels go back to Channels. Nothing changes on the server.")
            }
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

    /// Groups are made, edited and ordered here as well as from the Groups tab's title,
    /// where only the one on show can be reached.
    private var groupsSection: some View {
        Section {
            ForEach(model.groups) { group in
                Button {
                    editingGroup = GroupID(id: group.id)
                } label: {
                    HStack(spacing: 12) {
                        GroupAvatar(name: group.name, icon: group.icon, size: 32, active: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).foregroundStyle(.primary)
                            Text(group.channelCount == 1 ? "1 channel" : "\(group.channelCount) channels")
                                .font(.caption)
                                .foregroundStyle(TextTone.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(TextTone.tertiary)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { deletingGroup = group }
                }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { editingGroup = GroupID(id: group.id) }
                    NotificationLevelMenu.group(group.id, model: model)
                    Button("Delete", systemImage: "trash", role: .destructive) { deletingGroup = group }
                }
            }
            Button {
                newGroupName = ""
                creatingGroup = true
            } label: {
                Label("New group", systemImage: "folder.badge.plus")
            }
            if model.groups.count > 1 {
                Button {
                    reorderingGroups = true
                } label: {
                    Label("Reorder groups", systemImage: "arrow.up.arrow.down")
                }
            }
        } header: {
            Text("Groups")
        } footer: {
            if !model.groups.isEmpty {
                Text("Swipe a group to delete it. Its channels go back to Channels.")
            }
        }
    }

    /// Opens the new group's editor here, rather than letting the shell jump to it.
    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.createGroup(named: name)
        if let id = model.pendingGroupToEdit {
            model.pendingGroupToEdit = nil
            editingGroup = GroupID(id: id)
        }
    }

    /// `sheet(item:)` needs something Identifiable, and a bare String is not.
    private struct GroupID: Identifiable {
        let id: String
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}
