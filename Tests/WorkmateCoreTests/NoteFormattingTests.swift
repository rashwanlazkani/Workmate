import AppKit
import Testing
@testable import WorkmateCore

@MainActor struct NoteFormattingTests {
    @Test func formattingRoundTripsWithoutChangingSearchableText() throws {
        let text = NSMutableAttributedString(string: "PO-sync agenda\n☐ Review release\nVisit site", attributes: NoteFormatting.attributes)
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 7))
        let linkRange = (text.string as NSString).range(of: "Visit site")
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: linkRange)
        let encoded = try #require(NoteFormatting.encode(text))
        var note = Note(title: "Agenda", body: text.string); note.richText = encoded
        var workspace = Workspace(); workspace.notes = [note]
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        let rich = NoteFormatting.decode(body: restored.notes[0].body, richText: restored.notes[0].richText)
        #expect(rich.string == text.string)
        #expect(NSFontManager.shared.traits(of: try #require(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)).contains(.boldFontMask))
        #expect(String(describing: rich.attribute(.link, at: linkRange.location, effectiveRange: nil)!) == "https://example.com")
        #expect(restored.search("release").notes.count == 1)
        #expect(NoteFormatting.decode(body: "New plain text", richText: encoded).string == "New plain text")
    }
    @Test func listsPreserveUnicodeAndExistingInlineFormatting() {
        let text = NSMutableAttributedString(string: "👋 Agenda\nRelease", attributes: NoteFormatting.attributes)
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: text.length))
        let (numbered, selection) = NoteFormatting.list(text, selection: NSRange(location: 0, length: text.length), kind: .numbered)
        #expect(numbered.string == "1. 👋 Agenda\n2. Release")
        let (checks, selected) = NoteFormatting.list(numbered, selection: selection, kind: .checklist)
        #expect(checks.string == "☐ 👋 Agenda\n☐ Release")
        let (plain, _) = NoteFormatting.list(checks, selection: selected, kind: .checklist)
        #expect(plain.string == text.string)
        #expect(NSFontManager.shared.traits(of: plain.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.boldFontMask))
        let (empty, cursor) = NoteFormatting.list(NSAttributedString(string: ""), selection: NSRange(location: 0, length: 0), kind: .bullet)
        #expect(empty.string == "• "); #expect(cursor.location == 2)
    }
    @Test func changingFourthLinePreservesEarlierListsAndSelection() {
        let text = NSAttributedString(string: "• One\n• Two\n• Three\n• Four\n• Five", attributes: NoteFormatting.attributes)
        let fourth = (text.string as NSString).range(of: "Four")
        let (numbered, selection) = NoteFormatting.list(text, selection: fourth, kind: .numbered)
        #expect(numbered.string == "• One\n• Two\n• Three\n1. Four\n• Five")
        #expect((numbered.string as NSString).substring(with: selection) == "Four")
        let (checklist, cursor) = NoteFormatting.list(numbered, selection: NSRange(location: selection.location + selection.length, length: 0), kind: .checklist)
        #expect(checklist.string == "• One\n• Two\n• Three\n☐ Four\n• Five")
        #expect(cursor.length == 0)
        #expect(cursor.location == (checklist.string as NSString).range(of: "Four").upperBound)
        let firstThree = NSRange(location: 0, length: (text.string as NSString).range(of: "• Four").location)
        let (changed, _) = NoteFormatting.list(text, selection: firstThree, kind: .numbered)
        #expect(changed.string == "1. One\n2. Two\n3. Three\n• Four\n• Five")
        let trailing = NSAttributedString(string: "• One\n", attributes: NoteFormatting.attributes)
        let (last, _) = NoteFormatting.list(trailing, selection: NSRange(location: trailing.length, length: 0), kind: .numbered)
        #expect(last.string == "• One\n1. ")
    }
    @Test func selectionStyleTracksInlineAndMixedLists() {
        let text = NSMutableAttributedString(string: "• Bold\n1. Number\n☐ Check", attributes: NoteFormatting.attributes)
        let bold = (text.string as NSString).range(of: "Bold")
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: bold)
        let selected = NoteFormatting.selectionStyle(text, selection: bold, typingAttributes: [:])
        #expect(selected.bold); #expect(!selected.italic); #expect(selected.list == .bullet)
        let numbered = NoteFormatting.selectionStyle(text, selection: (text.string as NSString).range(of: "Number"), typingAttributes: [:])
        #expect(!numbered.bold); #expect(numbered.list == .numbered)
        let mixed = NoteFormatting.selectionStyle(text, selection: NSRange(location: 0, length: text.length), typingAttributes: [:])
        #expect(!mixed.bold); #expect(mixed.list == nil)
        let caret = NoteFormatting.selectionStyle(text, selection: NSRange(location: text.length, length: 0), typingAttributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        #expect(caret.bold); #expect(caret.list == .checklist)
    }
    @Test func existingNotesUseLargerTextAndListMarkers() throws {
        let text = NSMutableAttributedString(string: "• Bullet\n1. Number\n☐ Check", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let readable = NoteFormatting.readable(text)
        #expect(readable.string == text.string)
        #expect((readable.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 21)
        #expect((readable.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize == 17)
        #expect(NSFontManager.shared.traits(of: try #require(readable.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)).contains(.boldFontMask))
    }
    @Test func linksAcceptWebAndMailAndRejectExecutableSchemes() {
        #expect(NoteFormatting.safeLink("example.com")?.absoluteString == "https://example.com")
        #expect(NoteFormatting.safeLink("mailto:hello@example.com") != nil)
        #expect(NoteFormatting.safeLink("javascript:alert(1)") == nil)
        #expect(NoteFormatting.safeLink("file:///etc/passwd") == nil)
        #expect(NoteFormatting.safeLink("") == nil)
    }
}
