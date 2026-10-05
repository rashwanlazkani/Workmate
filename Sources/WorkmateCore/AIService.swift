import Foundation
import Darwin

public enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case apple, openAI, anthropic
    public var id: String { rawValue }
    public var title: String { switch self { case .apple: "Apple Intelligence"; case .openAI: "OpenAI"; case .anthropic: "Anthropic" } }
    public var model: String { switch self { case .apple: "On this Mac"; case .openAI: "gpt-4.1-mini-2025-04-14"; case .anthropic: "claude-haiku-4-5-20251001" } }
    public var rates: (input: Double, output: Double) { switch self { case .apple: (0,0); case .openAI: (0.4,1.6); case .anthropic: (1,5) } }
}
public struct AIError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Conservative preflight reservations, retained even on network failures; no unbilled retries.
/// One locked ledger for both providers and all Workmate processes on this Mac.
public final class AIBudget {
    public static let defaultLimit = 5.0
    public struct Ledger: Codable { public var months: [String: Double] = [:]; public var maximum: Double?; public init() {} }
    let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func month(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }
    public static func reservation(provider: AIProvider, instructions: String, input: String, outputTokens: Int = 1200) -> Double {
        // UTF-8 bytes upper-bound ordinary BPE text tokens; add message overhead and 100% pricing headroom.
        let inputBound = instructions.utf8.count + input.utf8.count + 2048
        return 2 * (Double(inputBound) * provider.rates.input + Double(outputTokens) * provider.rates.output) / 1_000_000
    }
    public func reserved(date: Date = Date()) throws -> Double { try locked { ledger in ledger.months[Self.month(date), default: 0] } }
    public func monthlyLimit() throws -> Double { try locked { $0.maximum ?? Self.defaultLimit } }
    public static func parseLimit(_ input: String) throws -> Double {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard text.range(of: #"^\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite, value <= 1_000_000 else {
            throw AIError("Enter a USD amount from 0 to 1,000,000, with up to two decimal places.")
        }
        return value
    }
    public func setMonthlyLimit(_ value: Double) throws {
        guard value.isFinite, value >= 0, value <= 1_000_000,
              abs(value * 100 - (value * 100).rounded()) < 0.000001 else { throw AIError("Enter a valid monthly maximum in USD, with up to two decimal places.") }
        try locked { $0.maximum = value }
    }
    public func reserve(_ cost: Double, date: Date = Date()) throws {
        guard cost.isFinite, cost > 0 else { throw AIError("Invalid AI cost estimate.") }
        try locked { ledger in
            let month = Self.month(date), current = ledger.months[month, default: 0]
            guard current + cost <= (ledger.maximum ?? Self.defaultLimit) else { throw AIError("This request would exceed your monthly AI maximum. Choose Apple Intelligence, wait until next month (UTC), or change the maximum in Settings → AI.") }
            ledger.months[month] = current + cost
        }
    }
    private func locked<T>(_ operation: (inout Ledger) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("budget.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw AIError("Cannot secure the AI budget. No request was sent.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AIError("Cannot lock the AI budget. No request was sent.") }
        defer { flock(fd, LOCK_UN) }
        let url = directory.appendingPathComponent("budget.json")
        var ledger = Ledger()
        if FileManager.default.fileExists(atPath: url.path) {
            // Fail closed for damaged or unreadable state, rather than resetting spending.
            ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
            guard ledger.months.values.allSatisfy({ $0.isFinite && $0 >= 0 }), (ledger.maximum ?? Self.defaultLimit).isFinite, (ledger.maximum ?? Self.defaultLimit) >= 0, (ledger.maximum ?? Self.defaultLimit) <= 1_000_000 else { throw AIError("The AI budget file is invalid. No request was sent.") }
        }
        let result = try operation(&ledger)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result
    }
}

public enum AIWire {
    public static let outputLimit = 1200
    public static func request(provider: AIProvider, key: String, instructions: String, input: String) throws -> URLRequest {
        guard provider != .apple, !key.isEmpty else { throw AIError("Add your API key in Settings → AI.") }
        guard input.utf8.count <= 24000, instructions.utf8.count <= 4000 else { throw AIError("Select a shorter passage (up to about 6,000 characters) and try again.") }
        let url = provider == .openAI ? "https://api.openai.com/v1/responses" : "https://api.anthropic.com/v1/messages"
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if provider == .openAI {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            body = ["model": provider.model, "instructions": instructions, "input": input, "max_output_tokens": outputLimit, "store": false]
        } else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": provider.model, "system": instructions, "messages": [["role": "user", "content": input]], "max_tokens": outputLimit]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public static func response(provider: AIProvider, data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else {
            switch status {
            case 401, 403: throw AIError("The API key was rejected or does not have access to this model. Check Settings → AI.")
            case 429: throw AIError("The provider reports a rate or billing limit. Check your API account, then try again yourself.")
            default: throw AIError("The AI provider could not complete this request (HTTP \(status)). No automatic retry was made.")
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError("Invalid AI response.") }
        let chunks: [[String: Any]]
        if provider == .openAI {
            guard json["status"] as? String == "completed" else { throw AIError("The response was incomplete. Try a shorter passage; your text has not changed.") }
            chunks = (json["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        } else {
            guard json["stop_reason"] as? String == "end_turn" else { throw AIError("The response was incomplete. Try a shorter passage; your text has not changed.") }
            chunks = json["content"] as? [[String: Any]] ?? []
        }
        let result = chunks.filter { ["text", "output_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.utf8.count <= 32000 else { throw AIError("The AI returned no usable text. Your note has not changed.") }
        return result
    }
}
