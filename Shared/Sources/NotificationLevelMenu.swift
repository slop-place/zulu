import SwiftUI
import ZuluStore

/// The Notifications picker every context menu shares. "Default" names what it falls
/// back to, so choosing it is not a guess.
struct NotificationLevelMenu: View {
    let selection: NotificationLevel?
    let defaultLabel: String
    let choose: (NotificationLevel?) -> Void
    /// Laid flat, for a menu that is already about notifications and needs no submenu.
    var inline = false

    var body: some View {
        if inline {
            // No label: the menu this sits in already says what it is about.
            Picker(selection: Binding(get: { selection }, set: choose)) {
                options
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } else {
            Picker("Notifications", systemImage: "bell", selection: Binding(get: { selection }, set: choose)) {
                options
            }
            .pickerStyle(.menu)
        }
    }

    private var options: some View {
        Group {
            Text(defaultLabel).tag(NotificationLevel?.none)
            ForEach(NotificationLevel.allCases, id: \.self) { level in
                Text(level.label).tag(NotificationLevel?.some(level))
            }
        }
    }

    func flattened() -> Self {
        var copy = self
        copy.inline = true
        return copy
    }
}

extension NotificationLevelMenu {
    static func channel(_ id: Int, model: AppModel) -> Self {
        Self(
            selection: model.notificationSelection(forChannel: id),
            defaultLabel: "Default (\(model.inheritedNotificationLevel(forChannel: id).label))"
        ) { level in
            Task { await model.setNotificationOverride(level, forChannel: id) }
        }
    }

    static func topic(_ topic: String, inChannel channelID: Int, model: AppModel) -> Self {
        Self(
            selection: model.notificationLevel(forTopic: topic, inChannel: channelID),
            defaultLabel: "Default (\(model.notificationLevel(forChannel: channelID).label))"
        ) { level in
            Task { await model.setNotificationLevel(level, forTopic: topic, inChannel: channelID) }
        }
    }

    /// A group with no level leaves each of its channels to its own settings.
    static func group(_ id: String, model: AppModel) -> Self {
        Self(selection: model.notificationLevel(forGroup: id), defaultLabel: "Per Channel") { level in
            Task { await model.setNotificationLevel(level, forGroup: id) }
        }
    }
}
