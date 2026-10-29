// Tiny XCTest stand-in: just enough API for ModuleAudioTopologyTests.swift.
open class XCTestCase {
    public required init() {}
}

public nonisolated(unsafe) var xctShimFailures = 0
public nonisolated(unsafe) var xctShimAssertions = 0

private func fail(_ what: String, _ file: StaticString, _ line: UInt) {
    xctShimFailures += 1
    print("FAIL \(file):\(line): \(what)")
}

public func XCTAssertEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) {
    xctShimAssertions += 1
    let (x, y) = ((try? a()), (try? b()))
    if let x, let y, x == y { return }
    fail("XCTAssertEqual(\(String(describing: x)), \(String(describing: y)))", file, line)
}

public func XCTAssertNotEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) {
    xctShimAssertions += 1
    let (x, y) = ((try? a()), (try? b()))
    if let x, let y, x != y { return }
    fail("XCTAssertNotEqual(\(String(describing: x)), \(String(describing: y)))", file, line)
}

public func XCTAssertNil(
    _ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    xctShimAssertions += 1
    do { if try a() != nil { fail("XCTAssertNil", file, line) } } catch { fail("XCTAssertNil threw: \(error)", file, line) }
}

public func XCTAssertNotNil(
    _ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    xctShimAssertions += 1
    if (try? a()) ?? nil == nil { fail("XCTAssertNotNil", file, line) }
}

public func XCTAssertTrue(
    _ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    xctShimAssertions += 1
    if (try? a()) != true { fail("XCTAssertTrue", file, line) }
}

public func XCTAssertFalse(
    _ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    xctShimAssertions += 1
    if (try? a()) != false { fail("XCTAssertFalse", file, line) }
}
