import AppKit
import UserNotifications
import ZulipAPI
import ZuluStore

/// Notification Center banners for what is addressed to you — a direct message or a
/// mention — while the app is running. The queue is live the whole time the app is,
/// which is exactly the case the push service does not need to cover.
@MainActor
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let dmsKey = "notify.directMessages"
    static let mentionsKey = "notify.mentions"

    private weak var model: AppModel?
    private weak var ui: MacUIState?

    func attach(model: AppModel, ui: MacUIState) {
        self.model = model
        self.ui = ui
        model.messageArrivalHandler = { [weak self] message in self?.arrived(message) }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func arrived(_ message: ZulipMessage) {
        guard let model, let selfID = model.selfUserID else { return }
        let defaults = UserDefaults.standard
        let rule = NotificationRule(
            directMessages: defaults.object(forKey: Self.dmsKey) as? Bool ?? true,
            mentions: defaults.object(forKey: Self.mentionsKey) as? Bool ?? true
        )

        let isDirect = !message.isChannelMessage
        let level = message.stream_id.map { model.effectiveNotificationLevel(forTopic: message.subject, inChannel: $0) }
        guard rule.allows(flags: message.flags ?? [], isOwn: message.sender_id == selfID, level: level) else { return }

        let destination: AppModel.Destination
        let subtitle: String
        if isDirect {
            let key = MessageRecord.dmKey(for: message.dmParticipants.map(\.id), selfUserID: selfID)
            destination = .dm(key)
            subtitle = message.dmParticipants.count > 2 ? "Group direct message" : ""
        } else {
            guard let channelID = message.stream_id else { return }
            let channelName = model.channel(channelID)?.name ?? message.channelName ?? ""
            destination = .topic(channelID: channelID, name: message.subject, channelName: channelName)
            subtitle = "#\(channelName) › \(message.subject.isEmpty ? "general chat" : message.subject)"
        }

        // Already reading it: a banner would only repeat what is on screen.
        if NSApp.isActive, model.isShowing(destination) { return }

        let content = UNMutableNotificationContent()
        content.title = message.sender_full_name
        content.subtitle = subtitle
        content.body = String(MessageActionsController.plainText(of: message.content).prefix(400))
        content.sound = .default
        content.threadIdentifier = Self.thread(for: destination)
        content.userInfo = Self.encode(destination)

        let request = UNNotificationRequest(
            identifier: "zulu-message-\(message.id)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let destination = Self.decode(info) else { return }
        await MainActor.run {
            guard let model, let ui else { return }
            ui.section = MacShellView.section(for: destination, model: model)
            model.destination = destination
            NSApp.activate()
        }
    }

    // MARK: destination in userInfo

    nonisolated private static func thread(for destination: AppModel.Destination) -> String {
        switch destination {
        case .dm(let key): "d:\(key)"
        case .topic(let channelID, let name, _): "c:\(channelID)/\(name)"
        case .channel(let id): "c:\(id)"
        }
    }

    nonisolated private static func encode(_ destination: AppModel.Destination) -> [String: String] {
        switch destination {
        case .channel(let id):
            ["kind": "channel", "channel": String(id)]
        case .dm(let key):
            ["kind": "dm", "key": key]
        case .topic(let channelID, let name, let channelName):
            ["kind": "topic", "channel": String(channelID), "name": name, "channelName": channelName]
        }
    }

    nonisolated private static func decode(_ info: [AnyHashable: Any]) -> AppModel.Destination? {
        switch info["kind"] as? String {
        case "channel":
            return (info["channel"] as? String).flatMap(Int.init).map { .channel($0) }
        case "dm":
            return (info["key"] as? String).map { .dm($0) }
        case "topic":
            guard let id = (info["channel"] as? String).flatMap(Int.init),
                  let name = info["name"] as? String,
                  let channelName = info["channelName"] as? String
            else { return nil }
            return .topic(channelID: id, name: name, channelName: channelName)
        default:
            return nil
        }
    }
}
