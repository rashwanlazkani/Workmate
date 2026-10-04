import Foundation
import Testing
@testable import WorkmateCore

struct ReminderChannelTests {
    @Test func newRemindersDefaultToMacAndPreserveExplicitTelegramChoice() throws {
        let date = try #require(Dates.parse("2026-11-04T12:00:00Z"))
        var task = WorkTask(title: "Prepare agenda", reminder: date)
        #expect(!task.notifiesTelegram)
        task.notifiesTelegram = true
        var restored = try JSONDecoder().decode(WorkTask.self, from: JSONEncoder().encode(task))
        #expect(restored.notifiesTelegram)
        #expect(restored.reminder == date)
        restored.notifiesTelegram = false
        restored = try JSONDecoder().decode(WorkTask.self, from: JSONEncoder().encode(restored))
        #expect(!restored.notifiesTelegram)
        #expect(restored.reminder == date) // Disabling Telegram must keep the Mac reminder.
    }

    @Test func olderScheduledRemindersKeepTelegramButNewDatesDoNotOptIn() throws {
        let date = try #require(Dates.parse("2026-11-04T12:00:00Z"))
        func legacy(_ task: WorkTask) throws -> WorkTask {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
            object.removeValue(forKey: "telegramReminder")
            return try JSONDecoder().decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var scheduled = try legacy(WorkTask(title: "Existing reminder", reminder: date))
        #expect(scheduled.notifiesTelegram)
        scheduled.reminder = date.addingTimeInterval(3600)
        #expect(scheduled.notifiesTelegram)
        scheduled.notifiesTelegram = false
        scheduled.reminder = date.addingTimeInterval(7200)
        #expect(!scheduled.notifiesTelegram)
        var unscheduled = try legacy(WorkTask(title: "Existing action"))
        #expect(!unscheduled.notifiesTelegram)
        unscheduled.reminder = date
        #expect(!unscheduled.notifiesTelegram)
    }
}
