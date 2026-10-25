import PhotosUI
import SwiftUI
import ZuluStore

/// Create or change one channel group: its name, its icon, and which channels it holds.
struct GroupEditor: View {
    let groupID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<Int> = []
    @State private var icon: Data?
    @State private var pickedIcon: PhotosPickerItem?
    @State private var showIconPicker = false
    @State private var loaded = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Button { showIconPicker = true } label: {
                            GroupAvatar(name: name, icon: icon, size: 56, active: true)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Group name", text: $name)
                                .font(.headline)
                            Text(icon == nil ? "Tap to choose an icon" : "Tap to change")
                                .font(.caption)
                                .foregroundStyle(TextTone.secondary)
                        }

                        if icon != nil {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                icon = nil
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button("Delete Group", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } footer: {
                    Text("Its channels are kept. Nothing changes on the server.")
                }

                Section("Channels") {
                    ForEach(model.allChannels) { channel in
                        Button {
                            if selected.contains(channel.id) {
                                selected.remove(channel.id)
                            } else {
                                selected.insert(channel.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                ChannelIcon(
                                    isForum: channel.rendersAsForum, restricted: channel.isRestricted
                                )
                                .foregroundStyle(TextTone.secondary)
                                .frame(width: 26, alignment: .leading)
                                Text(channel.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(channel.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog(
                "Delete “\(name)”?", isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) {
                    model.deleteGroup(id: groupID)
                    dismiss()
                }
            }
            .photosPicker(isPresented: $showIconPicker, selection: $pickedIcon, matching: .images)
            .task(id: pickedIcon) {
                guard let pickedIcon else { return }
                if let data = try? await pickedIcon.loadTransferable(type: Data.self) {
                    icon = GroupAvatar.downscale(data)
                }
                self.pickedIcon = nil
            }
            .task {
                guard !loaded else { return }
                loaded = true
                if let group = model.groups.first(where: { $0.id == groupID }) {
                    name = group.name
                    icon = group.icon
                }
                selected = Set(model.channelIDs(inGroup: groupID))
            }
        }
    }

    private func save() {
        model.renameGroup(id: groupID, to: name.trimmingCharacters(in: .whitespaces))
        model.setGroupIcon(id: groupID, icon: icon)
        model.setChannels(Array(selected), inGroup: groupID)
        dismiss()
    }
}

/// The rail bubble for a group: its icon, or its initials when it has none.
struct GroupAvatar: View {
    let name: String
    let icon: Data?
    var size: CGFloat = 46
    var active = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: active ? size * 0.3 : size * 0.5)
        Group {
            if let icon, let image = UIImage(data: icon) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.33, weight: .bold))
                    .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .glassEffect(
            .regular.tint(active && icon == nil ? .accentColor : nil).interactive(), in: shape
        )
        .overlay {
            if active && icon != nil { shape.stroke(Color.accentColor, lineWidth: 2.5) }
        }
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Icons sync between devices, so they are stored small rather than at whatever size
    /// the camera produced.
    static func downscale(_ data: Data, to side: CGFloat = 256) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(side / max(image.size.width, image.size.height), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

/// A plain system-image rail button, styled to match the group bubbles beside it.
struct RailIcon: View {
    let systemImage: String
    var active = false
    var size: CGFloat = 46

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: active ? size * 0.3 : size * 0.5)
        Image(systemName: systemImage)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(active ? .accentColor : nil).interactive(), in: shape)
    }
}
