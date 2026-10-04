import Foundation

public enum Priority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high, urgent
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw == "normal" ? "medium" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown priority"))
        }
        self = value
    }
}

public enum Dates {
    public static func iso(_ date: Date = Date()) -> String { ISO8601DateFormatter().string(from: date) }
    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    public static func day(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public static func tomorrowMorning(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
    public static func nextMonday(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
    }
}

public struct WorkTask: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var title: String
    public var project = ""
    public var status = "todo"
    public var priority: Priority = .medium
    public var focus = false
    // Retained only for lossless import/export of old workspaces. No due-date feature.
    public var due = ""
    public var remindAt = ""
    // Missing in older workspaces, where scheduled reminders also used Telegram.
    public var telegramReminder: Bool? = false
    public var notifiesTelegram: Bool {
        get { telegramReminder ?? !remindAt.isEmpty }
        set { telegramReminder = newValue }
    }
    public var noteId = ""
    public var meetingId: String?
    public var tags: [String]? = nil {
        didSet { if let tags { self.tags = TaskTags.unique(tags) } }
    }
    public var tagNames: [String] { TaskTags.unique(tags ?? []) }
    public var createdAt = Dates.iso()
    public var completedAt: String?
    public var isArchived: Bool { status == "done" }
    public mutating func setCompleted(_ completed: Bool, at date: Date = Date()) {
        status = completed ? "done" : "todo"
        completedAt = completed ? Dates.iso(date) : nil
    }
    public var reminder: Date? {
        get { Dates.parse(remindAt) }
        set {
            // Freeze legacy behavior before changing the date of an older task.
            if telegramReminder == nil { telegramReminder = !remindAt.isEmpty }
            remindAt = newValue.map(Dates.iso) ?? ""
        }
    }
    public init(title: String, priority: Priority = .medium, reminder: Date? = nil, noteId: String = "") {
        self.title = title; self.priority = priority; self.noteId = noteId
        self.reminder = reminder
    }
}

public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var title = ""
    public var body = ""
    public var richText: String?
    public var project = ""
    public var updatedAt = Dates.iso()
    public var pinned = false
    public var meetingIds: [String]? = []
    public init(title: String = "", body: String = "") { self.title = title; self.body = body }
    public var displayTitle: String { title.isEmpty ? String(body.split(separator: "\n").first ?? "Untitled note").prefixString(60) : title }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var name = ""
    public var timezone = "Europe/Stockholm"
    public var digestEnabled = false
    public var digestTime = "08:30"
    public var browserNotifications = false
    public var digestPriorities = Priority.allCases
    public init() {}
    enum CodingKeys: String, CodingKey { case name, timezone, digestEnabled, digestTime, browserNotifications, digestPriorities }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "Europe/Stockholm"
        digestEnabled = try c.decodeIfPresent(Bool.self, forKey: .digestEnabled) ?? false
        digestTime = try c.decodeIfPresent(String.self, forKey: .digestTime) ?? "08:30"
        browserNotifications = try c.decodeIfPresent(Bool.self, forKey: .browserNotifications) ?? false
        digestPriorities = try c.decodeIfPresent([Priority].self, forKey: .digestPriorities) ?? Priority.allCases
        if digestPriorities.isEmpty { digestPriorities = Priority.allCases }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct Workspace: Codable, Equatable, Sendable {
    public var tasks: [WorkTask] = []
    public var notes: [Note] = []
    public var nodes: [JSONValue] = []
    public var strokes: [JSONValue] = []
    public var settings = Preferences()
    public var sample = false
    public var revision = 0
    public var meetings: [Meeting] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case tasks, notes, nodes, strokes, settings, sample, revision, meetings }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([WorkTask].self, forKey: .tasks)
        for index in tasks.indices {
            if let tags = tasks[index].tags { tasks[index].tags = TaskTags.unique(tags) }
        }
        notes = try c.decode([Note].self, forKey: .notes)
        nodes = try c.decodeIfPresent([JSONValue].self, forKey: .nodes) ?? []
        strokes = try c.decodeIfPresent([JSONValue].self, forKey: .strokes) ?? []
        settings = try c.decode(Preferences.self, forKey: .settings)
        sample = try c.decodeIfPresent(Bool.self, forKey: .sample) ?? false
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        meetings = try c.decodeIfPresent([Meeting].self, forKey: .meetings) ?? []
    }
    public var openTasks: [WorkTask] {
        tasks.enumerated().filter { !$0.element.isArchived }.sorted {
            $0.element.priority.rank == $1.element.priority.rank ? $0.offset < $1.offset : $0.element.priority.rank > $1.element.priority.rank
        }.map(\.element)
    }
    public var archivedTasks: [WorkTask] {
        let archived: [(task: WorkTask, date: Date, offset: Int)] = tasks.enumerated().filter { $0.element.isArchived }.map {
            (task: $0.element, date: Dates.parse($0.element.completedAt ?? $0.element.createdAt) ?? .distantPast, offset: $0.offset)
        }
        return archived.sorted {
            $0.date == $1.date ? $0.offset < $1.offset : $0.date > $1.date
        }.map { $0.task }
    }
    public var briefTasks: [WorkTask] { openTasks.filter { settings.digestPriorities.contains($0.priority) } }
    public var brief: String {
        let tasks = briefTasks
        let lines = tasks.prefix(16).map { "• [\($0.priority.title)] \($0.title.prefix(160))" }
        return (["Your daily brief", "Priorities: " + Priority.allCases.reversed().filter { settings.digestPriorities.contains($0) }.map(\.title).joined(separator: ", "), "", "\(tasks.count) open \(tasks.count == 1 ? "action" : "actions")"] + lines + (tasks.isEmpty ? ["Nothing on your list. A little room to breathe."] : [])).joined(separator: "\n")
    }
    public func validated() throws -> Workspace {
        guard tasks.count <= 1000, notes.count <= 300, meetings.count <= 500,
              Set(tasks.map(\.id)).count == tasks.count, Set(notes.map(\.id)).count == notes.count,
              tasks.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.title.isEmpty && $0.title.count <= 500 && ($0.tags?.count ?? 0) <= 20 && ($0.tags ?? []).allSatisfy { $0.count <= 200 } && ($0.remindAt.isEmpty || $0.reminder != nil) }),
              notes.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.title.count <= 200 && $0.body.count <= 60000 && ($0.richText?.count ?? 0) <= 800000 }),
              meetings.allSatisfy({ ($0.weeklySchedule == nil || (!$0.weeklySchedule!.isEmpty && $0.weeklySchedule!.allSatisfy(\.isValid) && Set($0.weeklySchedule!.map(\.weekday)).count == $0.weeklySchedule!.count)) && ($0.weekdays == nil || (!$0.weekdays!.isEmpty && $0.weekdays!.allSatisfy { (1...7).contains($0) } && Set($0.weekdays!).count == $0.weekdays!.count)) && UUID(uuidString: $0.id) != nil && !$0.title.isEmpty && $0.title.count <= 200 && Dates.parse($0.startAt) != nil && Dates.parse($0.endAt) != nil && $0.end > $0.start && (0...120).contains($0.reminderMinutes) && TimeZone(identifier: $0.timezone) != nil }),
              TimeZone(identifier: settings.timezone) != nil,
              settings.digestTime.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil,
              !settings.digestPriorities.isEmpty,
              try JSONEncoder().encode(self).count <= 4_000_000 else { throw WorkmateError.message("This backup contains invalid or oversized data.") }
        return self
    }
}
public func extractActions(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).compactMap { line in
        let pattern = #"^\s*(?:[-*]\s*\[\s\]\s*|☐\s*|(?:TODO|ACTION):\s*)(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range]).trimmingCharacters(in: .whitespaces)
    }
}
public enum WorkmateError: LocalizedError {
    case message(String), unauthorized, conflict
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .unauthorized: return "Sign in again to resume sync. Your edits are saved on this Mac."
        case .conflict: return "This workspace changed on another device. Your edits are safe on this Mac. Export a backup, then reload the cloud copy."
        }
    }
}
private extension String { func prefixString(_ count: Int) -> String { String(prefix(count)) } }
