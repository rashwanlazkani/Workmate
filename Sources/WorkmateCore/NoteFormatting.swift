import AppKit

public enum NoteFormatting {
    public enum ListKind: Equatable { case bullet, numbered, checklist }
    public static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }
    public static func decode(body: String, richText: String?) -> NSAttributedString {
        if let richText, let data = Data(base64Encoded: richText), data.count <= 600000,
           let value = NSAttributedString(rtf: data, documentAttributes: nil), value.string == body {
            return value
        }
        return NSAttributedString(string: body, attributes: attributes)
    }
    public static func encode(_ text: NSAttributedString) -> String? {
        text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])?.base64EncodedString()
    }
    public static func safeLink(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = value.contains(":") ? value : "https://" + value
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme),
              (scheme == "mailto" ? url.absoluteString.count > 7 : !(url.host ?? "").isEmpty) else { return nil }
        return url
    }
    public static func listPrefix(_ line: String) -> String {
        let regex = try! NSRegularExpression(pattern: "^(?:[•☐☑] |[0-9]+\\. )")
        let text = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return "" }
        return text.substring(with: match.range)
    }
    // A selection ending at the next line's start must not include that line.
    public static func selectedParagraphs(_ text: String, selection: NSRange) -> [NSRange] {
        let ns = text as NSString
        let start = min(selection.location, ns.length)
        let length = min(selection.length, ns.length - start)
        if start == ns.length, ns.length == 0 || text.hasSuffix("\n") || text.hasSuffix("\r") {
            return [NSRange(location: ns.length, length: 0)]
        }
        let last = length == 0 ? start : start + length - 1
        var offset = ns.paragraphRange(for: NSRange(location: start, length: 0)).location
        var ranges: [NSRange] = []
        repeat {
            let range = ns.paragraphRange(for: NSRange(location: offset, length: 0))
            ranges.append(range)
            if NSMaxRange(range) > last || NSMaxRange(range) >= ns.length || range.length == 0 { break }
            offset = NSMaxRange(range)
        } while offset <= ns.length
        return ranges
    }
    public struct SelectionStyle: Equatable {
        public init() {}
        public var bold = false
        public var italic = false
        public var linked = false
        public var list: ListKind?
    }
    public static func selectionStyle(_ text: NSAttributedString, selection: NSRange, typingAttributes: [NSAttributedString.Key: Any]) -> SelectionStyle {
        var style = SelectionStyle()
        func hasTrait(_ attributes: [NSAttributedString.Key: Any], _ trait: NSFontTraitMask) -> Bool {
            NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)).contains(trait)
        }
        let start = min(selection.location, text.length), count = min(selection.length, text.length - start)
        if count == 0 {
            style.bold = hasTrait(typingAttributes, .boldFontMask)
            style.italic = hasTrait(typingAttributes, .italicFontMask)
            style.linked = typingAttributes[.link] != nil
        } else {
            style.bold = true; style.italic = true; style.linked = true
            text.enumerateAttributes(in: NSRange(location: start, length: count)) { attributes, _, _ in
                style.bold = style.bold && hasTrait(attributes, .boldFontMask)
                style.italic = style.italic && hasTrait(attributes, .italicFontMask)
                style.linked = style.linked && attributes[.link] != nil
            }
        }
        let ns = text.string as NSString
        let kinds: [ListKind?] = selectedParagraphs(text.string, selection: selection).map { range in
            let prefix = listPrefix(ns.substring(with: range))
            if prefix == "• " { return .bullet }
            if prefix == "☐ " || prefix == "☑ " { return .checklist }
            if prefix.first?.isNumber == true { return .numbered }
            return nil
        }
        if let first = kinds.first, kinds.allSatisfy({ $0 == first }) { style.list = first }
        return style
    }
    public static func list(_ text: NSAttributedString, selection: NSRange, kind: ListKind) -> (NSAttributedString, NSRange) {
        let ns = text.string as NSString
        let ranges = selectedParagraphs(text.string, selection: selection)
        let result = NSMutableAttributedString(attributedString: text)
        let removing = ranges.allSatisfy { range in
            let prefix = listPrefix(ns.substring(with: range))
            switch kind {
            case .bullet: return prefix == "• "
            case .numbered: return prefix.first?.isNumber == true
            case .checklist: return prefix == "☐ " || prefix == "☑ "
            }
        }
        var start = min(selection.location, ns.length)
        var end = min(NSMaxRange(selection), ns.length)
        for (index, range) in ranges.enumerated().reversed() {
            let oldLength = (listPrefix(ns.substring(with: range)) as NSString).length
            let prefix = removing ? "" : kind == .bullet ? "• " : kind == .checklist ? "☐ " : "\(index + 1). "
            let newLength = (prefix as NSString).length
            var prefixAttributes = attributes
            if range.location + oldLength < text.length {
                prefixAttributes = text.attributes(at: range.location + oldLength, effectiveRange: nil)
                prefixAttributes.removeValue(forKey: .link)
            }
            result.replaceCharacters(in: NSRange(location: range.location, length: oldLength), with: NSAttributedString(string: prefix, attributes: prefixAttributes))
            func moved(_ position: Int) -> Int {
                if position < range.location { return position }
                if position <= range.location + oldLength { return range.location + newLength }
                return position + newLength - oldLength
            }
            start = moved(start); end = moved(end)
        }
        return (result, NSRange(location: start, length: max(0, end - start)))
    }
}
