import Foundation
import XCTest
@testable import EC25Toolbox

private actor CommandLog {
    var entries: [(LocalControlServer.Command, Int?)] = []
    func record(_ command: LocalControlServer.Command, _ epoch: Int?) { entries.append((command, epoch)) }
    var count: Int { entries.count }
    var last: (LocalControlServer.Command, Int?)? { entries.last }
}

final class LocalControlServerTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private let incoming = LocalControlServer.Snapshot(phase: "incoming", number: "+8610000", epoch: 7)

    private func request(_ method: String, _ path: String, query: [String: String] = [:], auth: String? = nil)
        -> LocalControlServer.Request {
        .init(method: method, path: path, query: query, authorization: auth ?? "Bearer \(token)")
    }

    private func call(
        _ request: LocalControlServer.Request?, outcome: LocalControlServer.Outcome = .accepted,
        log: CommandLog = CommandLog()
    ) async -> (status: Int, json: [String: Any]) {
        let snapshot = incoming
        let response = await LocalControlServer.respond(
            to: request, token: token,
            snapshot: { snapshot },
            command: { command, epoch in
                await log.record(command, epoch)
                return outcome
            }
        )
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        return (response.status, object)
    }

    func testParseExtractsMethodPathQueryAndAuthorization() {
        let head = "POST /v1/answer?epoch=7&x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nauthorization: Bearer abc"
        let parsed = LocalControlServer.parse(head)
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(parsed?.path, "/v1/answer")
        XCTAssertEqual(parsed?.query["epoch"], "7")
        XCTAssertEqual(parsed?.query["x"], "1")
        XCTAssertEqual(parsed?.authorization, "Bearer abc")
    }

    func testParseRejectsMalformedRequestLine() {
        XCTAssertNil(LocalControlServer.parse("GET /v1/state"))
        XCTAssertNil(LocalControlServer.parse("GET /v1/state NOTHTTP"))
        XCTAssertNil(LocalControlServer.parse(""))
    }

    func testTokensEqualComparesWholeValue() {
        XCTAssertTrue(LocalControlServer.tokensEqual("abc", "abc"))
        XCTAssertFalse(LocalControlServer.tokensEqual("abc", "abd"))
        XCTAssertFalse(LocalControlServer.tokensEqual("abc", "abcd"))
        XCTAssertFalse(LocalControlServer.tokensEqual("", "a"))
    }

    func testMissingOrWrongTokenIsUnauthorizedAndRunsNothing() async {
        let log = CommandLog()
        let wrong = await call(request("POST", "/v1/answer", auth: "Bearer nope"), log: log)
        XCTAssertEqual(wrong.status, 401)
        var noScheme = request("POST", "/v1/answer")
        noScheme.authorization = token
        let r1 = await call(noScheme, log: log)
        XCTAssertEqual(r1.status, 401)
        var missing = request("POST", "/v1/answer")
        missing.authorization = nil
        let r2 = await call(missing, log: log)
        XCTAssertEqual(r2.status, 401)
        let r3 = await call(nil, log: log)
        XCTAssertEqual(r3.status, 400)
        let count = await log.count
        XCTAssertEqual(count, 0)
    }

    func testStateReturnsSnapshot() async {
        let result = await call(request("GET", "/v1/state"))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json["phase"] as? String, "incoming")
        XCTAssertEqual(result.json["number"] as? String, "+8610000")
        XCTAssertEqual(result.json["epoch"] as? Int, 7)
        XCTAssertEqual(result.json["ok"] as? Bool, true)
    }

    func testAnswerIsForwardedWithEpoch() async {
        let log = CommandLog()
        let result = await call(request("POST", "/v1/answer", query: ["epoch": "7"]), log: log)
        XCTAssertEqual(result.status, 200)
        let last = await log.last
        XCTAssertEqual(last?.0, .answer)
        XCTAssertEqual(last?.1, 7)
    }

    func testHangupIsForwardedWithoutEpoch() async {
        let log = CommandLog()
        let result = await call(request("POST", "/v1/hangup"), log: log)
        XCTAssertEqual(result.status, 200)
        let last = await log.last
        XCTAssertEqual(last?.0, .hangUp)
        XCTAssertNil(last?.1)
    }

    func testRefusedCommandIsConflictWithReason() async {
        let result = await call(request("POST", "/v1/answer"), outcome: .refused("no_incoming_call"))
        XCTAssertEqual(result.status, 409)
        XCTAssertEqual(result.json["error"] as? String, "no_incoming_call")
        XCTAssertEqual(result.json["ok"] as? Bool, false)
    }

    func testBadEpochIsRejectedBeforeRunningAnything() async {
        let log = CommandLog()
        let result = await call(request("POST", "/v1/answer", query: ["epoch": "x"]), log: log)
        XCTAssertEqual(result.status, 400)
        let count = await log.count
        XCTAssertEqual(count, 0)
    }

    func testDialForwardsValidNumber() async {
        let log = CommandLog()
        let result = await call(request("POST", "/v1/dial", query: ["number": "+8613800138000"]), log: log)
        XCTAssertEqual(result.status, 200)
        let last = await log.last
        XCTAssertEqual(last?.0, .dial("+8613800138000"))
    }

    func testDialRejectsUnsafeNumbersBeforeRunningAnything() async {
        let log = CommandLog()
        for bad in ["", "12;ATH", "1 2", "12+3", "abc", String(repeating: "1", count: 21)] {
            let result = await call(request("POST", "/v1/dial", query: ["number": bad]), log: log)
            XCTAssertEqual(result.status, 400)
        }
        let missing = await call(request("POST", "/v1/dial"), log: log)
        XCTAssertEqual(missing.status, 400)
        let wrongMethod = await call(request("GET", "/v1/dial", query: ["number": "10086"]), log: log)
        XCTAssertEqual(wrongMethod.status, 405)
        let count = await log.count
        XCTAssertEqual(count, 0)
    }

    func testDialRefusalIsConflict() async {
        let result = await call(request("POST", "/v1/dial", query: ["number": "10086"]), outcome: .refused("call_in_progress"))
        XCTAssertEqual(result.status, 409)
        XCTAssertEqual(result.json["error"] as? String, "call_in_progress")
    }

    func testUnknownPathAndWrongMethod() async {
        let r4 = await call(request("GET", "/nope"))
        XCTAssertEqual(r4.status, 404)
        let r5 = await call(request("GET", "/v1/answer"))
        XCTAssertEqual(r5.status, 405)
        let r6 = await call(request("POST", "/v1/state"))
        XCTAssertEqual(r6.status, 405)
    }

    func testTokenFileIsCreatedOwnerOnlyAndStable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LocalControlToken.loadOrCreate(in: directory)
        let second = try LocalControlToken.loadOrCreate(in: directory)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("token").path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o600)
    }

    func testLoopbackServerSpeaksHTTP() async throws {
        let log = CommandLog()
        let snapshot = incoming
        let server = LocalControlServer(
            snapshot: { snapshot },
            command: { command, epoch in
                await log.record(command, epoch)
                return .accepted
            }
        )
        let port = 49_000 + Int.random(in: 0..<900)
        try server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func fetch(_ method: String, _ path: String, bearer: String?) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, object)
        }

        let state = try await fetch("GET", "/v1/state", bearer: token)
        XCTAssertEqual(state.0, 200)
        XCTAssertEqual(state.1["phase"] as? String, "incoming")
        let denied = try await fetch("POST", "/v1/answer", bearer: "wrong")
        XCTAssertEqual(denied.0, 401)
        let answered = try await fetch("POST", "/v1/answer?epoch=7", bearer: token)
        XCTAssertEqual(answered.0, 200)
        let count = await log.count
        XCTAssertEqual(count, 1)
    }
}
