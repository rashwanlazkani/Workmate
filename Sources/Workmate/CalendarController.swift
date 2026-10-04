import EventKit
import Foundation
import WorkmateCore

@MainActor final class CalendarController: ObservableObject {
    @Published var calendars: [EKCalendar] = []
    @Published var selected: Set<String> = []
    @Published var authorized = false
    @Published var error: String?
    private let events = EKEventStore()
    private var observer: NSObjectProtocol?
    var changed: (() -> Void)?
    init() {
        selected = Set(UserDefaults.standard.stringArray(forKey: "selected-calendars") ?? [])
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if authorized { calendars = events.calendars(for: .event) }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.changed?() }
        }
    }
    func connect() async {
        do {
            authorized = try await events.requestFullAccessToEvents()
            if authorized { refresh() }
            else { error = "Allow Calendar access for Workmate in System Settings → Privacy & Security → Calendars." }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        calendars = authorized ? events.calendars(for: .event).sorted { $0.title < $1.title } : []
    }
    func toggle(_ calendar: EKCalendar) {
        if selected.contains(calendar.calendarIdentifier) { selected.remove(calendar.calendarIdentifier) }
        else { selected.insert(calendar.calendarIdentifier) }
        UserDefaults.standard.set(Array(selected), forKey: "selected-calendars")
        changed?()
    }
    func readMeetings(existing: [Meeting], now: Date = Date()) -> [Meeting]? {
        guard authorized else { return nil }
        let sources = calendars.filter { selected.contains($0.calendarIdentifier) }
        guard !sources.isEmpty else { return existing.map { m in var m = m; if m.isImported { m.canceled = true }; return m } }
        let from = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let to = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let matches = events.events(matching: events.predicateForEvents(withStart: from, end: to, calendars: sources))
            .filter { !$0.isAllDay && $0.status != .canceled && $0.endDate > now && !($0.title ?? "").isEmpty }
            .sorted { $0.startDate < $1.startDate }
        var seen = Set<String>()
        var result = existing
        for event in matches {
            let sourceID = event.calendar.calendarIdentifier + ":" + event.calendarItemIdentifier
            guard seen.insert(sourceID).inserted else { continue }
            let index = result.firstIndex { $0.calendarEventId == sourceID }
            var meeting = index.map { result[$0] } ?? Meeting(title: event.title, start: event.startDate, end: event.endDate)
            meeting.title = String(event.title.prefix(200))
            meeting.startAt = Dates.iso(event.startDate); meeting.endAt = Dates.iso(event.endDate)
            meeting.timezone = event.timeZone?.identifier ?? TimeZone.current.identifier
            meeting.calendarEventId = sourceID; meeting.calendarId = event.calendar.calendarIdentifier
            meeting.calendarName = String(event.calendar.title.prefix(200))
            meeting.location = String((event.location ?? "").prefix(1000)); meeting.canceled = false
            if let index { result[index] = meeting } else if result.count < 500 { result.append(meeting) }
        }
        for i in result.indices where result[i].isImported {
            if !selected.contains(result[i].calendarId) || (!seen.contains(result[i].calendarEventId) && result[i].end > now) { result[i].canceled = true }
        }
        return result
    }
}
