import OSLog
import SwiftUI
import UIKit
import UserNotifications
import ZulipAPI
import ZuluStore

/// Pushes from zulu-notifyd. Once signed in it asks for permission and hands the APNs
/// token to the service; a tapped push opens its conversation, and opening a
/// conversation clears the pushes about it.
@MainActor
final class PushNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let log = Logger(subsystem: "com.bwees.zulu", category: "push")

    let settings = NotificationServiceSettings()
    private weak var model: AppModel?
    /// A tap that launched the app before anyone was signed in to route it.
    private var pendingTap: PushTarget?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before launch finishes, or the tap that launched the app is never delivered.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func attach(model: AppModel) {
        self.model = model
    }

    func enable() async {
        if let pendingTap {
            self.pendingTap = nil
            open(pendingTap)
        }
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        await settings.refreshPermission()
        guard granted == true else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func clearDelivered() async {
        guard let model else { return }
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications().filter { notification in
            destination(for: PushTarget(notification.request.content.userInfo))
                .map(model.isShowing) ?? false
        }
        center.removeDeliveredNotifications(withIdentifiers: stale.map(\.request.identifier))
    }

    // MARK: APNs

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        settings.receive(deviceToken: deviceToken)
        guard let account = model?.account else { return }
        Task { await settings.register(account: account) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.log.error("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let target = PushTarget(notification.request.content.userInfo)
        let alreadyShowing = await MainActor.run {
            guard let model else { return false }
            return destination(for: target).map(model.isShowing) ?? false
        }
        return alreadyShowing ? [] : [.banner, .sound, .list]
    }

    /// Main-actor isolated, unlike `willPresent`: UIKit asserts that a tap's completion
    /// handler runs on the main thread, and a nonisolated async witness calls it from
    /// the global executor.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        open(PushTarget(response.notification.request.content.userInfo))
    }

    // MARK: routing

    private func open(_ target: PushTarget) {
        guard let model, model.account != nil else {
            pendingTap = target
            return
        }
        if let destination = destination(for: target) {
            model.destination = destination
        }
    }

    private func destination(for target: PushTarget) -> AppModel.Destination? {
        guard let model, let account = model.account,
              let realm = target.realm.flatMap(URL.init(string:)),
              realm.host() == account.realmURL.host()
        else { return nil }

        // Always the topic, never a chat channel's page: that page lists topics from the
        // store, which may not have synced the pushed message yet and would show empty.
        if let channelID = target.channelID {
            return .topic(
                channelID: channelID,
                name: target.topic ?? "",
                channelName: model.channel(channelID)?.name ?? target.channelName ?? ""
            )
        }
        guard !target.recipientIDs.isEmpty else { return nil }
        return .dm(MessageRecord.dmKey(for: target.recipientIDs, selfUserID: account.userID))
    }
}

/// The custom keys zulu-notifyd puts beside `aps`.
private enum PayloadKey {
    static let realm = "realmUrl"
    static let channelID = "zulipStreamId"
    static let channelName = "zulipChannel"
    static let topic = "zulipTopic"
    static let recipientIDs = "zulipRecipientIds"
}

/// What a push is about, read off its payload before it crosses to the main actor.
private struct PushTarget: Sendable {
    let realm: String?
    let channelID: Int?
    let channelName: String?
    let topic: String?
    let recipientIDs: [Int]

    init(_ info: [AnyHashable: Any]) {
        realm = info[PayloadKey.realm] as? String
        channelID = info[PayloadKey.channelID] as? Int
        channelName = info[PayloadKey.channelName] as? String
        topic = info[PayloadKey.topic] as? String
        recipientIDs = info[PayloadKey.recipientIDs] as? [Int] ?? []
    }
}
