import Testing
private struct MissingValue: Error {}
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual == expected) }
func XCTAssertTrue(_ condition: Bool) { #expect(condition) }
func XCTAssertFalse(_ condition: Bool) { #expect(!condition) }
func XCTUnwrap<T>(_ value: T?) throws -> T { try #require(value) }
func XCTFail(_ message: String) { Issue.record(Comment(rawValue: message)) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); Issue.record("Expected an error") } catch { }
}
