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
