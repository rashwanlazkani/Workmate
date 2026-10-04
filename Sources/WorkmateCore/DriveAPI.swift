import Foundation

/// Access is scoped to one private workspace, provisioned into its iCloud config file.
public actor DriveAPI {
    private var configuration: DriveConfiguration
    private let network: URLSession
    public init(configuration: DriveConfiguration, network: URLSession = .shared) {
        self.configuration = configuration; self.network = network
    }
    public func configure(_ value: DriveConfiguration) { configuration = value }
    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard configuration.serviceReady, let token = configuration.serviceToken,
              let base = URL(string: configuration.apiURL), base.scheme == "https", base.host != nil,
              let url = URL(string: configuration.apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/device" + path) else {
            throw WorkmateError.message("AWS backup is not connected to this Workmate folder yet.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 { throw WorkmateError.conflict }
        guard (200..<300).contains(status) else {
            if status == 401 { throw WorkmateError.message("The AWS connection key needs to be renewed. Your files are safe in your Workmate folder.") }
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw WorkmateError.message(detail?["error"] as? String ?? "AWS backup is unavailable (\(status)). Your files are saved locally; Workmate will retry.")
        }
        return data
    }
    public func load() async throws -> Workspace { try JSONDecoder().decode(Workspace.self, from: await request("/workspace")).validated() }
    public func save(_ workspace: Workspace) async throws -> Workspace {
        try JSONDecoder().decode(Workspace.self, from: await request("/workspace", method: "PUT", body: JSONEncoder().encode(workspace.validated()))).validated()
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
