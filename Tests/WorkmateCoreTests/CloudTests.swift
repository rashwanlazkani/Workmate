import Foundation
import Testing
@testable import WorkmateCore

struct CloudTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKMATE_CLOUD_TEST_FILE"] != nil)) func testNativeClientAgainstAWS() async throws {
        guard let path = ProcessInfo.processInfo.environment["WORKMATE_CLOUD_TEST_FILE"] else { return }
        struct Fixture: Decodable { let region: String; let clientId: String; let apiUrl: String; let email: String; let password: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = CloudAPI(config: .init(region: fixture.region, clientId: fixture.clientId, apiUrl: fixture.apiUrl), restoreSession: false)
        switch try await api.signIn(email: fixture.email, password: fixture.password) {
        case .session(let session): XCTAssertEqual(session.email, fixture.email)
        case .challenge: XCTFail("Unexpected challenge"); return
        }
        var initial = try await api.load()
        XCTAssertTrue(initial.notes.isEmpty)
        initial.notes = [Note(title: "SwiftUI native check", body: "Unicode notes: möte 你好\n- [ ] Follow up")]
        let meeting = Meeting(title: "PO-sync integration test", start: Date().addingTimeInterval(7200), end: Date().addingTimeInterval(12600))
        initial.meetings = [meeting]
        initial.notes[0].meetingIds = [meeting.id]
        initial.tasks = [WorkTask(title: "Swift native priority", priority: .urgent, reminder: Date().addingTimeInterval(3600))]
        initial.tasks[0].meetingId = meeting.id
        initial.tasks[0].notifiesTelegram = true
        initial.settings.digestPriorities = [.high, .urgent]
        let saved = try await api.save(initial)
        XCTAssertEqual(saved.revision, initial.revision + 1)
        let loaded = try await api.load()
        XCTAssertEqual(loaded.notes, saved.notes)
        XCTAssertEqual(loaded.tasks.first?.priority, .urgent)
        XCTAssertEqual(loaded.settings.digestPriorities, [.high, .urgent])
        XCTAssertEqual(loaded.tasks.first?.remindAt, saved.tasks.first?.remindAt)
        XCTAssertEqual(loaded.meetings, initial.meetings)
        XCTAssertEqual(loaded.notes.first?.meetingIds, [meeting.id])
        XCTAssertEqual(loaded.tasks.first?.meetingId, meeting.id)
        XCTAssertEqual(loaded.tasks.first?.telegramReminder, true)
        do { _ = try await api.save(initial); XCTFail("A stale save was accepted") }
        catch WorkmateError.conflict { }
        var macOnly = loaded
        macOnly.tasks[0].notifiesTelegram = false
        let macOnlySaved = try await api.save(macOnly)
        let macOnlyLoaded = try await api.load()
        XCTAssertEqual(macOnlyLoaded.tasks.first?.telegramReminder, false)
        XCTAssertEqual(macOnlyLoaded.tasks.first?.remindAt, loaded.tasks.first?.remindAt)
        let telegram = try await api.telegramStatus()
        XCTAssertFalse(telegram.connected)
        XCTAssertFalse(telegram.configured)
        var empty = Workspace(); empty.revision = macOnlySaved.revision
        _ = try await api.save(empty)
        await api.signOut()
        do { _ = try await api.load(); XCTFail("Signed-out request should fail") }
        catch WorkmateError.unauthorized { }
    }
}
