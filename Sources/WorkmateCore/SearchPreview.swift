import Foundation

public struct NoteSearchPreview {
    public var section: String?
    public var text: String
    public var highlights: [NSRange]

    public static func terms(_ query: String) -> [String] {
        query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    public static func ranges(in text: String, query: String) -> [NSRange] {
        let ns = text as NSString
        var result: [NSRange] = []
        for term in terms(query) {
            var start = 0
            while start < ns.length {
                let range = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: ns.length - start))
                if range.location == NSNotFound { break }
                result.append(range); start = NSMaxRange(range)
            }
        }
        return result
    }
    public init(note: Note, query: String, meetings: [Meeting] = []) {
        let sections = note.contentSections
        let matched = sections.first { !Self.ranges(in: $0.body, query: query).isEmpty }
            ?? sections.first { !Self.ranges(in: $0.title, query: query).isEmpty }
        var source = matched?.body ?? note.body
        section = matched.flatMap { $0.title.isEmpty ? nil : $0.title }
        if let matched, Self.ranges(in: source, query: query).isEmpty { source = matched.title + " — " + source }
        if matched == nil, Self.ranges(in: note.title, query: query).isEmpty,
           let linked = meetings.first(where: { (note.meetingIds ?? []).contains($0.id) && !Self.ranges(in: $0.title, query: query).isEmpty }) {
            source = "Meeting: " + linked.title
            section = sections.first { ($0.meetingIds ?? []).contains(linked.id) }?.title
        }
        let clean = source.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let firstMatch = Self.ranges(in: clean, query: query).first.flatMap { Range($0, in: clean) }
        let anchor = firstMatch?.lowerBound ?? clean.startIndex
        let start = clean.index(anchor, offsetBy: -45, limitedBy: clean.startIndex) ?? clean.startIndex
        let end = clean.index(firstMatch?.upperBound ?? start, offsetBy: 110, limitedBy: clean.endIndex) ?? clean.endIndex
        text = (start > clean.startIndex ? "…" : "") + clean[start..<end] + (end < clean.endIndex ? "…" : "")
        highlights = Self.ranges(in: text, query: query)
    }
}
