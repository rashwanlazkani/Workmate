import Foundation
import Testing
@testable import WorkmateCore

struct DriveStorageTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func migrationPreservesLegacyAndNeverReplacesExistingDriveData() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = try WorkspaceFiles(directory: folder.appendingPathComponent("legacy"))
        var original = Workspace(); original.notes = [Note(title: "Existing notes", body: "Keep everything")]
        try legacy.save(.init(workspace: original, dirty: false), account: "local")
        let drive = try DriveWorkspaceFiles(directory: folder.appendingPathComponent("drive"))
        #expect(try drive.migrate(from: legacy) == original)
        #expect(try legacy.read("local")?.workspace == original)
        var newer = original; newer.notes[0].body = "A newer iCloud edit"
        _ = try drive.save(newer)
        #expect(try DriveWorkspaceFiles(directory: drive.directory).migrate(from: legacy) == newer)
        let backups = try FileManager.default.contentsOfDirectory(atPath: drive.directory.appendingPathComponent("Recovery").path)
        #expect(backups.count == 1)
    }

    @Test func twoEditorsMergeIndependentEditsAndPreserveConflictingVersions() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = try DriveWorkspaceFiles(directory: folder)
        var original = Workspace(); original.notes = [Note(title: "Agenda"), Note(title: "Decision")]
        _ = try first.save(original)
        let second = try DriveWorkspaceFiles(directory: folder)
        var onSecond = try #require(try second.read())
        var onFirst = original
        onFirst.notes[0].body = "First Mac"
        _ = try first.save(onFirst)
        onSecond.notes[1].body = "Second Mac"
        let merged = try second.save(onSecond)
        #expect(merged.notes.map(\.body) == ["First Mac", "Second Mac"])
        #expect(second.recoveryURL == nil)
        onFirst.notes[1].body = "Conflicting edit"
        let conflict = try first.save(onFirst)
        #expect(conflict.notes[1].body == "Conflicting edit")
        let preserved = try #require(first.recoveryURL)
        let other = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: preserved))
        #expect(other.notes[1].body == "Second Mac")
    }

    @Test func mergeHonorsDeletionAndRemoteTelegramCompletion() {
        var base = Workspace(); base.notes = [Note(title: "Delete"), Note(title: "Keep")]
        base.tasks = [WorkTask(title: "Finish")]
        var local = base; local.notes.removeFirst()
        var remote = base; remote.tasks[0].setCompleted(true)
        let merged = Workspace.merge(base: base, local: local, remote: remote)
        #expect(merged.workspace.notes.count == 1)
        #expect(merged.workspace.tasks[0].isArchived)
        #expect(!merged.hasConflicts)
    }

    @Test func savingAWSAcknowledgementDoesNotRestoreTheOldRevision() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let drive = try DriveWorkspaceFiles(directory: folder)
        var workspace = Workspace(); workspace.revision = 4
        _ = try drive.save(workspace)
        workspace.revision = 5
        #expect(try drive.save(workspace).revision == 5)
        #expect(try drive.read()?.revision == 5)
    }

    @Test func corruptCloudFileIsNotOverwritten() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let drive = try DriveWorkspaceFiles(directory: folder)
        _ = try drive.save(Workspace())
        let damaged = Data("incomplete download".utf8)
        try damaged.write(to: drive.workspaceURL)
        #expect(throws: (any Error).self) { try drive.save(Workspace()) }
        #expect(try Data(contentsOf: drive.workspaceURL) == damaged)
    }

    @Test func configurationKeepsStableIdentityAndOtherDevicesFields() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = try DriveWorkspaceFiles(directory: folder)
        let config = try first.configuration()
        let second = try DriveWorkspaceFiles(directory: folder)
        _ = try second.updateConfiguration { $0.serviceToken = "private-test-key" }
        let updated = try first.updateConfiguration { $0.columns = ["note"] }
        #expect(updated.workspaceID == config.workspaceID)
        #expect(updated.serviceToken == "private-test-key")
        #expect(try second.configuration().columns == ["note"])
        let permissions = try FileManager.default.attributesOfItem(atPath: first.configurationURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func picksCurrentUsersDriveOrDocumentsWithoutCreatingFakeICloud() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let local = try DriveWorkspaceFiles(home: folder)
        #expect(!local.usesICloud)
        #expect(local.directory == folder.appendingPathComponent("Documents/Workmate", isDirectory: true))
        let cloud = folder.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let synced = try DriveWorkspaceFiles(home: folder)
        #expect(synced.usesICloud)
        #expect(synced.directory == cloud.appendingPathComponent("Documents/Workmate", isDirectory: true))
    }
}
