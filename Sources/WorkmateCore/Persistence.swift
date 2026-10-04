import Foundation
import Security

public struct CachedWorkspace: Codable {
    public var workspace: Workspace
    public var dirty: Bool
    public init(workspace: Workspace, dirty: Bool) { self.workspace = workspace; self.dirty = dirty }
}
public struct WorkspaceFiles {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workmate", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func url(_ account: String) -> URL {
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("workspace-\(safe).json")
    }
    public func read(_ account: String) throws -> CachedWorkspace? {
        let path = url(account)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        let cached = try JSONDecoder().decode(CachedWorkspace.self, from: data)
        _ = try cached.workspace.validated()
        return cached
    }
    public func save(_ cached: CachedWorkspace, account: String) throws {
        _ = try cached.workspace.validated()
        try JSONEncoder().encode(cached).write(to: url(account), options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(account).path)
    }
    public func importLegacy(_ path: URL) throws -> Workspace? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let workspace = object?["WORKSPACE#local"] else { return nil }
        return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: workspace)).validated()
    }
}
public enum Keychain {
    private static let service = "se.workmate.mac.session"
    public static func save(_ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "cloud"]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw WorkmateError.message("Could not save your sign-in in Keychain (\(status)).") }
    }
    public static func read() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "cloud", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    public static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "cloud"] as CFDictionary)
    }
}
