import Foundation
import Testing
@testable import WorkmateCore

struct ArchiveTests {
    @Test func completionSurvivesSavingAndCanBeRestoredWithoutLosingDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try WorkspaceFiles(directory: directory)
        let date = try #require(Dates.parse("2026-10-04T15:00:00Z"))
        var workspace = Workspace()
        let note = Note(title: "PO-sync")
        let meeting = Meeting(title: "PO-sync", start: date, end: date.addingTimeInterval(3600))
        var task = WorkTask(title: "Prepare agenda", priority: .urgent, reminder: date.addingTimeInterval(7200), noteId: note.id)
        task.meetingId = meeting.id
        let original = task
        task.setCompleted(true, at: date)
        workspace.tasks = [task]; workspace.notes = [note]; workspace.meetings = [meeting]
        try files.save(.init(workspace: workspace, dirty: true), account: "archive-test")
        var restored = try #require(try files.read("archive-test")).workspace
        #expect(restored.archivedTasks.map(\.id) == [task.id])
        #expect(restored.archivedTasks.first?.completedAt == Dates.iso(date))
        #expect(restored.openTasks.isEmpty)
        #expect(restored.briefTasks.isEmpty)
        #expect(restored.search("agenda").tasks.isEmpty)
        #expect(restored.search("agenda", includeArchived: true).tasks.map(\.id) == [task.id])
        restored.tasks[0].setCompleted(false)
        #expect(restored.tasks[0] == original)
        #expect(restored.archivedTasks.isEmpty)
        #expect(restored.openTasks == [original])
        #expect(restored.briefTasks == [original])
        #expect(restored.search("agenda").tasks == [original])
    }

    @Test func archiveFilterAppliesToTextAndEveryMeetingAssociation() {
        var workspace = Workspace()
        let meeting = Meeting(title: "PO-sync", start: Date(), end: Date().addingTimeInterval(3600))
        var linked = Note(title: "Agenda"); linked.meetingIds = [meeting.id]
        let mentioned = Note(title: "Wednesday", body: "PO sync discussion")
        let suggested = Note(title: "Product plans")
        workspace.meetings = [meeting]; workspace.notes = [linked, mentioned, suggested]
        var direct = WorkTask(title: "Prepare slides"); direct.meetingId = meeting.id
        workspace.tasks = [
            WorkTask(title: "PO-sync follow-up", priority: .urgent), direct,
            WorkTask(title: "Review agenda", noteId: linked.id),
            WorkTask(title: "Read decisions", noteId: mentioned.id),
            WorkTask(title: "Update plan", noteId: suggested.id)
        ]
        for index in workspace.tasks.indices { workspace.tasks[index].setCompleted(true) }
        let archivedIDs = Set(workspace.tasks.map(\.id))
        let active = WorkTask(title: "PO-sync preparation", priority: .low)
        workspace.tasks.append(active)
        let suggestions = [suggested.id: [meeting.id]]
        let defaultResults = workspace.search("PO-SYNC", suggestedMeetingLinks: suggestions)
        #expect(defaultResults.tasks == [active])
        #expect(defaultResults.count == 5)
        let allResults = workspace.search("PO-SYNC", includeArchived: true, suggestedMeetingLinks: suggestions)
        #expect(allResults.tasks.first == active)
        #expect(Set(allResults.tasks.dropFirst().map(\.id)) == archivedIDs)
        #expect(allResults.count == 10)
        #expect(workspace.search("unrelated", includeArchived: true).count == 0)
        #expect(workspace.search("", includeArchived: true).count == 0)
    }

    @Test func existingCompletedTasksAppearInArchiveNewestFirst() throws {
        var oldTask = WorkTask(title: "Older completed task")
        oldTask.status = "done"; oldTask.completedAt = "2026-10-01T10:00:00Z"
        var legacyTask = WorkTask(title: "Imported completed task without timestamp")
        legacyTask.status = "done"; legacyTask.createdAt = "2026-10-02T10:00:00Z"
        var newest = WorkTask(title: "Recently completed task")
        newest.setCompleted(true, at: try #require(Dates.parse("2026-10-04T10:00:00Z")))
        var workspace = Workspace()
        workspace.tasks = [oldTask, WorkTask(title: "Open task"), legacyTask, newest]
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(decoded.archivedTasks.map(\.id) == [newest.id, legacyTask.id, oldTask.id])
    }
}
