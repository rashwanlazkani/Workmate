import Foundation
import Testing
@testable import WorkmateCore

struct DriveCloudTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKMATE_DRIVE_TEST_FILE"] != nil)) func privateConnectionRoundTrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WORKMATE_DRIVE_TEST_FILE"])
        let config = try JSONDecoder().decode(DriveConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = DriveAPI(configuration: config)
        var workspace = try await api.load()
        #expect(workspace.notes.isEmpty)
        workspace.notes = [Note(title: "iCloud backup check", body: "Unicode: möte 你好")]
        workspace.notes[0].richText = NoteFormatting.encode(NoteFormatting.decode(body: workspace.notes[0].body, richText: nil))
        workspace.notes[0].setSections(workspace.notes[0].contentSections + [NoteSection(title: "Decisions", body: "Keep the section in the backup")])
        workspace.tasks = [WorkTask(title: "Mac only", reminder: Date().addingTimeInterval(3600))]
        workspace.tasks[0].tags = ["PO-Sync", "release"]
        var meeting = Meeting(title: "Different weekday times", start: Date(), end: Date().addingTimeInterval(3600))
        meeting.timezone = "Europe/Stockholm"; meeting.reminderEnabled = false
        meeting.scheduleWeekly(with: [.init(weekday: 2, startTime: "09:00", endTime: "10:00"), .init(weekday: 4, startTime: "13:00", endTime: "14:30")])
        workspace.meetings = [meeting]
        var sections = workspace.notes[0].contentSections
        sections[1].meetingIds = [meeting.id]
        workspace.notes[0].setSections(sections)
        let saved = try await api.save(workspace)
        #expect(saved.revision == workspace.revision + 1)
        #expect(try await api.load().notes == workspace.notes)
        #expect(try await api.load().tasks[0].notifiesTelegram == false)
        #expect(try await api.load().tasks[0].tags == ["po-sync", "release"])
        #expect(try await api.load().meetings[0].weeklySchedule == meeting.weeklySchedule)
        do { _ = try await api.save(workspace); Issue.record("Stale version was accepted") }
        catch WorkmateError.conflict { }
        let status = try await api.telegramStatus()
        #expect(!status.connected && !status.configured)
        var bad = config; bad.serviceToken = (config.serviceToken ?? "") + "invalid"
        await api.configure(bad)
        do { _ = try await api.load(); Issue.record("Invalid token was accepted") }
        catch { }
    }
}
