import Foundation

/// Portable preferences and a workspace-scoped service key. Never contains AWS credentials.
public struct DriveConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var workspaceID = UUID().uuidString.lowercased()
    public var apiURL = ""
    public var serviceToken: String?
    public var backupEnabled = false
    public var columns: [String] = []
    public var selectedCalendars: [String] = []
    public var intelligenceEnabled = true
    public init() {}
    public var serviceReady: Bool {
        guard backupEnabled, !(serviceToken ?? "").isEmpty,
              let url = URL(string: apiURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }
}

public struct WorkspaceMerge {
    public var workspace: Workspace
    public var hasConflicts: Bool
}

extension Workspace {
    /// A three-way merge keeps independent edits and deletions from both devices.
    /// Conflicting edits favor the current editor; the caller preserves the other version.
    public static func merge(base: Workspace, local: Workspace, remote: Workspace) -> WorkspaceMerge {
        var conflict = false
        func value<T: Equatable>(_ base: T, _ local: T, _ remote: T) -> T {
            if local == base { return remote }
            if remote == base || local == remote { return local }
            conflict = true
            return local
        }
        func collection<T: Identifiable & Equatable>(_ base: [T], _ local: [T], _ remote: [T]) -> [T] where T.ID == String {
            let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let r = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            return (local.map(\.id) + remote.map(\.id)).filter { seen.insert($0).inserted }.compactMap { value(b[$0], l[$0], r[$0]) }
        }
        var result = local
        result.notes = collection(base.notes, local.notes, remote.notes)
        result.tasks = collection(base.tasks, local.tasks, remote.tasks)
        result.meetings = collection(base.meetings, local.meetings, remote.meetings)
        result.settings = value(base.settings, local.settings, remote.settings)
        result.nodes = value(base.nodes, local.nodes, remote.nodes)
        result.strokes = value(base.strokes, local.strokes, remote.strokes)
        result.revision = remote.revision
        return WorkspaceMerge(workspace: result, hasConflicts: conflict)
    }
}

public final class DriveWorkspaceFiles {
    public let directory: URL
    public let usesICloud: Bool
    public var workspaceURL: URL { directory.appendingPathComponent("workspace.json") }
    public var configurationURL: URL { directory.appendingPathComponent("config.json") }
    public private(set) var recoveryURL: URL?
    private var baseline: Workspace?

    public init(directory: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        usesICloud = directory == nil && FileManager.default.fileExists(atPath: drive.path)
        self.directory = directory ?? (usesICloud ? drive : home).appendingPathComponent("Documents/Workmate", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func decode(_ url: URL) throws -> Workspace? {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw WorkmateError.message("iCloud is downloading your Workmate files. Try again in a moment.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url)).validated()
    }
    private func coordinated<T>(_ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: workspaceURL, options: .forMerging, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
    public func read() throws -> Workspace? {
        let value = try coordinated { try decode($0) }
        baseline = value
        return value
    }
    public func save(_ workspace: Workspace) throws -> Workspace {
        let saved = try coordinated { url in
            let remote = try decode(url)
            let merged = remote.map { Workspace.merge(base: baseline ?? Workspace(), local: workspace, remote: $0) }
            var next = try (merged?.workspace ?? workspace).validated()
            // The AWS revision is an acknowledgement, not an iCloud conflict counter.
            next.revision = workspace.revision
            if merged?.hasConflicts == true, let remote { recoveryURL = try preserve(remote, reason: "conflict") }
            // iCloud may provide additional file versions after offline edits on another Mac.
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                if let other = try decode(version.url) { recoveryURL = try preserve(other, reason: "icloud-conflict") }
                version.isResolved = true
            }
            try write(next, to: url)
            return next
        }
        baseline = saved
        return saved
    }
    public func preserve(_ workspace: Workspace, reason: String) throws -> URL {
        let folder = directory.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("\(reason)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
        try write(workspace, to: url)
        return url
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func configuration() throws -> DriveConfiguration {
        var error: NSError?
        var result: Result<DriveConfiguration, Error>?
        NSFileCoordinator().coordinate(writingItemAt: configurationURL, options: .forMerging, error: &error) { url in
            result = Result {
                // Never replace an iCloud placeholder with a fresh identity.
                let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    throw WorkmateError.message("Waiting for iCloud to download your Workmate configuration.")
                }
                if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode(DriveConfiguration.self, from: Data(contentsOf: url)) }
                let config = DriveConfiguration(); try write(config, to: url); return config
            }
        }
        if let error { throw error }
        return try result!.get()
    }
    public func updateConfiguration(_ mutate: (inout DriveConfiguration) -> Void) throws -> DriveConfiguration {
        var error: NSError?
        var result: Result<DriveConfiguration, Error>?
        NSFileCoordinator().coordinate(writingItemAt: configurationURL, options: .forMerging, error: &error) { url in
            result = Result {
                var config = try JSONDecoder().decode(DriveConfiguration.self, from: Data(contentsOf: url))
                mutate(&config); try write(config, to: url); return config
            }
        }
        if let error { throw error }
        return try result!.get()
    }
    /// Existing iCloud files always win. Legacy files remain untouched as a recovery copy.
    public func migrate(from legacy: WorkspaceFiles, account: String = "local") throws -> Workspace? {
        if let current = try read() { return current }
        let previous = try legacy.read(account) ?? legacy.read("local")
        let workspace = try previous?.workspace ?? legacy.importLegacy(legacy.directory.appendingPathComponent("Legacy/Web/store.json"))
        guard let workspace else { return nil }
        _ = try preserve(workspace, reason: "before-migration")
        return try save(workspace)
    }
}
