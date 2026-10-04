import AppKit
import Testing
@testable import WorkmateCore

@MainActor struct NoteSectionTests {
    @Test func existingNotesSplitWithoutLosingFormattingAndRoundTrip() throws {
        var note = Note(title: "Meetings", body: "PO-sync\n• Release 🚀\nDesign review\n☐ Prepare mocks")
        let rich = NSMutableAttributedString(string: note.body, attributes: NoteFormatting.attributes)
        let bold = (note.body as NSString).range(of: "Design review")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: bold)
        note.richText = NoteFormatting.encode(rich)
        let original = note.contentSections[0]
        var (first, second) = NoteFormatting.splitSection(original, at: bold.location)
        second.title = "Design"
        #expect(first.body + second.body == original.body)
        #expect(first.id == note.id)
        let secondText = NoteFormatting.decode(body: second.body, richText: second.richText)
        #expect(NSFontManager.shared.traits(of: secondText.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.boldFontMask))
        note.setSections([first, second])
        var workspace = Workspace(); workspace.notes = [note]
        _ = try workspace.validated()
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored.notes == workspace.notes)
        #expect(restored.search("Prepare mocks").notes.count == 1)
        #expect(restored.search("Design").notes.count == 1)
        let merged = NoteFormatting.mergeSections(first, second)
        #expect(merged.body.contains("Design\nDesign review"))
        #expect(merged.body.contains("☐ Prepare mocks"))
        first = NoteFormatting.splitSection(original, at: 0).0
        #expect(first.body.isEmpty)
        #expect(NoteFormatting.splitSection(original, at: rich.length).1.body.isEmpty)
    }
    @Test func sectionMeetingTagsAreIndependentAndSearchable() throws {
        let firstMeeting = Meeting(title: "PO-sync", start: Date(), end: Date().addingTimeInterval(3600))
        let secondMeeting = Meeting(title: "Design review", start: Date(), end: Date().addingTimeInterval(3600))
        var note = Note(title: "Meetings", body: "Original")
        note.meetingIds = [firstMeeting.id]
        // Existing sectioned notes migrate the old note tag to the first section only.
        note.sections = [NoteSection(title: "Meetings", body: "Original"), NoteSection(title: "Design", body: "Mocks")]
        var sections = note.contentSections
        #expect(sections[0].meetingIds == [firstMeeting.id])
        #expect((sections[1].meetingIds ?? []).isEmpty)
        sections[1].meetingIds = [secondMeeting.id]
        note.setSections(sections)
        #expect(note.sections(for: firstMeeting.id).map(\.body) == ["Original"])
        #expect(note.sections(for: secondMeeting.id).map(\.body) == ["Mocks"])
        var workspace = Workspace(); workspace.notes = [note]; workspace.meetings = [firstMeeting, secondMeeting]
        #expect(workspace.search("Design review").notes.map(\.id) == [note.id])
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(decoded.contentSections == sections)
        let split = NoteFormatting.splitSection(sections[1], at: 2)
        #expect(split.0.meetingIds == [secondMeeting.id]); #expect(split.1.meetingIds == [secondMeeting.id])
        let merged = NoteFormatting.mergeSections(sections[0], sections[1])
        #expect(Set(merged.meetingIds ?? []) == Set([firstMeeting.id, secondMeeting.id]))
        sections[1].meetingIds = []; note.setSections(sections)
        #expect(note.meetingIds == [firstMeeting.id])
        #expect(note.sections(for: secondMeeting.id).isEmpty)
    }
    @Test func columnNameIsIndependentOfSectionHeadings() {
        var note = Note(title: "SoS", body: "Agenda")
        var sections = note.contentSections
        sections.append(NoteSection(title: "PO-sync", body: "Release"))
        note.setSections(sections)
        note.title = "Meetings"
        sections[1].body = "Updated release"
        note.setSections(sections)
        #expect(note.title == "Meetings")
        #expect(note.contentSections.map(\.title) == ["SoS", "PO-sync"])
        #expect(note.body.contains("SoS"))
        var workspace = Workspace(); workspace.notes = [note]
        #expect(workspace.search("SoS").notes.count == 1)
    }
    @Test func deletingASectionKeepsColumnAndOtherSections() {
        var note = Note(title: "Meetings")
        let first = NoteSection(title: "SoS", body: "Keep this", meetingIds: [UUID().uuidString.lowercased()])
        let second = NoteSection(title: "PO-sync", body: "Remove this", meetingIds: [UUID().uuidString.lowercased()])
        note.setSections([first, second]); note.removeSection(second.id)
        #expect(note.title == "Meetings")
        #expect(note.contentSections == [first])
        #expect(note.meetingIds == first.meetingIds)
        #expect(!note.body.contains("Remove this"))
        note.removeSection(first.id)
        #expect(note.title == "Meetings")
        #expect(note.contentSections.count == 1)
        #expect(note.body.isEmpty)
        #expect(note.meetingIds == [])
    }
    @Test func legacyNotesAndDuplicateSectionValidation() throws {
        let note = Note(title: "Legacy", body: "Keep this")
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(decoded.sections == nil)
        #expect(decoded.contentSections[0].body == "Keep this")
        var invalid = note
        invalid.setSections([decoded.contentSections[0], decoded.contentSections[0]])
        #expect(!invalid.validSections)
    }
}
