import AppKit
import SwiftUI
import Security
import FoundationModels
import WorkmateCore

private enum AIKeys {
    static var service: String { (Bundle.main.bundleIdentifier ?? "se.workmate.mac") + ".ai-keys" }
    static func query(_ provider: AIProvider) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue] }
    static func read(_ provider: AIProvider) -> String? {
        var q = query(provider); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, provider: AIProvider) throws {
        let q = query(provider)
        if key.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError("Could not remove the API key from Keychain.") }; return
        }
        let values = [kSecValueData as String: Data(key.utf8)] as [String: Any]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var new = q; new.merge(values) { _, value in value }
            new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw AIError("Could not save the API key to Keychain.") }
        } else if status != errSecSuccess { throw AIError("Could not update the API key in Keychain.") }
    }
}
private final class AINetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class AIController: ObservableObject {
    static let shared = AIController()
    @Published var provider: AIProvider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "ai-provider"); cache.removeAll(); refresh() } }
    @Published private(set) var busy = false
    @Published private(set) var reserved = 0.0
    @Published private(set) var monthlyMaximum = AIBudget.defaultLimit
    @Published private(set) var keySaved = false
    @Published private(set) var budgetError: String?
    private let budget: AIBudget
    private var cache: [String: String] = [:]
    private let networkPolicy = AINetworkPolicy()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil; c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 65
        return URLSession(configuration: c, delegate: networkPolicy, delegateQueue: nil)
    }()
    private init() {
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai-provider") ?? "apple") ?? .apple
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        budget = AIBudget(directory: base.appendingPathComponent((Bundle.main.bundleIdentifier ?? "se.workmate.mac") + "/AI"))
        refresh()
    }
    func refresh() {
        keySaved = AIKeys.read(provider) != nil
        do { reserved = try budget.reserved(); monthlyMaximum = try budget.monthlyLimit(); budgetError = nil } catch { budgetError = "Cannot read the AI budget. Paid requests are blocked until the budget file is available." }
    }
    func setMonthlyMaximum(_ text: String) throws {
        try budget.setMonthlyLimit(AIBudget.parseLimit(text))
        refresh()
    }
    func saveKey(_ value: String) throws {
        try AIKeys.save(value.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
        cache.removeAll(); refresh()
    }
    var disclosure: String {
        provider == .apple ? "Processed on this Mac. No API charge." : "Sends only the text shown here to \(provider.title) when you click Generate. Uses your API account."
    }
    func generate(instructions: String, input: String) async throws -> String {
        guard !busy else { throw AIError("Another AI request is still running.") }
        let selectedProvider = provider
        let identity = selectedProvider.rawValue + "\n" + instructions + "\n" + input
        if let answer = cache[identity] { return answer }
        guard input.utf8.count <= 24000 else { throw AIError("This text is too long. Select a shorter passage and try again.") }
        busy = true; defer { busy = false; refresh() }
        let result: String
        if selectedProvider == .apple {
            guard #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available else { throw AIError("Apple Intelligence is unavailable. Enable it in System Settings or add an API key in Workmate Settings → AI.") }
            let model = LanguageModelSession(instructions: instructions)
            result = try await model.respond(to: input, options: GenerationOptions(maximumResponseTokens: 1200)).content
        } else {
            guard let key = AIKeys.read(selectedProvider), !key.isEmpty else { throw AIError("Add your \(selectedProvider.title) API key in Settings → AI.") }
            let request = try AIWire.request(provider: selectedProvider, key: key, instructions: instructions, input: input)
            try Task.checkCancellation()
            try budget.reserve(AIBudget.reservation(provider: selectedProvider, instructions: instructions, input: input))
            reserved = try budget.reserved()
            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw AIError("No response from the AI provider.") }
                result = try AIWire.response(provider: selectedProvider, data: data, status: response.statusCode)
            } catch let error as AIError { throw error }
            catch { throw AIError("The request did not finish. Your text is unchanged. The budget reservation is kept because the provider may have processed it; no automatic retry was made.") }
        }
        try Task.checkCancellation()
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError("No text was returned.") }
        if cache.count >= 20 { cache.removeAll() }
        cache[identity] = result
        return result
    }
}
