import Foundation
import Testing
@testable import WorkmateCore

struct MeetingTests {
    @Test func weekdayAndTimeSelectionBuildsNextWeeklyMeeting() throws {
        let start = try #require(Dates.parse("2026-10-04T11:00:00Z"))
        let end = try #require(Dates.parse("2026-10-04T12:30:00Z"))
        var meeting = Meeting(title: "PO-sync", start: start, end: end)
        meeting.timezone = "Europe/Stockholm"
        meeting.scheduleWeekly(on: 4, startTime: start, endTime: end, after: start)
        #expect(meeting.recurrence == "weekly")
        #expect(meeting.startAt == "2026-10-07T11:00:00Z")
        #expect(meeting.endAt == "2026-10-07T12:30:00Z")
        // Editing an active meeting keeps today's occurrence; an ended one rolls forward.
        meeting.scheduleWeekly(on: 4, startTime: start, endTime: end, after: try #require(Dates.parse("2026-10-07T12:00:00Z")))
        #expect(meeting.startAt == "2026-10-07T11:00:00Z")
        meeting.scheduleWeekly(on: 4, startTime: start, endTime: end, after: try #require(Dates.parse("2026-10-07T13:00:00Z")))
        #expect(meeting.startAt == "2026-10-14T11:00:00Z")
    }
    @Test func weeklyTimeSelectionPreservesWallClockAcrossDSTAndMidnight() throws {
        let start = try #require(Dates.parse("2026-10-21T21:00:00Z"))
        let end = try #require(Dates.parse("2026-10-22T00:30:00Z"))
        var meeting = Meeting(title: "Late sync", start: start, end: end)
        meeting.timezone = "Europe/Stockholm"
        meeting.scheduleWeekly(on: 4, startTime: start, endTime: end, after: try #require(Dates.parse("2026-10-26T12:00:00Z")))
        #expect(meeting.startAt == "2026-10-28T22:00:00Z")
        #expect(meeting.endAt == "2026-10-29T01:30:00Z")
        #expect(meeting.end > meeting.start)
        meeting.scheduleWeekly(on: 4, startTime: start, endTime: end, after: try #require(Dates.parse("2026-10-29T00:30:00Z")))
        #expect(meeting.startAt == "2026-10-28T22:00:00Z")
    }
    @Test func weeklyMeetingKeepsLocalTimeAcrossDST() throws {
        var meeting = Meeting(title: "PO-sync", start: try #require(Dates.parse("2026-10-21T11:00:00Z")), end: try #require(Dates.parse("2026-10-21T12:30:00Z")))
        meeting.recurrence = "weekly"; meeting.timezone = "Europe/Stockholm"
        let instances = meeting.occurrences(after: try #require(Dates.parse("2026-10-20T00:00:00Z")), days: 16)
        #expect(instances.count == 3)
        #expect(Dates.iso(instances[0].start) == "2026-10-21T11:00:00Z")
        #expect(Dates.iso(instances[1].start) == "2026-10-28T12:00:00Z")
        #expect(instances[1].end.timeIntervalSince(instances[1].start) == 5400)
        #expect(instances[1].start.timeIntervalSince(instances[1].reminderDate) == 600)
    }
    @Test func activeMeetingAndCanceledMeeting() throws {
        let start = try #require(Dates.parse("2026-10-07T11:00:00Z"))
        var meeting = Meeting(title: "PO-sync", start: start, end: start.addingTimeInterval(5400))
        let during = start.addingTimeInterval(1200)
        let occurrence = try #require(meeting.occurrences(after: during).first)
        #expect(occurrence.isCurrent(at: during))
        #expect(meeting.occurrences(after: start.addingTimeInterval(5400)).isEmpty)
        meeting.canceled = true
        #expect(meeting.occurrences(after: start.addingTimeInterval(-3600)).isEmpty)
    }
    @Test func multipleDaysKeepIndependentTimesAcrossDSTAndRoundTrip() throws {
        let now = try #require(Dates.parse("2026-10-19T00:00:00Z"))
        var meeting = Meeting(title: "Team sync", start: now, end: now.addingTimeInterval(3600))
        meeting.timezone = "Europe/Stockholm"
        meeting.scheduleWeekly(with: [
            .init(weekday: 2, startTime: "09:00", endTime: "10:00"),
            .init(weekday: 4, startTime: "13:00", endTime: "14:30"),
            .init(weekday: 6, startTime: "23:30", endTime: "00:30")
        ], after: now)
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        #expect(restored == meeting)
        let occurrences = restored.occurrences(after: now, days: 14)
        #expect(occurrences.map { Dates.iso($0.start) } == ["2026-10-19T07:00:00Z", "2026-10-21T11:00:00Z", "2026-10-23T21:30:00Z", "2026-10-26T08:00:00Z", "2026-10-28T12:00:00Z", "2026-10-30T22:30:00Z"])
        #expect(Dates.iso(occurrences[2].end) == "2026-10-23T22:30:00Z")
        var rules = restored.daySchedules
        rules[0].startTime = "08:30"
        meeting.scheduleWeekly(with: rules, after: now)
        #expect(meeting.daySchedules.first { $0.weekday == 4 }?.startTime == "13:00")
    }
    @Test func legacyWeeklyAndInvalidDaySchedules() throws {
        let now = try #require(Dates.parse("2026-10-19T07:00:00Z"))
        var meeting = Meeting(title: "Legacy", start: now, end: now.addingTimeInterval(3600))
        meeting.timezone = "Europe/Stockholm"; meeting.recurrence = "weekly"
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        #expect(decoded.recurringWeekdays == [2])
        #expect(decoded.daySchedules == [.init(weekday: 2, startTime: "09:00", endTime: "10:00")])
        var workspace = Workspace(); workspace.meetings = [meeting]
        workspace.meetings[0].weeklySchedule = [.init(weekday: 2, startTime: "25:00", endTime: "10:00")]
        #expect(throws: (any Error).self) { try workspace.validated() }
    }
    @Test func searchFindsMetadataAndAllRelatedActions() {
        var w = Workspace()
        let meeting = Meeting(title: "PO-sync", start: Date(), end: Date().addingTimeInterval(5400))
        w.meetings = [meeting]
        var linked = Note(title: "Launch decisions", body: "The team agreed to simplify the flow.")
        linked.meetingIds = [meeting.id]
        let mentioned = Note(title: "Wednesday", body: "PO sync: send the revised plan.")
        let suggested = Note(title: "Priorities", body: "Prepare the next product discussion.")
        let unrelated = Note(title: "Personal", body: "Get groceries.")
        w.notes = [linked, mentioned, suggested, unrelated]
        var direct = WorkTask(title: "Prepare agenda"); direct.meetingId = meeting.id
        w.tasks = [WorkTask(title: "Send follow-up", noteId: linked.id), WorkTask(title: "Get milk"), direct]
        let results = w.search("PO-SYNC", suggestedMeetingLinks: [suggested.id: [meeting.id]])
        #expect(results.meetings.map(\.id) == [meeting.id])
        #expect(Set(results.notes.map(\.id)) == Set([linked.id, mentioned.id, suggested.id]))
        #expect(Set(results.tasks.map(\.title)) == Set(["Send follow-up", "Prepare agenda"]))
        #expect(w.search("unrelated phrase").count == 0)
    }
    @Test func meetingsAndLinksSurviveBackupRoundTrip() throws {
        var w = Workspace()
        let meeting = Meeting(title: "PO-sync", start: Date(), end: Date().addingTimeInterval(5400))
        var note = Note(title: "Agenda"); note.meetingIds = [meeting.id]
        var task = WorkTask(title: "Prepare", priority: .urgent); task.meetingId = meeting.id
        w.meetings = [meeting]; w.notes = [note]; w.tasks = [task]
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        #expect(restored == w)
        _ = try restored.validated()
    }
}
