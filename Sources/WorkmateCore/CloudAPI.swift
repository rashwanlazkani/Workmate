import Foundation

public struct CloudConfig: Codable, Sendable {
    public let region: String
    public let clientId: String
    public let apiUrl: String
    public let legacyStore: String?
    public init(region: String, clientId: String, apiUrl: String, legacyStore: String? = nil) {
        self.region = region; self.clientId = clientId; self.apiUrl = apiUrl; self.legacyStore = legacyStore
    }
}
public struct CloudSession: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var subject: String
    public var email: String
}
public struct LoginChallenge: Sendable {
    public let session: String
    public let username: String
    public let email: String
}
public enum SignInResult { case session(CloudSession), challenge(LoginChallenge) }
public struct TelegramStatus: Decodable, Sendable {
    public var configured: Bool
    public var connected: Bool
    public var botName: String?
    public var link: String?
    public var lastError: String?
    public var agentLastSeen: String?
    public static var empty: Self { .init(configured: false, connected: false) }
}

public actor CloudAPI {
    private let config: CloudConfig
    private let network: URLSession
    private var session: CloudSession?
    private let persistSession: Bool
    public init(config: CloudConfig, network: URLSession = .shared, restoreSession: Bool = true) {
        self.config = config; self.network = network; self.persistSession = restoreSession
        if restoreSession, let data = Keychain.read() { self.session = try? JSONDecoder().decode(CloudSession.self, from: data) }
    }
    public func currentSession() -> CloudSession? { session }
    public func signOut() { session = nil; if persistSession { Keychain.delete() } }
    private func auth(_ target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://cognito-idp.\(config.region).amazonaws.com/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await network.data(for: request)
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WorkmateError.message(result["message"] as? String ?? "Unable to sign in. Check your email and password.")
        }
        return result
    }
    public func signIn(email: String, password: String) async throws -> SignInResult {
        let data = try await auth("InitiateAuth", body: ["ClientId": config.clientId, "AuthFlow": "USER_PASSWORD_AUTH", "AuthParameters": ["USERNAME": email, "PASSWORD": password]])
        if data["ChallengeName"] as? String == "NEW_PASSWORD_REQUIRED", let s = data["Session"] as? String {
            let fields = data["ChallengeParameters"] as? [String: String]
            return .challenge(.init(session: s, username: fields?["USER_ID_FOR_SRP"] ?? email, email: email))
        }
        return .session(try accept(data, email: email))
    }
    public func completeChallenge(_ challenge: LoginChallenge, password: String) async throws -> CloudSession {
        let data = try await auth("RespondToAuthChallenge", body: ["ClientId": config.clientId, "ChallengeName": "NEW_PASSWORD_REQUIRED", "Session": challenge.session, "ChallengeResponses": ["USERNAME": challenge.username, "NEW_PASSWORD": password]])
        return try accept(data, email: challenge.email)
    }
    private func accept(_ response: [String: Any], email: String) throws -> CloudSession {
        guard let result = response["AuthenticationResult"] as? [String: Any], let token = result["AccessToken"] as? String else {
            throw WorkmateError.message("This account requires an unsupported sign-in step. Contact your workspace administrator.")
        }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw WorkmateError.unauthorized }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any], let subject = fields["sub"] as? String, UUID(uuidString: subject) != nil else { throw WorkmateError.unauthorized }
        let value = CloudSession(accessToken: token, refreshToken: result["RefreshToken"] as? String ?? session?.refreshToken ?? "", expiresAt: Date().addingTimeInterval(result["ExpiresIn"] as? Double ?? 3600), subject: subject, email: email)
        if persistSession { try Keychain.save(JSONEncoder().encode(value)) }
        session = value
        return value
    }
    private func refresh() async throws {
        guard let s = session, !s.refreshToken.isEmpty else { throw WorkmateError.unauthorized }
        let result = try await auth("InitiateAuth", body: ["ClientId": config.clientId, "AuthFlow": "REFRESH_TOKEN_AUTH", "AuthParameters": ["REFRESH_TOKEN": s.refreshToken]])
        _ = try accept(result, email: s.email)
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, retried: Bool = false) async throws -> Data {
        guard let current = session else { throw WorkmateError.unauthorized }
        if current.expiresAt.timeIntervalSinceNow < 60 { try await refresh() }
        var request = URLRequest(url: URL(string: config.apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session!.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            if !retried { try await refresh(); return try await self.request(path, method: method, body: body, retried: true) }
            throw WorkmateError.unauthorized
        }
        if status == 409 { throw WorkmateError.conflict }
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw WorkmateError.message(json?["error"] as? String ?? "Cloud request failed (\(status)). Try again.")
        }
        return data
    }
    public func load() async throws -> Workspace { try JSONDecoder().decode(Workspace.self, from: await request("/workspace")).validated() }
    public func save(_ workspace: Workspace) async throws -> Workspace {
        try JSONDecoder().decode(Workspace.self, from: await request("/workspace", method: "PUT", body: JSONEncoder().encode(workspace.validated())))
    }
    public func telegramStatus() async throws -> TelegramStatus { try JSONDecoder().decode(TelegramStatus.self, from: await request("/telegram/status")) }
    public func connectTelegram(_ token: String) async throws -> TelegramStatus {
        try JSONDecoder().decode(TelegramStatus.self, from: await request("/telegram/connect", method: "POST", body: JSONSerialization.data(withJSONObject: ["token": token])))
    }
    public func disconnectTelegram() async throws { _ = try await request("/telegram/disconnect", method: "POST", body: Data("{}".utf8)) }
    public func sendBrief(priorities: [Priority]) async throws {
        _ = try await request("/telegram/test", method: "POST", body: JSONSerialization.data(withJSONObject: ["kind": "digest", "priorities": priorities.map(\.rawValue)]))
    }
}
