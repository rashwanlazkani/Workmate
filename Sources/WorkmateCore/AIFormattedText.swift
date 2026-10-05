import AppKit
import Foundation

public enum AIFormattedText {
    /// A small native renderer for the formatting vocabulary requested from the model.
    /// No HTML, attachments, scripts, or remote content is interpreted.
    public static func render(_ input: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, rawLine) in input.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: NoteFormatting.attributes)) }
            var line = rawLine
            var attributes = NoteFormatting.attributes
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
                line = String(line.drop(while: { $0 == "#" || $0 == " " }))
                attributes[.font] = NSFont.boldSystemFont(ofSize: 20)
            } else if line.hasPrefix("- [ ] ") { line = "☐ " + line.dropFirst(6) }
            else if line.hasPrefix("- [x] ") { line = "☑ " + line.dropFirst(6) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            let formatted = NSMutableAttributedString(string: line, attributes: attributes)
            for (pattern, trait) in [(#"\*\*([^*\n]+)\*\*"#, NSFontTraitMask.boldFontMask), (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, NSFontTraitMask.italicFontMask)] {
                let regex = try! NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: formatted.string, range: NSRange(location: 0, length: formatted.length)).reversed() {
                    let inner = formatted.attributedSubstring(from: match.range(at: 1))
                    let replacement = NSMutableAttributedString(attributedString: inner)
                    replacement.enumerateAttribute(.font, in: NSRange(location: 0, length: replacement.length)) { value, range, _ in
                        let font = value as? NSFont ?? .systemFont(ofSize: 17)
                        replacement.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: range)
                    }
                    formatted.replaceCharacters(in: match.range, with: replacement)
                }
            }
            result.append(formatted)
        }
        return NoteFormatting.readable(result)
    }
}

public enum AIEditValidation {
    public static func validate(original: String, result: String) throws {
        func numbers(_ value: String) -> Set<String> {
            let stripped = value.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)
            let regex = try! NSRegularExpression(pattern: #"\d+(?:[.,:/-]\d+)*"#)
            let ns = stripped as NSString
            return Set(regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        }
        guard numbers(result).isSubset(of: numbers(original)) else {
            throw AIError("AI introduced numbers or dates that were not in the selection. The result was discarded; your text is unchanged.")
        }
        let before = original.split(whereSeparator: \.isWhitespace).count
        let after = result.split(whereSeparator: \.isWhitespace).count
        guard before >= 8 || after <= before + 8 else {
            throw AIError("AI expanded this short selection beyond a simple edit. The result was discarded. Try selecting a complete sentence.")
        }
    }
}
