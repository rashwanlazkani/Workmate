import AppKit
import Testing
@testable import WorkmateCore

@MainActor struct NoteMarkdownTests {
    @Test func nativeMarkdownRenderingAndRTFRoundTrip() throws {
        let source = "# Agenda\n\n**Bold** and *italic* with ~~old~~ and `code`.\n\n- One\n- [ ] Open\n- [x] Done\n\n3. Third\n4. Fourth\n\n> Quote\n\n[Site](https://example.com)"
        let section = try NoteMarkdown.section(source)
        let text = NoteFormatting.decode(body: section.body, richText: section.richText)
        #expect(text.string.contains("• One\n☐ Open\n☑ Done"))
        #expect(text.string.contains("3. Third\n4. Fourth"))
        #expect(!text.string.contains("**"))
        let ns = text.string as NSString
        let bold = try #require(text.attribute(.font, at: ns.range(of: "Bold").location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let italic = try #require(text.attribute(.font, at: ns.range(of: "italic").location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        #expect(text.attribute(.link, at: ns.range(of: "Site").location, effectiveRange: nil) != nil)
        #expect(NoteMarkdown.source(for: section) == source)
    }
    @Test func sourceSurvivesStorageSearchAndSectionChanges() throws {
        let source = "## Release 👋\n\n- [ ] Prepare **PdM** summary\n\n![Chart](https://example.com/image.png)\n\n| A | B |\n| - | - |\n| 1 | 2 |"
        let section = try NoteMarkdown.section(source)
        var note = Note(title: "Meetings"); note.setSections([section])
        var workspace = Workspace(); workspace.notes = [note]
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace)).validated()
        #expect(NoteMarkdown.source(for: restored.notes[0].contentSections[0]) == source)
        #expect(restored.search("PdM").notes.count == 1)
        #expect(section.body.contains("A  |  B"))
        #expect(section.body.contains("Image: Chart"))
        let split = NoteFormatting.splitSection(section, at: 8)
        #expect(split.0.markdownSource == nil)
        #expect(split.1.markdownSource == nil)
        #expect(NoteMarkdown.export(note).contains(source))
    }
    @Test func noExecutableLinksAndSizeLimits() throws {
        let text = try NoteMarkdown.render("[Bad](javascript:alert) [File](file:///tmp/demo) <script>alert(1)</script>")
        var links = 0
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in if value != nil { links += 1 } }
        #expect(links == 0)
        #expect(text.string.contains("<script>"))
        #expect(throws: NoteMarkdown.Failure.self) { try NoteMarkdown.render(String(repeating: "x", count: 60001)) }
        let nested = try NoteMarkdown.render("- Parent\n    - Child\n    - [ ] Task\n\n```swift\nlet value = 1\n```")
        #expect(nested.string.contains("    • Child\n    ☐ Task"))
        #expect(nested.string.contains("let value = 1"))
    }
    @Test func nativeEditsRegenerateUsableMarkdown() throws {
        let rendered = try NoteMarkdown.render("# Heading\n\n**Bold** and *italic*\n\n- [x] Done\n- Open\n\n[Example](https://example.com)\n\n> Quote")
        let rtf = try #require(NoteFormatting.encode(rendered))
        let restored = NoteFormatting.decode(body: rendered.string, richText: rtf)
        let generated = NoteMarkdown.serialize(restored)
        #expect(generated.contains("# Heading"))
        #expect(generated.contains("**Bold**"))
        #expect(generated.contains("*italic*"))
        #expect(generated.contains("- [x] Done"))
        #expect(generated.contains("> Quote"))
        #expect(try NoteMarkdown.render(generated).string == rendered.string)
    }
    @Test func exportingLiteralPunctuationDoesNotCreateMarkdownStructure() throws {
        let plain = NSAttributedString(string: "- Literal\n+ Literal\n---\n![not an image](example)\n👋 **plain**", attributes: NoteFormatting.attributes)
        #expect(try NoteMarkdown.render(NoteMarkdown.serialize(plain)).string == plain.string)
        let code = try NoteMarkdown.render("Use `let count = 3` here.")
        #expect(try NoteMarkdown.render(NoteMarkdown.serialize(code)).string == code.string)
    }

}
