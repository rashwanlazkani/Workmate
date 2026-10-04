import Foundation
import Testing
@testable import WorkmateCore

struct SearchPreviewTests {
    @Test func previewCentersOnMatchInsideSection() {
        var note = Note(title: "Meetings")
        note.setSections([NoteSection(title: "General", body: "Unrelated introduction"), NoteSection(title: "Weekly sync", body: String(repeating: "Earlier notes. ", count: 30) + "Meet PdM to discuss the release plan.")])
        let preview = NoteSearchPreview(note: note, query: "pdm")
        #expect(preview.section == "Weekly sync")
        #expect(preview.text.contains("Meet PdM to discuss"))
        #expect(preview.text.hasPrefix("…"))
        #expect(preview.highlights.map { (preview.text as NSString).substring(with: $0) } == ["PdM"])
    }
    @Test func unicodeAndHeadingMatchesRemainReadable() {
        var note = Note(title: "Meetings")
        note.setSections([NoteSection(title: "PdM decisions", body: "Discuss café ☕️ tomorrow")])
        let heading = NoteSearchPreview(note: note, query: "pdm")
        #expect(heading.text.contains("PdM decisions")); #expect(!heading.highlights.isEmpty)
        let accented = NoteSearchPreview(note: note, query: "cafe")
        #expect(accented.highlights.map { (accented.text as NSString).substring(with: $0) } == ["café"])
    }
    @Test func metadataMatchExplainsMeetingLink() {
        let meeting = Meeting(title: "PO-sync", start: Date(), end: Date().addingTimeInterval(3600))
        var note = Note(title: "Work")
        note.setSections([NoteSection(title: "Agenda", body: "Prepare release", meetingIds: [meeting.id])])
        let preview = NoteSearchPreview(note: note, query: "sync", meetings: [meeting])
        #expect(preview.text == "Meeting: PO-sync")
        #expect(preview.section == "Agenda")
    }
}
