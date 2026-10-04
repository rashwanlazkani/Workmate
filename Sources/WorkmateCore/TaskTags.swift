import Foundation

public enum TaskTags {
    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
