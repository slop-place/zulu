import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers
import ZuluStore

// MARK: - New direct message

/// Pick one person for a conversation, or several for a group one.
struct MacNewMessageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chosen: [Int] = []
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Message").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("To:").foregroundStyle(TextTone.secondary)
                FlowRow(spacing: 4) {
                    ForEach(chosen, id: \.self) { id in
                        HStack(spacing: 4) {
                            Text(model.name(forUser: id)).font(.callout)
                            Button {
                                chosen.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    TextField("Name or email", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .frame(minWidth: 120)
                        .onSubmit {
                            if let first = people.first { toggle(first.id) }
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            List(people) { user in
                Button { toggle(user.id) } label: {
                    HStack(spacing: 10) {
                        SenderAvatar(name: user.fullName, userID: user.id, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.fullName).lineLimit(1)
                            if let email = user.email {
                                Text(email).font(.caption).foregroundStyle(TextTone.secondary).lineLimit(1)
                            }
                        }
                        if user.isBot {
                            Text("BOT")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                        Spacer()
                        if chosen.contains(user.id) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text(chosen.count > 1 ? "Group message with \(chosen.count) people" : " ")
                    .font(.caption).foregroundStyle(TextTone.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 500)
        .task { searching = true }
    }

    private var people: [UserRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return model.users.values
            .filter { $0.id != model.selfUserID }
            .filter {
                needle.isEmpty
                    || $0.fullName.localizedCaseInsensitiveContains(needle)
                    || ($0.email?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            .sorted {
                if $0.isBot != $1.isBot { return !$0.isBot }
                return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
    }

    private func toggle(_ id: Int) {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
        } else {
            chosen.append(id)
            query = ""
        }
        searching = true
    }

    private func start() {
        guard let key = model.dmKey(with: chosen) else { return }
        ui.section = .dms
        model.destination = .dm(key)
        dismiss()
        ui.requestComposerFocus()
    }
}

// MARK: - New topic

/// Starting a topic is naming it and saying the first thing. The conversation opens as
/// soon as the server has it.
struct MacNewTopicSheet: View {
    let channel: ChannelSummary

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var topic = ""
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case topic, message }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New topic in #\(channel.name)").font(.headline)

            TextField("Topic", text: $topic)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .topic)
                .onSubmit { focus = .message }

            TextEditor(text: $message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .focused($focus, equals: .message)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Say something to start it off")
                            .foregroundStyle(.placeholder)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text("⌘↩ to send").font(.caption).foregroundStyle(TextTone.tertiary)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || sending)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task { focus = .topic }
    }

    private var ready: Bool {
        !topic.trimmingCharacters(in: .whitespaces).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let name = topic.trimmingCharacters(in: .whitespaces)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !text.isEmpty else { return }
        sending = true
        error = nil
        defer { sending = false }
        if let failure = await model.send(text, toChannel: channel.id, topic: name) {
            error = failure
            return
        }
        model.destination = .topic(channelID: channel.id, name: name, channelName: channel.name)
        dismiss()
    }
}

// MARK: - Group editor

/// Create or change one channel group: its name, its icon, and which channels it holds.
struct MacGroupEditor: View {
    let groupID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<Int> = []
    @State private var icon: Data?
    @State private var importingIcon = false
    @State private var filter = ""
    @State private var loaded = false
    @FocusState private var naming: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MacGroupAvatar(name: name, icon: icon, size: 56, active: true)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Group name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .focused($naming)
                    HStack(spacing: 8) {
                        Button("Choose Icon…") { importingIcon = true }
                        if icon != nil {
                            Button("Remove Icon") { icon = nil }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            TextField("Filter channels", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            List(filteredChannels) { channel in
                Toggle(isOn: binding(for: channel.id)) {
                    HStack(spacing: 8) {
                        ChannelIcon(isForum: channel.rendersAsForum, restricted: channel.isRestricted, size: 12)
                            .foregroundStyle(TextTone.secondary)
                            .frame(width: 18, alignment: .leading)
                        Text(channel.name).lineLimit(1)
                        if let elsewhere = model.group(containingChannel: channel.id), elsewhere != groupID,
                           let other = model.groups.first(where: { $0.id == elsewhere }) {
                            Text("in \(other.name)").font(.caption).foregroundStyle(TextTone.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text("\(selected.count) channel\(selected.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(TextTone.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480, height: 540)
        .fileImporter(isPresented: $importingIcon, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                icon = MacImageScaler.jpegThumbnail(data)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let group = model.groups.first(where: { $0.id == groupID }) {
                name = group.name
                icon = group.icon
            }
            selected = Set(model.channelIDs(inGroup: groupID))
            naming = true
        }
    }

    private var filteredChannels: [ChannelSummary] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return model.allChannels }
        return model.allChannels.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { if $0 { selected.insert(id) } else { selected.remove(id) } }
        )
    }

    private func save() {
        model.renameGroup(id: groupID, to: name.trimmingCharacters(in: .whitespaces))
        model.setGroupIcon(id: groupID, icon: icon)
        model.setChannels(Array(selected), inGroup: groupID)
        dismiss()
    }
}

/// Icons are stored small rather than at whatever size the picture came in at.
enum MacImageScaler {
    static func jpegThumbnail(_ data: Data, maxSide: CGFloat = 256) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - Hidden channels

/// Where hidden channels go, and the only way back.
///
/// Hiding is a filing decision, not a mute: these channels are still subscribed, still
/// notify, and still count their mentions. They simply do not take up a row.
struct MacHiddenChannelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [ChannelSummary] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Hidden Channels").font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            if channels.isEmpty {
                ContentUnavailableView(
                    "Nothing hidden",
                    systemImage: "eye",
                    description: Text("Right-click a channel in the sidebar to hide it.")
                )
            } else {
                List(channels) { channel in
                    HStack(spacing: 10) {
                        ChannelIcon(isForum: channel.rendersAsForum, restricted: channel.isRestricted, size: 12)
                            .foregroundStyle(TextTone.secondary)
                            .frame(width: 18, alignment: .leading)
                        Text(channel.name)
                        Spacer()
                        if channel.mentionCount > 0 {
                            Badge(count: channel.mentionCount, mention: true)
                        }
                        Button("Unhide") { model.setHidden(false, forChannel: channel.id) }
                            .controlSize(.small)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 400)
        .task { await observe() }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.hiddenChannelObservation
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) { channels = rows }
        } catch {}
    }
}

// MARK: - Muted topics

/// A channel's muted topics. Muting takes a topic out of every list, so this is the only
/// way back to one.
struct MacMutedTopicsSheet: View {
    let channel: ChannelSummary

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var topics: [MutedTopicRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Muted in #\(channel.name)").font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            if topics.isEmpty {
                ContentUnavailableView(
                    "Nothing muted",
                    systemImage: "bell",
                    description: Text("Right-click a topic to mute it.")
                )
            } else {
                List(topics, id: \.topic) { topic in
                    HStack {
                        Text(topic.topic.isEmpty ? "general chat" : topic.topic)
                        Spacer()
                        Button("Unmute") {
                            Task { await model.setMuted(false, topic: topic.topic, inChannel: channel.id) }
                        }
                        .controlSize(.small)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 400)
        .task { await observe() }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.mutedTopicObservation(inChannel: channel.id)
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) { topics = rows }
        } catch {}
    }
}

// MARK: - Settings

struct MacSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    @AppStorage(MacNotifier.dmsKey) private var notifyDirectMessages = true
    @AppStorage(MacNotifier.mentionsKey) private var notifyMentions = true
    @AppStorage(MacMessageActionStyle.storageKey) private var messageActionStyle = MacMessageActionStyle.standard
    @AppStorage(MacSidebarSettings.showsRecentKey) private var showsRecent = true
    @AppStorage(MacSidebarSettings.pinsUnreadDMsKey) private var pinsUnreadDMs = true
    @AppStorage(MacSidebarLayout.storageKey) private var sidebarLayout = MacSidebarLayout.standard

    var body: some View {
        Form {
            Section("Account") {
                if let account = model.account {
                    LabeledContent("Name", value: model.selfUserID.flatMap { model.users[$0]?.fullName } ?? "—")
                    LabeledContent("Email", value: account.email)
                    LabeledContent("Server", value: account.realmURL.host() ?? account.realmURL.absoluteString)
                    Button("Sign Out…") { ui.confirmingSignOut = true }
                } else {
                    Text("Not signed in.").foregroundStyle(TextTone.secondary)
                }
            }
            Section("Messages") {
                Picker("Show actions", selection: $messageActionStyle) {
                    ForEach(MacMessageActionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
            Section {
                Picker("Layout", selection: $sidebarLayout) {
                    ForEach(MacSidebarLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Toggle("Show Recent", isOn: $showsRecent)
                Toggle("Pin unread direct messages above channels", isOn: $pinsUnreadDMs)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Sections puts Recent, Direct Messages, your groups and the channels in a sidebar of their own, as on iPhone Duo. With pinning off, direct messages are listed only under Direct Messages.")
            }
            Section {
                Toggle("Direct messages", isOn: $notifyDirectMessages)
                Toggle("Mentions", isOn: $notifyMentions)
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Only while Zulu is running. Nothing arrives when it is closed until the notification service ships.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
