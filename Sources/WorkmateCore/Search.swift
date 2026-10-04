import Foundation
public struct SearchMatches {
    public var meetings: [Meeting]
    public var notes: [Note]
    public var tasks: [WorkTask]
    public var count: Int { meetings.count + notes.count + tasks.count }
}
public extension Workspace {
    func search(_ query: String, includeArchived: Bool = false, suggestedMeetingLinks: [String: [String]] = [:]) -> SearchMatches {
        func normalize(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let terms = normalize(query).split(separator: " ").map(String.init)
        func matches(_ text: String) -> Bool { let text = normalize(text); return !terms.isEmpty && terms.allSatisfy { text.contains($0) } }
        let matchingMeetings = meetings.filter { matches($0.title + " " + $0.location + " " + $0.calendarName) }
        let meetingIds = Set(matchingMeetings.map(\.id))
        let matchingNotes = notes.filter { note in
            matches(note.title + " " + note.body) || !meetingIds.isDisjoint(with: note.meetingIds ?? []) || !meetingIds.isDisjoint(with: suggestedMeetingLinks[note.id] ?? [])
        }
        let noteIds = Set(matchingNotes.map(\.id))
        let matchingTasks = tasks.enumerated().filter { _, task in
            (includeArchived || !task.isArchived) &&
                (matches(([task.title] + task.tagNames).joined(separator: " ")) || noteIds.contains(task.noteId) || (task.meetingId.map { meetingIds.contains($0) } ?? false))
        }.sorted {
            if $0.element.isArchived != $1.element.isArchived { return !$0.element.isArchived }
            return $0.element.priority.rank == $1.element.priority.rank ? $0.offset < $1.offset : $0.element.priority.rank > $1.element.priority.rank
        }.map(\.element)
        return .init(meetings: matchingMeetings, notes: matchingNotes, tasks: matchingTasks)
    }
}
