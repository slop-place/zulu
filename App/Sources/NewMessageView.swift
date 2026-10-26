import SwiftUI
import ZuluStore

/// Pick one person for a conversation, or several for a group one.
struct NewMessageView: View {
    let onStart: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chosen: [Int] = []

    var body: some View {
        NavigationStack {
            List {
                if !chosen.isEmpty {
                    Section {
                        FlowRow(spacing: 6) {
                            ForEach(chosen, id: \.self) { id in
                                Button { toggle(id) } label: {
                                    HStack(spacing: 4) {
                                        Text(model.name(forUser: id)).font(.callout)
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } footer: {
                        if chosen.count > 1 {
                            Text("Group message with \(chosen.count) people")
                        }
                    }
                }
                Section {
                    ForEach(people) { user in personRow(user) }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Name or email"
            )
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }.disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func personRow(_ user: UserRecord) -> some View {
        Button { toggle(user.id) } label: {
            HStack(spacing: 10) {
                SenderAvatar(name: user.fullName, userID: user.id, size: 32)
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
    }

    private func start() {
        guard let key = model.dmKey(with: chosen) else { return }
        dismiss()
        onStart(key)
    }
}
