import Foundation

public struct AISource: Identifiable, Equatable {
    public var id: String
    public var noteID: String
    public var sectionID: String
    public var title: String
    public var text: String
}
public enum AIRetrieval {
    /// Local passage ranking; paid providers see only a small, displayed shortlist.
    public static func sources(notes: [Note], query: String, limit: Int = 6) -> [AISource] {
        let stops = Set(["what", "did", "the", "we", "about", "a", "an", "is", "of", "and", "to", "in", "for", "how", "do", "my", "are", "was", "were", "with", "our"])
        let terms = Set(NoteSearchPreview.terms(query.lowercased())).subtracting(stops)
        var ranked: [(AISource, Int, Int)] = []
        var order = 0
        for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            for section in note.contentSections {
                let title = [note.displayTitle, section.title].filter { !$0.isEmpty }.joined(separator: " › ")
                let chars = Array(section.body)
                for offset in stride(from: 0, to: chars.count, by: 700) {
                    let text = String(chars[offset..<min(chars.count, offset + 950)])
                    let titleLower = title.lowercased(), lower = text.lowercased()
                    let score = terms.reduce(0) { $0 + (titleLower.contains($1) ? 3 : 0) + (lower.contains($1) ? 5 : 0) }
                    ranked.append((AISource(id: "", noteID: note.id, sectionID: section.id, title: title, text: text), score, order)); order += 1
                }
            }
        }
        return ranked.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.prefix(max(0, limit)).enumerated().map { index, item in
            var source = item.0; source.id = "S\(index + 1)"; return source
        }
    }
    public static func prompt(question: String, sources: [AISource]) throws -> String {
        struct Passage: Encodable { var id: String; var title: String; var text: String }
        struct Query: Encodable { var question: String; var passages: [Passage] }
        let data = try JSONEncoder().encode(Query(question: question, passages: sources.map { Passage(id: $0.id, title: $0.title, text: $0.text) }))
        return String(decoding: data, as: UTF8.self)
    }
}
