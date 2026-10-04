import Foundation
import Testing
@testable import WorkmateCore

struct CoreTests {
    @Test func testLegacyPriorityAndPreferences() throws {
        var w = Workspace()
        w.tasks = [WorkTask(title: "A real action", priority: .medium)]
        w.notes = [Note(title: "My meeting", body: "Actual work")]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String: Any]
        var tasks = json["tasks"] as! [[String: Any]]
        tasks[0]["priority"] = "normal"; json["tasks"] = tasks
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "digestPriorities"); json["settings"] = settings
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.tasks[0].priority, .medium)
        XCTAssertEqual(decoded.settings.digestPriorities, Priority.allCases)
        XCTAssertEqual(decoded.notes, w.notes)
    }
    @Test func testBriefFiltersCompletedAndOrdersPriorities() {
        var w = Workspace()
        w.tasks = [WorkTask(title: "Low", priority: .low), WorkTask(title: "High", priority: .high), WorkTask(title: "Urgent", priority: .urgent), WorkTask(title: "Medium", priority: .medium), WorkTask(title: "Finished urgent", priority: .urgent)]
        w.tasks[4].status = "done"
        w.settings.digestPriorities = [.high, .urgent]
        XCTAssertEqual(w.briefTasks.map(\.title), ["Urgent", "High"])
        XCTAssertTrue(w.brief.contains("2 open actions"))
        XCTAssertFalse(w.brief.contains("Finished urgent"))
        XCTAssertFalse(w.brief.contains("Medium"))
    }
    @Test func testISOAndLocalReminderRoundTripAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let beforeDST = try XCTUnwrap(Dates.parse("2026-10-24T10:00:00.000Z"))
        let morning = Dates.tomorrowMorning(now: beforeDST, calendar: calendar)
        XCTAssertEqual(Dates.iso(morning), "2026-10-25T08:00:00Z")
        let task = WorkTask(title: "Morning call", reminder: morning)
        let restored = try JSONDecoder().decode(WorkTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(restored.reminder, morning)
        XCTAssertEqual(calendar.component(.hour, from: restored.reminder!), 9)
    }
    @Test func testNativeStoragePreservesLegacyDrawingAndDueDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try WorkspaceFiles(directory: root)
        var w = Workspace()
        w.notes = [Note(title: "Möte", body: "你好 🪴")]
        w.tasks = [WorkTask(title: "Follow up", priority: .urgent)]
        w.tasks[0].due = "2026-10-09"
        w.nodes = [.object(["text": .string("Existing canvas"), "x": .number(420)])]
        w.strokes = [.object(["points": .array([.array([.number(10), .number(20)])])])]
        try files.save(.init(workspace: w, dirty: true), account: "test")
        let restored = try XCTUnwrap(files.read("test"))
        XCTAssertEqual(restored.workspace, w)
        XCTAssertTrue(restored.dirty)
        let path = root.appendingPathComponent("workspace-test.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    @Test func testLegacyImportIsReadOnlyAndDoesNotCopyBotSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try WorkspaceFiles(directory: root)
        var w = Workspace(); w.notes = [Note(title: "Keep me")]
        let original: [String: Any] = ["WORKSPACE#local": try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)), "SECRET#bot": "do-not-import"]
        let data = try JSONSerialization.data(withJSONObject: original)
        let legacy = root.appendingPathComponent("legacy.json"); try data.write(to: legacy)
        let imported = try XCTUnwrap(files.importLegacy(legacy))
        XCTAssertEqual(imported.notes, w.notes)
        XCTAssertEqual(try Data(contentsOf: legacy), data)
        XCTAssertFalse(String(data: try JSONEncoder().encode(imported), encoding: .utf8)!.contains("do-not-import"))
    }
    @Test func testExtractionDoesNotTurnOrdinaryProseIntoTasks() {
        XCTAssertEqual(extractActions("A paragraph\n- [ ] Book the meeting\n- [x] Already done\nTODO: Send notes\n* [ ] Review\nAn ordinary sentence"), ["Book the meeting", "Send notes", "Review"])
    }
    @Test func testValidationRejectsEmptyPrioritiesAndInvalidDates() throws {
        var w = Workspace(); w.settings.digestPriorities = []
        XCTAssertThrowsError(try w.validated())
        w.settings.digestPriorities = [.urgent]
        w.tasks = [WorkTask(title: "Valid")]; w.tasks[0].remindAt = "not a date"
        XCTAssertThrowsError(try w.validated())
    }
}
