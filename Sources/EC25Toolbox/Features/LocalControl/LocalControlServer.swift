import Foundation
@preconcurrency import Network
import Security

enum LocalControlError: Error, Equatable {
    case invalidPort
    case tokenUnavailable
}

/// Loopback-only HTTP control for an external SIP bridge.
///
/// Off by default. A bridge reads the tracked call state and asks the store to
/// answer or hang up after its own SIP leg connects; commands go through the
/// store's normal call actions, never straight to the AT pipeline.
final class LocalControlServer: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var phase: String
        var number: String?
        var epoch: Int
    }

    enum Command: Equatable, Sendable {
        case answer
        case hangUp
        case dial(String)
    }

    enum Outcome: Equatable, Sendable {
        case accepted
        case refused(String)
    }

    struct Request: Equatable, Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var authorization: String?
    }

    struct Response: Equatable, Sendable {
        var status: Int
        var body: Data
    }

    typealias SnapshotProvider = @Sendable () async -> Snapshot
    typealias CommandHandler = @Sendable (Command, Int?) async -> Outcome

    static let maxRequestBytes = 8192

    private let queue = DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.localcontrol", qos: .userInitiated)
    private var listener: NWListener?
    private let snapshot: SnapshotProvider
    private let command: CommandHandler
    private var token = ""

    init(snapshot: @escaping SnapshotProvider, command: @escaping CommandHandler) {
        self.snapshot = snapshot
        self.command = command
    }

    /// Binds 127.0.0.1 only. A non-loopback address is never offered.
    func start(port: Int, token: String) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), (1...65_535).contains(port),
              !token.isEmpty else { throw LocalControlError.invalidPort }
        self.token = token
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let token = self.token
                Task {
                    let response = await Self.respond(
                        to: Self.parse(head), token: token,
                        snapshot: self.snapshot, command: self.command
                    )
                    self.send(response, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > Self.maxRequestBytes {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Pure request handling (unit-tested without sockets)

    static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/") else { return nil }
        let target = String(start[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { query[String(kv[0])] = String(kv[1]) }
            }
        }
        var authorization: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "authorization" {
                authorization = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return Request(method: String(start[0]), path: String(parts[0]), query: query, authorization: authorization)
    }

    /// Length-independent comparison so a wrong token leaks no prefix timing.
    static func tokensEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            diff |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return diff == 0
    }

    static func respond(
        to request: Request?, token: String,
        snapshot: SnapshotProvider, command: CommandHandler
    ) async -> Response {
        guard let request else { return json(400, ["ok": false, "error": "bad_request"]) }
        guard let authorization = request.authorization, authorization.hasPrefix("Bearer "),
              tokensEqual(String(authorization.dropFirst("Bearer ".count)), token) else {
            return json(401, ["ok": false, "error": "unauthorized"])
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/state"):
            return state(await snapshot(), ok: true)
        case ("POST", "/v1/answer"), ("POST", "/v1/hangup"):
            let epoch = request.query["epoch"].flatMap { Int($0) }
            if request.query["epoch"] != nil, epoch == nil {
                return json(400, ["ok": false, "error": "bad_epoch"])
            }
            let outcome = await command(request.path == "/v1/answer" ? .answer : .hangUp, epoch)
            switch outcome {
            case .accepted:
                return state(await snapshot(), ok: true)
            case let .refused(reason):
                var body = stateBody(await snapshot(), ok: false)
                body["error"] = reason
                return json(409, body)
            }
        case ("POST", "/v1/dial"):
            guard let number = request.query["number"], isDialable(number) else {
                return json(400, ["ok": false, "error": "bad_number"])
            }
            switch await command(.dial(number), nil) {
            case .accepted:
                return state(await snapshot(), ok: true)
            case let .refused(reason):
                var body = stateBody(await snapshot(), ok: false)
                body["error"] = reason
                return json(409, body)
            }
        case (_, "/v1/state"), (_, "/v1/answer"), (_, "/v1/hangup"), (_, "/v1/dial"):
            return json(405, ["ok": false, "error": "method_not_allowed"])
        default:
            return json(404, ["ok": false, "error": "not_found"])
        }
    }

    /// Digits plus `+`, `*`, `#` only, so nothing else ever reaches the AT dial command.
    static func isDialable(_ number: String) -> Bool {
        guard (1...20).contains(number.count) else { return false }
        return number.enumerated().allSatisfy { index, character in
            character.isASCII && (character.isNumber || "*#".contains(character) || (character == "+" && index == 0))
        }
    }

    private static func stateBody(_ snapshot: Snapshot, ok: Bool) -> [String: Any] {
        var body: [String: Any] = ["ok": ok, "phase": snapshot.phase, "epoch": snapshot.epoch]
        if let number = snapshot.number { body["number"] = number }
        return body
    }

    private static func state(_ snapshot: Snapshot, ok: Bool) -> Response {
        json(200, stateBody(snapshot, ok: ok))
    }

    private static func json(_ status: Int, _ object: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Response(status: status, body: data)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        default: "Error"
        }
    }
}

/// Persists the bearer token for the local control interface with owner-only
/// permissions. The external bridge reads the same file.
enum LocalControlToken {
    static func loadOrCreate(in directory: URL) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("token")
        if let data = try? Data(contentsOf: url),
           let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalControlError.tokenUnavailable
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        guard fileManager.createFile(
            atPath: url.path, contents: Data((token + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw LocalControlError.tokenUnavailable }
        return token
    }
}
