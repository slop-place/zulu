import Foundation

/// What Zulu needs to talk to one realm as one user.
public struct ZulipAccount: Sendable, Equatable, Codable {
    /// Canonical realm URL as the server reported it, which may differ from what the user typed.
    public var realmURL: URL
    /// The account's delivery email. Basic auth needs this, not whatever was typed at sign-in.
    public var email: String
    public var apiKey: String
    public var userID: Int

    public init(realmURL: URL, email: String, apiKey: String, userID: Int) {
        self.realmURL = realmURL
        self.email = email
        self.apiKey = apiKey
        self.userID = userID
    }
}

public struct ZulipError: Error, Sendable, LocalizedError {
    public enum Kind: Sendable, Equatable {
        /// The server answered with `result: "error"`. `code` is Zulip's machine-readable code.
        case api(code: String, status: Int)
        case transport
        case decoding
        case badResponse
    }

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public let kind: Kind
    public let message: String

    public var errorDescription: String? { message }

    public var code: String? {
        if case .api(let code, _) = kind { return code }
        return nil
    }

    public static func api(code: String, status: Int, message: String) -> ZulipError {
        ZulipError(kind: .api(code: code, status: status), message: message)
    }
}

/// Zulip wraps every response in `result`, and puts the failure reason in `msg` and `code`.
private struct ZulipEnvelope: Decodable {
    let result: String
    let msg: String?
    let code: String?
}

public struct ZulipClient: Sendable {
    public let realmURL: URL
    public let account: ZulipAccount?
    private let session: URLSession

    public init(realmURL: URL, account: ZulipAccount? = nil, session: URLSession = .shared) {
        self.realmURL = realmURL
        self.account = account
        self.session = session
    }

    public init(account: ZulipAccount, session: URLSession = .shared) {
        self.init(realmURL: account.realmURL, account: account, session: session)
    }

    public func authenticated(as account: ZulipAccount) -> ZulipClient {
        ZulipClient(realmURL: account.realmURL, account: account, session: session)
    }

    // MARK: requests

    public enum Method: String, Sendable { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }

    /// Zulip's API is form-encoded in, JSON out. Nested values are JSON-encoded strings inside the form.
    public func send<T: Decodable>(
        _ method: Method,
        _ path: String,
        parameters: [String: String] = [:],
        timeout: TimeInterval = 60,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await raw(method, path, parameters: parameters, timeout: timeout)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ZulipError(kind: .decoding, message: "Could not decode \(T.self): \(error)")
        }
    }

    public func raw(
        _ method: Method,
        _ path: String,
        parameters: [String: String] = [:],
        timeout: TimeInterval = 60
    ) async throws -> Data {
        var url = realmURL.appending(path: "api/v1/\(path)")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        if method == .get {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            if !parameters.isEmpty {
                components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            url = components.url!
            request.url = url
        } else if !parameters.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(parameters)
        }

        if let account {
            let pair = "\(account.email):\(account.apiKey)"
            let encoded = Data(pair.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ZulipError(kind: .transport, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ZulipError(kind: .badResponse, message: "Not an HTTP response")
        }

        // Errors and successes share a shape, so the envelope is checked before decoding.
        if let envelope = try? Self.decoder.decode(ZulipEnvelope.self, from: data), envelope.result == "error" {
            throw ZulipError.api(
                code: envelope.code ?? "BAD_REQUEST",
                status: http.statusCode,
                message: envelope.msg ?? "The server rejected the request."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ZulipError(kind: .badResponse, message: "HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: encoding

    /// A Zulip-specific UA. Sending one that looks like the Zulip desktop app diverts the
    /// SSO flow to a paste-your-token page meant for Electron.
    public static let userAgent = "Zulu/0.1 (\(platform))"

    #if os(macOS)
    private static let platform = "macOS"
    #else
    private static let platform = "iOS"
    #endif

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    static let encoder = JSONEncoder()

    static func formEncode(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = parameters
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    /// Several parameters are JSON documents passed inside a form field.
    static func json(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
