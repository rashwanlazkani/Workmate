import Foundation

public struct MeetingDaySchedule: Codable, Equatable, Identifiable, Sendable {
    public var weekday: Int
    public var startTime: String
    public var endTime: String
    public var id: Int { weekday }
    public init(weekday: Int, startTime: String, endTime: String) {
        self.weekday = weekday; self.startTime = startTime; self.endTime = endTime
    }
    public var isValid: Bool {
        (1...7).contains(weekday) && [startTime, endTime].allSatisfy { $0.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil }
    }
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var title: String
    public var startAt: String
    public var endAt: String
    public var timezone = TimeZone.current.identifier
    public var recurrence = "none"
    /// Calendar weekday numbers: Sunday = 1 through Saturday = 7. Missing preserves older weekly meetings.
    public var weekdays: [Int]? = nil
    public var weeklySchedule: [MeetingDaySchedule]? = nil
    public var reminderMinutes = 10
    public var reminderEnabled = true
    public var calendarEventId = ""
    public var calendarId = ""
    public var calendarName = ""
    public var location = ""
    public var canceled = false
    public init(title: String, start: Date, end: Date) {
        self.title = title; self.startAt = Dates.iso(start); self.endAt = Dates.iso(end)
    }
    public var start: Date { Dates.parse(startAt) ?? .distantPast }
    public var end: Date { Dates.parse(endAt) ?? .distantPast }
    public var isImported: Bool { !calendarEventId.isEmpty }
    /// Anchor a weekly schedule to its next (or currently running) occurrence.
    /// Start/end are wall-clock times in the meeting's timezone, including DST.
    public mutating func scheduleWeekly(on weekday: Int, startTime: Date, endTime: Date, after now: Date = Date()) {
        guard (1...7).contains(weekday) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let startClock = calendar.dateComponents([.hour, .minute], from: startTime)
        let endClock = calendar.dateComponents([.hour, .minute], from: endTime)
        let match = DateComponents(hour: startClock.hour, minute: startClock.minute, second: 0, weekday: weekday)
        guard var nextStart = calendar.nextDate(after: calendar.startOfDay(for: now).addingTimeInterval(-1), matching: match, matchingPolicy: .nextTime),
              var nextEnd = calendar.date(bySettingHour: endClock.hour ?? 0, minute: endClock.minute ?? 0, second: 0, of: nextStart) else { return }
        if nextEnd <= nextStart { nextEnd = calendar.date(byAdding: .day, value: 1, to: nextEnd)! }
        let previousStart = calendar.date(byAdding: .weekOfYear, value: -1, to: nextStart)!
        let previousEnd = calendar.date(byAdding: .weekOfYear, value: -1, to: nextEnd)!
        if previousStart <= now && previousEnd > now {
            nextStart = previousStart; nextEnd = previousEnd
        }
        if nextEnd <= now {
            nextStart = calendar.date(byAdding: .weekOfYear, value: 1, to: nextStart)!
            nextEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: nextEnd)!
        }
        recurrence = "weekly"; weekdays = [weekday]; weeklySchedule = nil
        startAt = Dates.iso(nextStart); endAt = Dates.iso(nextEnd)
    }
    public var recurringWeekdays: Set<Int> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        if let weeklySchedule { return Set(weeklySchedule.map(\.weekday)) }
        return Set(weekdays?.filter { (1...7).contains($0) } ?? [calendar.component(.weekday, from: start)])
    }
    public var daySchedules: [MeetingDaySchedule] {
        if let weeklySchedule { return weeklySchedule }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        func clock(_ date: Date) -> String { String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date)) }
        return recurringWeekdays.sorted().map { .init(weekday: $0, startTime: clock(start), endTime: clock(end)) }
    }
    public mutating func scheduleWeekly(on days: Set<Int>, startTime: Date, endTime: Date, after now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        func clock(_ date: Date) -> String { String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date)) }
        scheduleWeekly(with: days.sorted().map { .init(weekday: $0, startTime: clock(startTime), endTime: clock(endTime)) }, after: now)
    }
    public mutating func scheduleWeekly(with schedules: [MeetingDaySchedule], after now: Date = Date()) {
        guard !schedules.isEmpty, schedules.allSatisfy(\.isValid), Set(schedules.map(\.weekday)).count == schedules.count else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        func date(_ time: String) -> Date {
            let pieces = time.split(separator: ":").compactMap { Int($0) }
            return calendar.date(bySettingHour: pieces[0], minute: pieces[1], second: 0, of: now)!
        }
        let choices = schedules.map { schedule -> Meeting in
            var candidate = self
            candidate.scheduleWeekly(on: schedule.weekday, startTime: date(schedule.startTime), endTime: date(schedule.endTime), after: now)
            return candidate
        }
        if let first = choices.min(by: { $0.start < $1.start }) {
            startAt = first.startAt; endAt = first.endAt; recurrence = "weekly"
            weekdays = schedules.map(\.weekday).sorted(); weeklySchedule = schedules.sorted { $0.weekday < $1.weekday }
        }
    }
    public func occurrences(after now: Date = Date(), days: Int = 30) -> [MeetingOccurrence] {
        guard !canceled, end > start else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let horizon = calendar.date(byAdding: .day, value: days, to: now)!
        if recurrence != "weekly" {
            return end > now && start < horizon ? [.init(meeting: self, start: start, end: end)] : []
        }
        let schedules = Dictionary(daySchedules.map { ($0.weekday, $0) }, uniquingKeysWith: { first, _ in first })
        let firstDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        return (0...(days + 1)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay), let rule = schedules[calendar.component(.weekday, from: day)] else { return nil }
            let from = rule.startTime.split(separator: ":").compactMap { Int($0) }
            let to = rule.endTime.split(separator: ":").compactMap { Int($0) }
            guard from.count == 2, to.count == 2,
                  let s = calendar.date(bySettingHour: from[0], minute: from[1], second: 0, of: day),
                  var e = calendar.date(bySettingHour: to[0], minute: to[1], second: 0, of: day) else { return nil }
            if e <= s { e = calendar.date(byAdding: .day, value: 1, to: e)! }
            guard s >= start, e > now, s < horizon else { return nil }
            return .init(meeting: self, start: s, end: e)
        }

    }
}
public struct MeetingOccurrence: Identifiable, Equatable, Sendable {
    public var meeting: Meeting
    public var start: Date
    public var end: Date
    public var id: String { meeting.id + "-" + String(Int(start.timeIntervalSince1970)) }
    public func isCurrent(at now: Date = Date()) -> Bool { start <= now && end > now }
    public var reminderDate: Date { start.addingTimeInterval(-Double(meeting.reminderMinutes * 60)) }
}
public struct NoteInsight: Codable, Equatable, Sendable {
    public var noteId: String
    public var sourceStamp: String
    public var summary: String
    public var actions: [String]
    public var meetingIds: [String]
    public init(noteId: String, sourceStamp: String, summary: String, actions: [String], meetingIds: [String]) {
        self.noteId = noteId; self.sourceStamp = sourceStamp; self.summary = summary; self.actions = actions; self.meetingIds = meetingIds
    }
}
