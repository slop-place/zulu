import Foundation
import OSLog
import UserNotifications
import ZulipAPI

/// Which zulu-notifyd this device uses, and whether it is working. The URL is the
/// user's to set; nothing is registered until they do.
@MainActor
@Observable
final class NotificationServiceSettings {
    private static let log = Logger(subsystem: "com.bwees.zulu", category: "push")
    private static let urlKey = "notify.serviceURL"
    private static let secretService = "com.bwees.zulu.notify-device"

    enum Registration: Equatable {
        case unconfigured
        case waitingForDeviceToken
        case registering
        case registered
        case failed(String)
    }

    enum Check<Value> {
        case idle
        case running
        case done(Value)
        case failed(String)
    }

    enum URLProblem: LocalizedError {
        case notHTTP

        var errorDescription: String? { "Enter an http or https URL." }
    }

    private(set) var serviceURL: URL?
    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    private(set) var registration: Registration = .unconfigured
    private(set) var status: Check<NotificationServiceClient.Status> = .idle
    private(set) var test: Check<NotificationServiceClient.TestReceipt> = .idle

    init() {
        serviceURL = UserDefaults.standard.url(forKey: Self.urlKey)
    }

    private var client: NotificationServiceClient? {
        serviceURL.map(NotificationServiceClient.init(baseURL:))
    }

    // MARK: configuring

    /// An empty string turns the service off. Either way the device leaves the old
    /// service first, or it would keep pushing alongside the new one.
    func setServiceURL(_ raw: String, account: ZulipAccount?) async throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if trimmed.isEmpty {
            url = nil
        } else {
            guard let parsed = URL(string: trimmed), ["http", "https"].contains(parsed.scheme)
            else { throw URLProblem.notHTTP }
            url = parsed
        }
        guard url != serviceURL else { return }

        await leaveCurrentService()
        serviceURL = url
        UserDefaults.standard.set(url, forKey: Self.urlKey)
        status = .idle
        test = .idle

        if let account { await register(account: account) }
    }

    func receive(deviceToken token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
    }

    func register(account: ZulipAccount) async {
        guard let client, let serviceURL else {
            registration = .unconfigured
            return
        }
        guard let deviceToken else {
            registration = .waitingForDeviceToken
            return
        }
        registration = .registering
        do {
            let credentials = try await client.register(
                account: account, deviceToken: deviceToken, replacing: storedCredentials()
            )
            try store(credentials, for: serviceURL)
            registration = .registered
        } catch {
            Self.log.error("notification service registration failed: \(error.localizedDescription)")
            registration = .failed(error.localizedDescription)
        }
    }

    // MARK: checking

    func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func refreshStatus() async {
        guard let client, let credentials = storedCredentials() else { return }
        status = .running
        do {
            status = .done(try await client.status(credentials))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func sendTest() async {
        guard let client, let credentials = storedCredentials() else { return }
        test = .running
        do {
            test = .done(try await client.sendTest(credentials))
        } catch {
            test = .failed(error.localizedDescription)
        }
    }

    var canTalkToService: Bool { storedCredentials() != nil }

    // MARK: credentials

    private func leaveCurrentService() async {
        guard let client, let serviceURL, let credentials = storedCredentials() else { return }
        do {
            try await client.deregister(credentials)
        } catch {
            Self.log.error("notification service deregistration failed: \(error.localizedDescription)")
        }
        SecretStore.delete(service: Self.secretService, account: serviceURL.absoluteString)
        registration = .unconfigured
    }

    private func store(_ credentials: NotificationServiceClient.Credentials, for url: URL) throws {
        let encoded = String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
        try SecretStore.write(encoded, service: Self.secretService, account: url.absoluteString)
    }

    private func storedCredentials() -> NotificationServiceClient.Credentials? {
        guard let serviceURL,
              let raw = SecretStore.read(service: Self.secretService, account: serviceURL.absoluteString)
        else { return nil }
        return try? JSONDecoder().decode(NotificationServiceClient.Credentials.self, from: Data(raw.utf8))
    }
}
