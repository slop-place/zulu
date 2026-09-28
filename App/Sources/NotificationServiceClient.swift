import Foundation
import ZulipAPI

/// The calls the app makes to zulu-notifyd. Registering again with the same token is
/// how the service expects to hear from a device on every launch.
struct NotificationServiceClient {
    static let platform = "ios"

    #if DEBUG
    static let apnsEnvironment = "sandbox"
    #else
    static let apnsEnvironment = "production"
    #endif

    let baseURL: URL

    private struct Registration: Encodable {
        let realmUrl: String
        let email: String
        let apiKey: String
        let deviceToken: String
        let platform: String
        let environment: String
        let appVersion: String
    }

    /// What the service hands back once. The secret authenticates every later call.
    struct Credentials: Codable {
        let deviceId: String
        let deviceSecret: String
    }

    struct Status: Decodable {
        let accountStatus: String
        let statusDetail: String?
        let devices: Int
        let queueConnected: Bool
        let parked: Bool
        let parkedUntil: Date?
        let lastEventAt: Date?
        let lastError: String?
    }

    struct TestReceipt: Decodable {
        let sent: Bool
        let statusCode: Int
        let reason: String?
    }

    struct Failure: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "notification service answered \(status): \(body)" }
    }

    /// `replacing` is what this install registered with last time. The service drops that
    /// registration, or a debug build's token would go on failing after a release install.
    func register(account: ZulipAccount, deviceToken: String, replacing previous: Credentials?) async throws -> Credentials {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let registration = Registration(
            realmUrl: account.realmURL.absoluteString,
            email: account.email,
            apiKey: account.apiKey,
            deviceToken: deviceToken,
            platform: Self.platform,
            environment: Self.apnsEnvironment,
            appVersion: version ?? ""
        )

        var request = URLRequest(url: baseURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let previous {
            request.setValue("Bearer \(previous.deviceSecret)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(registration)
        return try await send(request)
    }

    func status(_ credentials: Credentials) async throws -> Status {
        try await send(authorized(path: "v1/status", method: "GET", credentials))
    }

    func sendTest(_ credentials: Credentials) async throws -> TestReceipt {
        try await send(authorized(path: "v1/test-notification", method: "POST", credentials))
    }

    func deregister(_ credentials: Credentials) async throws {
        let request = authorized(
            path: "v1/devices/\(credentials.deviceId)", method: "DELETE", credentials
        )
        let _: Deregistered = try await send(request)
    }

    private struct Deregistered: Decodable {}

    private func authorized(path: String, method: String, _ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    /// Go writes RFC 3339 with fractional seconds, and writes an unset time as year 1
    /// rather than leaving it out.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
                ?? (try? Date.ISO8601FormatStyle().parse(raw))
            guard let parsed else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 date: \(raw)"
                ))
            }
            return parsed
        }
        return decoder
    }()
}
