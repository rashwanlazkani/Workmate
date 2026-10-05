import Foundation
import Testing
@testable import WorkmateCore

struct AIServiceTests {
    func budget() throws -> (AIBudget, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workmate-ai-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (AIBudget(directory: url), url)
    }
    @Test func sharedBudgetSurvivesReopenAndRejectsOverspend() throws {
        let (budget, url) = try budget(); defer { try? FileManager.default.removeItem(at: url) }
        try budget.reserve(4.99)
        let reopened = AIBudget(directory: url)
        #expect(try reopened.reserved() == 4.99)
        #expect(throws: AIError.self) { try reopened.reserve(0.02) }
        #expect(try reopened.reserved() == 4.99)
    }
    @Test func monthlyResetKeepsPreviousMonthAndRejectsInvalidCosts() throws {
        let (budget, url) = try budget(); defer { try? FileManager.default.removeItem(at: url) }
        let october = ISO8601DateFormatter().date(from: "2026-10-31T23:59:59Z")!
        let november = october.addingTimeInterval(2)
        try budget.reserve(5, date: october)
        #expect(try budget.reserved(date: november) == 0)
        try budget.reserve(1, date: november)
        #expect(try budget.reserved(date: october) == 5)
        #expect(throws: AIError.self) { try budget.reserve(-1) }
        #expect(throws: AIError.self) { try budget.reserve(.nan) }
    }
    @Test func corruptBudgetFailsClosed() throws {
        let (budget, url) = try budget(); defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url.appendingPathComponent("budget.json"))
        #expect(throws: (any Error).self) { try budget.reserve(0.01) }
    }
    @Test func concurrentReservationsCannotExceedFiveDollars() async throws {
        let (_, url) = try budget(); defer { try? FileManager.default.removeItem(at: url) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { try? AIBudget(directory: url).reserve(0.5) } }
        }
        #expect(try AIBudget(directory: url).reserved() == 5)
    }
    @Test func byteBasedEstimateProtectsUnicodeAndBothProviders() {
        let ascii = AIBudget.reservation(provider: .openAI, instructions: "Edit", input: "abc")
        let unicode = AIBudget.reservation(provider: .openAI, instructions: "Edit", input: "😀😀😀")
        #expect(unicode > ascii)
        #expect(AIBudget.reservation(provider: .anthropic, instructions: "Edit", input: "abc") > ascii)
    }
    @Test func requestFormatsAreBoundedAndDoNotEnableToolsOrStorage() throws {
        for provider in [AIProvider.openAI, .anthropic] {
            let request = try AIWire.request(provider: provider, key: "test-key", instructions: "Edit", input: "Hello")
            let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(json["model"] as? String == provider.model)
            #expect(json["tools"] == nil)
            if provider == .openAI {
                #expect(json["store"] as? Bool == false)
                #expect(json["max_output_tokens"] as? Int == 1200)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            } else {
                #expect(json["max_tokens"] as? Int == 1200)
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
                #expect(json["thinking"] == nil)
            }
        }
        #expect(throws: AIError.self) { try AIWire.request(provider: .openAI, key: "x", instructions: "Edit", input: String(repeating: "😀", count: 7000)) }
    }
    @Test func parsesBothProvidersAndRejectsTruncatedResponses() throws {
        let openAI = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Edited text"}]}]}"#.utf8)
        #expect(try AIWire.response(provider: .openAI, data: openAI, status: 200) == "Edited text")
        let claude = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"Edited text"}]}"#.utf8)
        #expect(try AIWire.response(provider: .anthropic, data: claude, status: 200) == "Edited text")
        #expect(throws: AIError.self) { try AIWire.response(provider: .anthropic, data: Data(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#.utf8), status: 200) }
        #expect(throws: AIError.self) { try AIWire.response(provider: .openAI, data: Data(#"{"status":"incomplete"}"#.utf8), status: 200) }
        #expect(throws: AIError.self) { try AIWire.response(provider: .openAI, data: Data(), status: 401) }
    }
    @Test func retrievalFindsLatePassagesAndPreservesSectionReferences() throws {
        var note = Note(title: "Meetings")
        let section = NoteSection(title: "PO sync", body: String(repeating: "Unrelated text. ", count: 400) + "PdM agreed to release on Friday.")
        note.setSections([section])
        let result = AIRetrieval.sources(notes: [note], query: "What did PdM decide about the release?")
        #expect(result.count <= 6)
        #expect(result.first?.text.contains("PdM agreed") == true)
        #expect(result.first?.sectionID == section.id)
        #expect(result.first?.id == "S1")
        let prompt = try AIRetrieval.prompt(question: "release?", sources: result)
        #expect(prompt.contains("S1"))
        #expect(AIRetrieval.sources(notes: [], query: "anything").isEmpty)
    }
}

@MainActor struct AIFormattingTests {
    @Test func outputBecomesNativeHeadingsAndListsWithoutMarkdownMarkers() {
        let value = AIFormattedText.render("# Decisions\n- **Ship** Friday\n- [ ] Ask *PdM* 👋")
        #expect(value.string == "Decisions\n• Ship Friday\n☐ Ask PdM 👋")
        #expect(value.attribute(.font, at: 0, effectiveRange: nil) != nil)
        #expect(value.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }
}

struct AIEditValidationTests {
    @Test func inventedNumbersAreRejectedButListNumbersAreAllowed() throws {
        #expect(throws: AIError.self) { try AIEditValidation.validate(original: "One", result: "June 1997 – 110,000 copies sold.") }
        try AIEditValidation.validate(original: "Ship on 2026-10-05. Ask PdM.", result: "1. Ship on 2026-10-05.\n2. Ask PdM.")
        #expect(throws: AIError.self) { try AIEditValidation.validate(original: "Ship tomorrow", result: "Ship on 2026-10-05") }
    }
}
