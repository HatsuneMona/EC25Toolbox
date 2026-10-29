import Foundation
import XCTest
@testable import EC25Toolbox

@MainActor
private final class ForwardingMemorySecrets: SMSForwardingSecretStorage {
    var values: [UUID: SMSForwardingSecrets] = [:]
    func read(id: UUID) throws -> SMSForwardingSecrets { values[id] ?? .init() }
    func save(_ secrets: SMSForwardingSecrets, id: UUID) throws { values[id] = secrets }
    func delete(id: UUID) throws { values.removeValue(forKey: id) }
}

private actor ForwardingRecordingTransport: SMSForwardingTransport {
    var requests: [URLRequest] = []
    var replies: [SMSForwardingHTTPResponse]
    init(codes: [Int] = [200], body: String = "ok") {
        replies = codes.map { .init(statusCode: $0, data: Data(body.utf8)) }
    }
    func send(_ request: URLRequest) async throws -> SMSForwardingHTTPResponse {
        requests.append(request)
        return replies.count > 1 ? replies.removeFirst() : replies[0]
    }
    func captured() -> [URLRequest] { requests }
}

private actor ForwardingSuspendedTransport: SMSForwardingTransport {
    var continuation: CheckedContinuation<SMSForwardingHTTPResponse, Never>?
    var started = false
    func send(_ request: URLRequest) async throws -> SMSForwardingHTTPResponse {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { started }
    func complete() { continuation?.resume(returning: .init(statusCode: 200, data: Data("ok".utf8))); continuation = nil }
}

@MainActor
private final class ForwardingFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EC25-forwarding-test-" + UUID().uuidString)
    let secrets = ForwardingMemorySecrets()
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    var channel: SMSForwardingChannel
    let transport: any SMSForwardingTransport
    lazy var store = makeStore()
    init(kind: SMSForwardingChannelKind = .webhook, transport: any SMSForwardingTransport = ForwardingRecordingTransport()) {
        channel = SMSForwardingChannel(name: "fixture", kind: kind)
        self.transport = transport
    }
    func makeStore(autoStart: Bool = false) -> SMSForwardingStore {
        SMSForwardingStore(directory: directory, secretStorage: secrets, transport: transport, now: { [unowned self] in self.date }, autoStart: autoStart)
    }
    func configure() throws {
        try store.saveChannel(channel, secrets: .init(endpoint: "https://example.invalid/secret-token", signingSecret: "secret", headers: ["Authorization": "Bearer secret-value"]))
        try store.saveRule(SMSForwardingRule(name: "all incoming", channelIDs: [channel.id]))
        try store.setEnabled(true)
    }
    func message(_ id: String = "new", body: String = "验证码 123456", components: [String]? = nil) -> SMSForwardingMessage {
        .init(id: id, sender: "+8610086", body: body, receivedAt: date, moduleID: "modem", moduleName: "模块", simID: "sim", simName: "SIM", componentIDs: components ?? [id])
    }
    func ingest(_ messages: [SMSForwardingMessage], observed: Set<String> = [], complete: Bool = true, into target: SMSForwardingStore? = nil) {
        (target ?? store).ingest(messages: messages, observedComponentIDs: observed, moduleID: "modem", simID: "sim", isCompleteSnapshot: complete)
    }
    func baseline() { ingest([]) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class SMSForwardingCoreTests: XCTestCase {
    private func fails(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body(); XCTAssertTrue(false, "Expected failure", file: file, line: line) } catch { }
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
    }

    func testRuleRequiresEveryConstraintAndHandlesUnicodeRegex() {
        let f = ForwardingFixture()
        var rule = SMSForwardingRule(moduleID: "modem", simID: "sim", senderContains: "10086", keywords: "验证码\n 123456 \n", pattern: "验证码 [0-9]{6}")
        XCTAssertTrue(rule.matches(f.message(body: "😀 验证码 123456")))
        XCTAssertFalse(rule.matches(f.message(body: "验证码 999999")))
        var other = f.message(); other.simID = "other"
        XCTAssertFalse(rule.matches(other))
        other = f.message(); other.moduleID = "other"
        XCTAssertFalse(rule.matches(other))
        other = f.message(); other.sender = "other"
        XCTAssertFalse(rule.matches(other))
        rule.pattern = "["
        XCTAssertFalse(rule.matches(f.message()))
        rule.pattern = ""; rule.enabled = false
        XCTAssertFalse(rule.matches(f.message()))
    }

    func testStructuralJSONEscapesSMSAndDoesNotExpandInjectedPlaceholders() throws {
        let f = ForwardingFixture()
        let message = f.message(body: "引号\"\n反斜线\\ ${from} [sim] 😀")
        var channel = f.channel
        channel.bodyTemplate = #"{"nested":["${content}",{"sender":"${from}"}],"timestamp":"${timestamp}","literal":true}"#
        let request = try SMSForwardingSender.request(channel: channel, secrets: .init(endpoint: "https://example.invalid"), message: message, now: f.date)
        let payload = try json(request)
        let nested = payload["nested"] as! [Any]
        XCTAssertEqual(nested[0] as? String, message.body)
        XCTAssertEqual((nested[1] as? [String: String])?["sender"], message.sender)
        XCTAssertEqual(payload["timestamp"] as? Int64, 1_700_000_000_000)
        XCTAssertEqual(payload["literal"] as? Bool, true)
        XCTAssertEqual(SMSForwardingSender.render("${content}|[from]|${unknown}", message: message), message.body + "|" + message.sender + "|${unknown}")
    }

    func testFormAndGETPreservePlusUnicodeAndExistingQuery() throws {
        let f = ForwardingFixture()
        var channel = f.channel
        channel.bodyTemplate = #"{"value":"${content}","empty":null,"number":12}"#
        channel.bodyFormat = .form
        let message = f.message(body: "+ & = 中\n")
        let secrets = SMSForwardingSecrets(endpoint: "https://example.invalid/path?fixed=a%2Bb")
        var request = try SMSForwardingSender.request(channel: channel, secrets: secrets, message: message, now: f.date)
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "empty=&number=12&value=%2B%20%26%20%3D%20%E4%B8%AD%0A")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        channel.method = .get
        request = try SMSForwardingSender.request(channel: channel, secrets: secrets, message: message, now: f.date)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first(where: { $0.name == "fixed" })?.value, "a+b")
        XCTAssertEqual(query.first(where: { $0.name == "value" })?.value, message.body)
        XCTAssertFalse(request.url!.absoluteString.contains("+"))
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        channel.bodyTemplate = #"{"nested":{"a":1}}"#
        fails { try SMSForwardingSender.validate(channel: channel, secrets: secrets) }
    }

    func testSignaturesUseIndependentGoldenVectorsAndCorrectTimestamps() throws {
        let f = ForwardingFixture(kind: .feishu)
        let message = f.message()
        let secret = SMSForwardingSecrets(endpoint: "https://example.invalid", signingSecret: "secret")
        // Golden vectors generated with Python's hmac/hashlib, independent of Swift implementation.
        XCTAssertEqual(SMSForwardingSender.feishuSignature(timestamp: "1700000000", secret: "secret"), "fiWS2+gh28DOydAv7hzONH/mDn9+b1Y4Y5ivXWXy8vA=")
        XCTAssertEqual(SMSForwardingSender.render("${sign}", message: message, signingSecret: "secret"), "OuzzJR5%2BxZ4%2FEYwqtNt6sMYZQMTa%2FHEGvc9miJe7XzY%3D")
        let request = try SMSForwardingSender.request(channel: f.channel, secrets: secret, message: message, now: f.date.addingTimeInterval(10))
        let payload = try json(request)
        XCTAssertEqual(payload["timestamp"] as? String, "1700000010")
        XCTAssertEqual(payload["msg_type"] as? String, "interactive")
        let card = payload["card"] as! [String: Any]
        let elements = card["elements"] as! [[String: Any]]
        XCTAssertEqual((elements[0]["text"] as! [String: Any])["tag"] as? String, "plain_text")
        let preview = try SMSForwardingSender.preview(channel: f.channel, secrets: secret)
        XCTAssertFalse(preview.contains("secret"))
        XCTAssertFalse(preview.contains("\"sign\""))
    }

    func testValidationRejectsUnsafeHeadersURLsAndInvalidTemplates() {
        let f = ForwardingFixture()
        for endpoint in ["file:///tmp/a", "https://user:pass@example.invalid", "https://example.invalid/#secret", "https://"] {
            fails { try SMSForwardingSender.validate(channel: f.channel, secrets: .init(endpoint: endpoint)) }
        }
        for headers in [["Host": "other"], ["Content-Length": "5"], ["X Bad": "value"]] {
            fails { try SMSForwardingSender.validate(channel: f.channel, secrets: .init(endpoint: "https://example.invalid", headers: headers)) }
        }
        fails { try SMSForwardingSender.validate(channel: f.channel, secrets: .init(endpoint: "https://example.invalid", headers: ["X-Test": "a\r\nb"])) }
        fails { _ = try SMSForwardingSender.request(channel: f.channel, secrets: .init(endpoint: "https://example.invalid", headers: ["X-Test": "${content}"]), message: f.message(body: "a\r\nb"), now: f.date) }
        fails { _ = try SMSForwardingSender.request(channel: f.channel, secrets: .init(endpoint: "https://example.invalid", headers: ["X-Test": "${content}"]), message: f.message(body: "a\nb"), now: f.date) }
        var channel = f.channel; channel.bodyTemplate = "[]"
        fails { try SMSForwardingSender.validate(channel: channel, secrets: .init(endpoint: "https://example.invalid")) }
        channel.kind = .feishu
        fails { try SMSForwardingSender.validate(channel: channel, secrets: .init(endpoint: "http://example.invalid")) }
    }

    func testResponseClassificationAndCredentialFreeDetails() {
        let f = ForwardingFixture()
        func outcome(_ kind: SMSForwardingChannelKind, _ code: Int, _ body: String) -> SMSForwardingOutcome {
            var channel = f.channel; channel.kind = kind
            return SMSForwardingSender.outcome(channel: channel, response: .init(statusCode: code, data: Data(body.utf8)))
        }
        for code in [429, 500, 503] { XCTAssertTrue(outcome(.webhook, code, "secret-response").retryable) }
        for code in [301, 400, 401, 404] { XCTAssertFalse(outcome(.webhook, code, "secret-response").retryable) }
        XCTAssertEqual(outcome(.feishu, 200, #"{"code":0}"#).status, .succeeded)
        XCTAssertTrue(outcome(.feishu, 200, #"{"code":11232}"#).retryable)
        XCTAssertEqual(outcome(.feishu, 200, "{}").status, .failed)
        XCTAssertFalse(outcome(.feishu, 200, #"{"code":19021}"#).retryable)
        for status in ["submitted", "queued"] { XCTAssertEqual(outcome(.vpnManager, 200, "{\"status\":\"\(status)\"}").status, .succeeded) }
        for status in ["duplicate", "ignored"] { XCTAssertEqual(outcome(.vpnManager, 200, "{\"status\":\"\(status)\",\"reason\":\"secret-response\"}").status, .ignored) }
        XCTAssertEqual(outcome(.vpnManager, 200, #"{"status":"unexpected"}"#).status, .failed)
        XCTAssertFalse(outcome(.vpnManager, 200, #"{"status":"ignored","reason":"secret-response"}"#).detail.contains("secret-response"))
        var channel = f.channel; channel.responseContains = "accepted"
        XCTAssertEqual(SMSForwardingSender.outcome(channel: channel, response: .init(statusCode: 200, data: Data("ok".utf8))).status, .failed)
        XCTAssertEqual(SMSForwardingSender.outcome(channel: channel, response: .init(statusCode: 200, data: Data("accepted".utf8))).status, .succeeded)
    }

    func testBaselineBlocksHistoryIncludingHistoricalPartialMessages() throws {
        let f = ForwardingFixture(); defer { f.cleanup() }; try f.configure()
        let old = f.message("old")
        f.ingest([old], observed: ["old", "fragment-old"], complete: false)
        XCTAssertTrue(f.store.jobs.isEmpty)
        f.ingest([old], observed: ["old", "fragment-old"])
        let completed = f.message("assembled", components: ["fragment-old", "fragment-new"])
        let new = f.message("fresh", components: ["fresh-1", "fresh-2"])
        f.ingest([old, completed, new], complete: false)
        f.ingest([new])
        XCTAssertEqual(f.store.jobs.count, 1)
        XCTAssertEqual(f.store.jobs.first?.message, new)
        // A second matching rule still creates only one job for the same channel.
        try f.store.saveRule(SMSForwardingRule(name: "overlap", channelIDs: [f.channel.id]))
        f.ingest([f.message("next")])
        XCTAssertEqual(f.store.jobs.count, 2)
        let restarted = f.makeStore()
        f.ingest([old, completed, new, f.message("next")], into: restarted)
        XCTAssertEqual(restarted.jobs.count, 2)
    }

    func testRetryScheduleStopsAtFourAttemptsAndKeepsPayloadTimestamp() async throws {
        let transport = ForwardingRecordingTransport(codes: [503])
        let f = ForwardingFixture(transport: transport); defer { f.cleanup() }; try f.configure(); f.baseline()
        let message = f.message(); f.ingest([message])
        let delays: [TimeInterval] = [5, 30, 120]
        for delay in delays {
            let processed = await f.store.processNextReady(); XCTAssertTrue(processed)
            XCTAssertEqual(f.store.jobs[0].status, .retrying)
            XCTAssertEqual(f.store.jobs[0].nextAttemptAt, f.date.addingTimeInterval(delay))
            let early = await f.store.processNextReady(); XCTAssertFalse(early)
            f.date.addTimeInterval(delay)
        }
        let final = await f.store.processNextReady(); XCTAssertTrue(final)
        XCTAssertEqual(f.store.jobs[0].status, .failed)
        XCTAssertEqual(f.store.jobs[0].attempts, 4)
        XCTAssertNil(f.store.jobs[0].nextAttemptAt)
        let again = await f.store.processNextReady(); XCTAssertFalse(again)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 4)
        for request in requests { XCTAssertEqual(try json(request)["timestamp"] as? Int64, 1_700_000_000_000) }
        XCTAssertEqual(Set(requests.compactMap(\.httpBody)).count, 1)
        try f.store.retry(jobID: f.store.jobs[0].id)
        XCTAssertEqual(f.store.jobs[0].attempts, 0)
        XCTAssertEqual(f.store.jobs[0].message.receivedAt, message.receivedAt)
    }

    func testRestartRestoresQueuedRetryAndInterruptedAttemptLimit() async throws {
        let transport = ForwardingRecordingTransport(codes: [503, 200])
        let f = ForwardingFixture(transport: transport); defer { f.cleanup() }; try f.configure(); f.baseline()
        f.ingest([f.message()])
        let id = f.store.jobs[0].id
        let first = await f.store.processNextReady(); XCTAssertTrue(first)
        let restarted = f.makeStore()
        XCTAssertEqual(restarted.jobs[0].id, id)
        XCTAssertEqual(restarted.jobs[0].attempts, 1)
        let early = await restarted.processNextReady(); XCTAssertFalse(early)
        f.date.addTimeInterval(5)
        let resumed = await restarted.processNextReady(); XCTAssertTrue(resumed)
        XCTAssertEqual(restarted.jobs[0].status, .succeeded)
        XCTAssertEqual(restarted.jobs[0].attempts, 2)
        // Model a process death after persisting the fourth attempt, before its response.
        let url = f.directory.appendingPathComponent("forwarding-v1.json")
        var persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var jobs = persisted["jobs"] as! [[String: Any]]
        jobs[0]["status"] = "sending"; jobs[0]["attempts"] = 4
        persisted["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: persisted).write(to: url)
        let interrupted = f.makeStore()
        XCTAssertEqual(interrupted.jobs[0].status, .queued)
        let stopped = await interrupted.processNextReady(); XCTAssertTrue(stopped)
        XCTAssertEqual(interrupted.jobs[0].status, .failed)
        XCTAssertEqual(interrupted.jobs[0].attempts, 4)
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 2)
    }

    func testDisableReenableTakesFreshBaselineAndChannelEditCancelsOnlyTarget() async throws {
        let transport = ForwardingRecordingTransport()
        let f = ForwardingFixture(transport: transport); defer { f.cleanup() }; try f.configure(); f.baseline()
        f.ingest([f.message("before-disable")])
        try f.store.setEnabled(false)
        XCTAssertTrue(f.store.allowsModemCleanup)
        XCTAssertEqual(f.store.jobs[0].status, .cancelled)
        let disabled = await f.store.processNextReady(); XCTAssertFalse(disabled)
        fails { try f.store.retry(jobID: f.store.jobs[0].id) }
        try f.store.setEnabled(true)
        f.ingest([f.message("during-disabled")]); f.ingest([f.message("during-disabled")])
        XCTAssertEqual(f.store.jobs.count, 1)
        var second = f.channel; second.id = UUID(); second.name = "second"
        try f.store.saveChannel(second, secrets: .init(endpoint: "https://example.invalid/second"))
        try f.store.saveRule(SMSForwardingRule(name: "second rule", channelIDs: [second.id]))
        f.ingest([f.message("after-enable")])
        try f.store.saveChannel(f.channel, secrets: .init(endpoint: "https://example.invalid/edited"))
        XCTAssertEqual(f.store.jobs.filter { $0.channelID == f.channel.id && $0.status.isPending }.count, 0)
        XCTAssertEqual(f.store.jobs.filter { $0.channelID == second.id && $0.status.isPending }.count, 1)
        try f.store.deleteChannel(id: second.id)
        XCTAssertFalse(f.store.jobs.contains { $0.status.isPending })
        XCTAssertFalse(f.store.configuration.rules.contains { $0.channelIDs.contains(second.id) })
        let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
    }

    func testLateResponseCannotOverwriteCancellation() async throws {
        let transport = ForwardingSuspendedTransport()
        let f = ForwardingFixture(transport: transport); defer { f.cleanup() }; try f.configure(); f.baseline(); f.ingest([f.message()])
        let pending = Task { await f.store.processNextReady() }
        for _ in 0..<2000 {
            if await transport.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await transport.hasStarted(); XCTAssertTrue(started)
        guard started else { pending.cancel(); return }
        XCTAssertEqual(f.store.jobs[0].status, .sending)
        try f.store.setEnabled(false)
        await transport.complete()
        _ = await pending.value
        XCTAssertEqual(f.store.jobs[0].status, .cancelled)
        XCTAssertEqual(f.makeStore().jobs[0].status, .cancelled)
    }

    func testEnablingDuringTestSendDoesNotStrandTheInFlightJob() async throws {
        let transport = ForwardingSuspendedTransport()
        let f = ForwardingFixture(transport: transport); defer { f.cleanup() }; try f.configure()
        try f.store.setEnabled(false)
        let running = f.makeStore(autoStart: true)
        try running.testChannel(id: f.channel.id)
        for _ in 0..<2000 {
            if await transport.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await transport.hasStarted(); XCTAssertTrue(started)
        guard started else { try running.setEnabled(true); try running.setEnabled(false); return }
        XCTAssertEqual(running.jobs[0].status, .sending)
        XCTAssertTrue(running.jobs[0].isTest)
        try running.setEnabled(true)
        await transport.complete()
        for _ in 0..<2000 {
            if running.jobs[0].status != .sending { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(running.jobs[0].status, .succeeded)
        XCTAssertEqual(f.makeStore().jobs[0].status, .succeeded)
        try running.setEnabled(false)
    }

    func testVPNExpiryFutureTimeAndRetryWindowNeverSendStaleCodes() async throws {
        let transport = ForwardingRecordingTransport(codes: [503])
        let f = ForwardingFixture(kind: .vpnManager, transport: transport); defer { f.cleanup() }; try f.configure(); f.baseline()
        var old = f.message("old"); old.receivedAt.addTimeInterval(-181)
        var future = f.message("future"); future.receivedAt.addTimeInterval(31)
        var nearExpiry = f.message("near-expiry"); nearExpiry.receivedAt.addTimeInterval(-178)
        f.ingest([old, future, nearExpiry])
        _ = await f.store.processNextReady(); _ = await f.store.processNextReady(); _ = await f.store.processNextReady()
        XCTAssertEqual(f.store.jobs.map(\.status), [.expired, .failed, .expired])
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try json(requests[0])["timestamp"] as? Int64, 1_699_999_822_000)
        fails { try f.store.retry(jobID: f.store.jobs[0].id) }
    }

    func testPersistenceExcludesSecretsAndCorruptionFailsClosed() async throws {
        let f = ForwardingFixture(); defer { f.cleanup() }; try f.configure(); f.baseline(); f.ingest([f.message()])
        let url = f.directory.appendingPathComponent("forwarding-v1.json")
        let saved = try String(contentsOf: url, encoding: .utf8)
        for secret in ["secret-token", "secret-value", "Authorization", "signingSecret", "endpoint"] { XCTAssertFalse(saved.contains(secret)) }
        let corrupt = Data("broken persistent data".utf8)
        try corrupt.write(to: url)
        let restarted = f.makeStore()
        XCTAssertNotNil(restarted.lastError)
        XCTAssertFalse(restarted.allowsModemCleanup)
        let processed = await restarted.processNextReady(); XCTAssertFalse(processed)
        fails { try restarted.setEnabled(true) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testFailedStateWriteRollsBackCredentialChange() throws {
        let f = ForwardingFixture(); defer { f.cleanup() }; try f.configure()
        let original = try f.secrets.read(id: f.channel.id)
        XCTAssertTrue(f.store.allowsModemCleanup)
        try FileManager.default.removeItem(at: f.directory)
        try Data("not a directory".utf8).write(to: f.directory)
        fails { try f.store.saveChannel(f.channel, secrets: .init(endpoint: "https://example.invalid/new")) }
        XCTAssertEqual(try f.secrets.read(id: f.channel.id), original)
        XCTAssertNotNil(f.store.lastError)
        XCTAssertFalse(f.store.allowsModemCleanup)
    }
}
