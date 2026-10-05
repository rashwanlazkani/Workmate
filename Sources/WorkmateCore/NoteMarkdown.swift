import AppKit
import Markdown

/// Markdown stays native: parse a syntax tree, then render editable AppKit text.
public enum NoteMarkdown {
    public enum Failure: LocalizedError {
        case tooLarge
        public var errorDescription: String? { "Markdown must fit within 60,000 characters per note." }
    }
    public static func render(_ source: String) throws -> NSAttributedString {
        guard source.count <= 60000 else { throw Failure.tooLarge }
        let renderer = Renderer()
        renderer.blocks(Document(parsing: source).children, depth: 0)
        guard renderer.text.string.count <= 60000 else { throw Failure.tooLarge }
        return NoteFormatting.readable(renderer.text)
    }
    public static func section(_ source: String, title: String = "") throws -> NoteSection {
        let text = try render(source)
        let rich = NoteFormatting.encode(text)
        guard (rich?.count ?? 0) <= 800000 else { throw Failure.tooLarge }
        return NoteSection(title: title, body: text.string, richText: rich, markdownSource: source)
    }
    public static func source(for section: NoteSection) -> String {
        section.markdownSource ?? serialize(NoteFormatting.decode(body: section.body, richText: section.richText))
    }
    public static func export(_ note: Note) -> String {
        var parts = [String]()
        if !note.title.isEmpty { parts.append("# " + escape(note.title)) }
        for section in note.contentSections {
            if note.contentSections.count > 1, !section.title.isEmpty { parts.append("## " + escape(section.title)) }
            parts.append(source(for: section))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
    private static func escape(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]<>#~|!+-.=".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
    /// Regenerate Markdown after native rich-text editing. Original source is kept until then.
    public static func serialize(_ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var lines = [String](), offset = 0
        while offset < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: offset, length: 0))
            var range = paragraph
            while range.length > 0, CharacterSet.newlines.contains(UnicodeScalar(ns.character(at: NSMaxRange(range) - 1)) ?? " ") { range.length -= 1 }
            let line = ns.substring(with: range)
            let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
            let trimmed = String(line.dropFirst(indentation.count))
            let marker = NoteFormatting.listPrefix(trimmed)
            var prefix = ""
            if !marker.isEmpty {
                range.location += (indentation + marker as NSString).length
                range.length -= (indentation + marker as NSString).length
                prefix = indentation + (marker == "• " ? "- " : marker == "☐ " ? "- [ ] " : marker == "☑ " ? "- [x] " : marker)
            }
            let attrs = range.length > 0 ? text.attributes(at: range.location, effectiveRange: nil) : [:]
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 17)
            if marker.isEmpty, font.pointSize > 21 {
                prefix = String(repeating: "#", count: font.pointSize >= 30 ? 1 : font.pointSize >= 26 ? 2 : 3) + " "
            }
            if (attrs[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0 > 0 { prefix = "> " + prefix }
            var content = ""
            text.enumerateAttributes(in: range) { attrs, part, _ in
                let raw = ns.substring(with: part)
                let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 17)
                let traits = NSFontManager.shared.traits(of: font)
                var value = escape(raw)
                // Keep whitespace outside emphasis delimiters, as required by CommonMark.
                let leading = String(raw.prefix { $0.isWhitespace }), trailing = String(raw.reversed().prefix { $0.isWhitespace }.reversed())
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { content += raw; return }
                let center = String(raw.dropFirst(leading.count).dropLast(trailing.count))
                value = escape(center)
                if font.isFixedPitch {
                    let fence = String(repeating: "`", count: max(1, (center.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
                    value = fence + " " + center + " " + fence
                } else {
                    if traits.contains(.italicFontMask) { value = "*" + value + "*" }
                    if traits.contains(.boldFontMask), prefix.trimmingCharacters(in: .whitespaces).first != "#" { value = "**" + value + "**" }
                    if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { value = "~~" + value + "~~" }
                }
                if let link = attrs[.link], let url = NoteFormatting.safeLink(String(describing: link)) {
                    value = "[" + value + "](<" + url.absoluteString.replacingOccurrences(of: ">", with: "%3E") + ">)"
                }
                content += leading + value + trailing
            }
            lines.append(prefix + content)
            offset = NSMaxRange(paragraph)
        }
        return lines.joined(separator: "\n")
    }

    private final class Renderer {
        let text = NSMutableAttributedString(string: "")
        var attributes = NoteFormatting.attributes
        func append(_ value: String) { text.append(NSAttributedString(string: value, attributes: attributes)) }
        func blocks(_ nodes: MarkupChildren, depth: Int) {
            for (index, node) in nodes.enumerated() {
                if index > 0 { append("\n\n") }
                block(node, depth: depth)
            }
        }
        func block(_ node: Markup, depth: Int) {
            guard depth < 64 else { append(node.format()); return }
            let previous = attributes
            defer { attributes = previous }
            switch node {
            case let heading as Heading:
                attributes[.font] = NSFont.boldSystemFont(ofSize: heading.level == 1 ? 30 : heading.level == 2 ? 26 : 23)
                inline(heading, depth: depth + 1)
            case let code as CodeBlock:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
                attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.06)
                append(code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
            case let quote as BlockQuote:
                let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.headIndent += 18; style.firstLineHeadIndent += 18
                attributes[.paragraphStyle] = style
                blocks(quote.children, depth: depth + 1)
            case let list as OrderedList: listItems(list.children, orderedStart: Int(list.startIndex), depth: depth)
            case let list as UnorderedList: listItems(list.children, orderedStart: nil, depth: depth)
            case is ThematicBreak: append("────────────")
            case let html as HTMLBlock: append(html.rawHTML)
            case let table as Table:
                // Tables remain readable native text; exact table syntax remains in markdownSource.
                for (i, row) in ([table.head as Markup] + Array(table.body.children)).enumerated() {
                    if i > 0 { append("\n") }
                    for (j, cell) in row.children.enumerated() {
                        if j > 0 { append("  |  ") }
                        inline(cell, depth: depth + 1)
                    }
                }
            default: inline(node, depth: depth + 1)
            }
        }
        func listItems(_ items: MarkupChildren, orderedStart: Int?, depth: Int) {
            for (index, node) in items.enumerated() {
                if index > 0 { append("\n") }
                guard let item = node as? ListItem else { continue }
                let prefix: String
                if let check = item.checkbox { prefix = check == .checked ? "☑ " : "☐ " }
                else { prefix = orderedStart.map { "\($0 + index). " } ?? "• " }
                append(prefix)
                for (childIndex, child) in item.children.enumerated() {
                    if childIndex > 0 { append("\n") }
                    let start = text.length
                    block(child, depth: depth + 1)
                    if child is UnorderedList || child is OrderedList {
                        let content = text.attributedSubstring(from: NSRange(location: start, length: text.length - start))
                        let indented = NSMutableAttributedString(attributedString: content)
                        let ns = content.string as NSString
                        var positions = [0], p = 0
                        while p < ns.length {
                            p = NSMaxRange(ns.paragraphRange(for: NSRange(location: p, length: 0)))
                            if p < ns.length { positions.append(p) }
                        }
                        for p in positions.reversed() { indented.insert(NSAttributedString(string: "    ", attributes: attributes), at: p) }
                        text.replaceCharacters(in: NSRange(location: start, length: text.length - start), with: indented)
                    }
                }
            }
        }
        func inline(_ node: Markup, depth: Int) {
            guard depth < 64 else { append(node.format()); return }
            let previous = attributes
            defer { attributes = previous }
            switch node {
            case let value as Markdown.Text: append(value.string); return
            case is SoftBreak: append("\n"); return
            case is LineBreak: append("\n"); return
            case let value as InlineCode:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
                attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.06)
                append(value.code); return
            case is Strong, is Emphasis:
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: node is Strong ? .boldFontMask : .italicFontMask)
            case is Strikethrough: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case let link as Link:
                if let destination = link.destination, destination.contains(":"), let url = NoteFormatting.safeLink(destination) { attributes[.link] = url }
            case let image as Markdown.Image:
                append("Image: "); for child in image.children { inline(child, depth: depth + 1) }
                if let source = image.source { append(" (" + source + ")") }; return
            case let html as InlineHTML: append(html.rawHTML); return
            default: break
            }
            for child in node.children { inline(child, depth: depth + 1) }
        }
    }
}
