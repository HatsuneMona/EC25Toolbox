import CryptoKit
import Foundation

// Protocol behavior ported from pppscn/SmsForwarder (BSD-2-Clause), commit
// ce931a03739a6a2b0dfc83161bf812a94fd5e45e, FeishuUtils.kt / WebhookUtils.kt.
// See THIRD_PARTY_NOTICES.md. HTTP/Keychain/queue integration is native Swift.
struct SMSForwardingHTTPResponse: Sendable {
    var statusCode: Int
    var data: Data
}
protocol SMSForwardingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SMSForwardingHTTPResponse
}

/// A redirect must not transmit a bot URL, Authorization header or SMS body to
/// a second destination. Let the user correct the configured endpoint instead.
private final class SMSForwardingNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
final class SMSForwardingURLTransport: SMSForwardingTransport, @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SMSForwardingNoRedirect(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> SMSForwardingHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= 1_048_576 else { throw SMSForwardingError.invalid("响应内容过大。") }
        return SMSForwardingHTTPResponse(statusCode: http.statusCode, data: data)
    }
}

struct SMSForwardingOutcome: Sendable {
    var status: SMSForwardingJobStatus
    var detail: String
    var retryable = false
}

enum SMSForwardingSender {
    static let variables = ["from", "content", "msg", "org_content", "timestamp", "receive_time", "module", "module_id", "sim", "sim_id", "sign"]

    static func validate(channel: SMSForwardingChannel, secrets: SMSForwardingSecrets) throws {
        guard !channel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMSForwardingError.invalid("请输入通道名称。")
        }
        guard let components = URLComponents(string: secrets.endpoint),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.fragment == nil else {
            throw SMSForwardingError.invalid("请输入有效的 HTTP/HTTPS 地址；鉴权信息请放在请求头中。")
        }
        if channel.kind == .feishu && components.scheme?.lowercased() != "https" {
            throw SMSForwardingError.invalid("飞书机器人需要 HTTPS 地址。")
        }
        for (name, value) in secrets.headers {
            guard !name.isEmpty, name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
                  value.rangeOfCharacter(from: .newlines) == nil else {
                throw SMSForwardingError.invalid("请求头名称或值格式不正确。")
            }
            if ["host", "content-length"].contains(name.lowercased()) {
                throw SMSForwardingError.invalid("Host 和 Content-Length 由客户端自动生成。")
            }
        }
        if channel.kind == .webhook {
            if channel.method == .get && channel.bodyFormat == .text {
                throw SMSForwardingError.invalid("GET 参数请使用 JSON 或表单对象。")
            }
            if channel.bodyFormat != .text {
                guard let object = try? JSONSerialization.jsonObject(with: Data(channel.bodyTemplate.utf8)), object is [String: Any] else {
                    throw SMSForwardingError.invalid("JSON/表单模板必须是有效 JSON 对象，占位符应放在字符串值中。")
                }
            }
        }
        _ = try request(channel: channel, secrets: secrets, message: .sample(), now: Date(), validateFirst: false)
    }

    static func render(_ template: String, message: SMSForwardingMessage, signingSecret: String = "") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = String(Int64(message.receivedAt.timeIntervalSince1970 * 1000))
        let signingData = Data((timestamp + "\n" + signingSecret).utf8)
        let signature = signingSecret.isEmpty ? "" : Data(HMAC<SHA256>.authenticationCode(for: signingData, using: SymmetricKey(data: Data(signingSecret.utf8)))).base64EncodedString()
        let values: [String: String] = [
            "from": message.sender, "content": message.body, "msg": message.body, "org_content": message.body,
            "timestamp": timestamp, "receive_time": formatter.string(from: message.receivedAt),
            "module": message.moduleName, "module_id": message.moduleID, "sim": message.simName, "sim_id": message.simID,
            "sign": percentEncode(signature), "device_mark": message.moduleName, "card_slot": message.simName,
            "title": message.simName, "level": message.isCall ? "timeSensitive" : "active",
            "event": message.isCall ? "call" : "sms", "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "27.1"
        ]
        // One substitution pass: placeholder-like text inside an SMS stays literal.
        let expression = try! NSRegularExpression(pattern: #"(?:\$\{([a-z_]+)\}|\[([a-z_]+)\])"#)
        let range = NSRange(template.startIndex..., in: template)
        var result = template
        for match in expression.matches(in: template, range: range).reversed() {
            let keyMatch = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            guard let keyRange = Range(keyMatch, in: template), let replaceRange = Range(match.range, in: result),
                  let value = values[String(template[keyRange])] else { continue }
            result.replaceSubrange(replaceRange, with: value)
        }
        return result
    }

    static func feishuSignature(timestamp: String, secret: String) -> String {
        let key = SymmetricKey(data: Data((timestamp + "\n" + secret).utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data(), using: key)).base64EncodedString()
    }

    private static func structured(_ value: Any, message: SMSForwardingMessage, secret: String) -> Any {
        if let text = value as? String {
            if text == "${timestamp}" || text == "[timestamp]" { return Int64(message.receivedAt.timeIntervalSince1970 * 1000) }
            return render(text, message: message, signingSecret: secret)
        }
        if let values = value as? [Any] { return values.map { structured($0, message: message, secret: secret) } }
        if let values = value as? [String: Any] { return values.mapValues { structured($0, message: message, secret: secret) } }
        return value
    }

    private static func scalar(_ value: Any) throws -> String {
        if let text = value as? String { return text }
        if value is NSNull { return "" }
        if let number = value as? NSNumber { return number.stringValue }
        throw SMSForwardingError.invalid("表单和 GET 参数仅支持字符串、数字、布尔值或 null。")
    }
    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    static func request(channel: SMSForwardingChannel, secrets: SMSForwardingSecrets,
                        message: SMSForwardingMessage, now: Date, validateFirst: Bool = true) throws -> URLRequest {
        if validateFirst { try validate(channel: channel, secrets: secrets) }
        guard var url = URLComponents(string: secrets.endpoint), let initialURL = url.url else {
            throw SMSForwardingError.invalid("通道地址无效。")
        }
        var request = URLRequest(url: initialURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = channel.kind == .webhook ? channel.method.rawValue : "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (name, template) in secrets.headers {
            let value = render(template, message: message, signingSecret: secrets.signingSecret)
            guard value.rangeOfCharacter(from: .newlines) == nil else { throw SMSForwardingError.invalid("模板展开后的请求头包含换行。") }
            request.setValue(value, forHTTPHeaderField: name)
        }
        switch channel.kind {
        case .feishu:
            let timestamp = String(Int64(now.timeIntervalSince1970))
            var payload: [String: Any] = [
                "msg_type": "interactive",
                "card": [
                    "config": ["wide_screen_mode": true],
                    "header": ["template": "blue", "title": ["tag": "plain_text", "content": render(channel.titleTemplate, message: message)]],
                    "elements": [["tag": "div", "text": ["tag": "plain_text", "content": render(channel.contentTemplate, message: message)]]]
                ]
            ]
            if !secrets.signingSecret.isEmpty {
                payload["timestamp"] = timestamp
                payload["sign"] = feishuSignature(timestamp: timestamp, secret: secrets.signingSecret)
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        case .vpnManager:
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "from": message.sender, "content": message.body,
                "timestamp": Int64(message.receivedAt.timeIntervalSince1970 * 1000)
            ], options: [.sortedKeys])
        case .webhook:
            if channel.bodyFormat == .text {
                request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(render(channel.bodyTemplate, message: message, signingSecret: secrets.signingSecret).utf8)
            } else {
                let object = try JSONSerialization.jsonObject(with: Data(channel.bodyTemplate.utf8))
                guard let payload = structured(object, message: message, secret: secrets.signingSecret) as? [String: Any] else {
                    throw SMSForwardingError.invalid("请求模板必须是 JSON 对象。")
                }
                if channel.method == .get {
                    let query = try payload.keys.sorted().map { URLQueryItem(name: $0, value: try scalar(payload[$0]!)) }
                    url.queryItems = (url.queryItems ?? []) + query
                    // URLComponents leaves '+' literal; servers often decode it as space.
                    url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                    request.url = url.url
                    request.setValue(nil, forHTTPHeaderField: "Content-Type")
                } else if channel.bodyFormat == .form {
                    request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data(try payload.keys.sorted().map {
                        percentEncode($0) + "=" + percentEncode(try scalar(payload[$0]!))
                    }.joined(separator: "&").utf8)
                } else {
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                }
            }
        }
        return request
    }

    /// Preview deliberately excludes URL/headers/signature. The test message
    /// contains no numeric code and never enters a vpn-manager request.
    static func preview(channel: SMSForwardingChannel, secrets: SMSForwardingSecrets,
                        message: SMSForwardingMessage = .sample()) throws -> String {
        var sanitized = secrets
        sanitized.signingSecret = ""
        sanitized.headers = [:]
        let built = try request(channel: channel, secrets: sanitized, message: message, now: Date())
        if channel.kind == .webhook && channel.method == .get {
            let source = try JSONSerialization.jsonObject(with: Data(channel.bodyTemplate.utf8))
            return String(data: try JSONSerialization.data(withJSONObject: structured(source, message: message, secret: ""), options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? ""
        }
        if let data = built.httpBody, let object = try? JSONSerialization.jsonObject(with: data) {
            return String(data: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? ""
        }
        return built.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func outcome(channel: SMSForwardingChannel, response: SMSForwardingHTTPResponse) -> SMSForwardingOutcome {
        let code = response.statusCode
        guard (200..<300).contains(code) else {
            return .init(status: .failed, detail: "HTTP \(code)", retryable: code == 429 || (500..<600).contains(code))
        }
        switch channel.kind {
        case .feishu:
            guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let result = object["code"] as? Int else {
                return .init(status: .failed, detail: "飞书响应缺少有效的业务状态。")
            }
            if result == 0 { return .init(status: .succeeded, detail: "飞书已接收") }
            // Feishu custom-bot rate-limit code. Other business errors need a config fix.
            return .init(status: .failed, detail: "飞书业务错误 \(result)", retryable: result == 11232)
        case .vpnManager:
            guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let status = object["status"] as? String else {
                return .init(status: .failed, detail: "vpn-manager 响应缺少有效状态。")
            }
            switch status {
            case "submitted": return .init(status: .succeeded, detail: "submitted：验证码已提交")
            case "queued": return .init(status: .succeeded, detail: "queued：验证码已进入接收端队列")
            case "duplicate": return .init(status: .ignored, detail: "duplicate：接收端已处理相同短信")
            case "ignored":
                let reason = object["reason"] as? String ?? ""
                let labels = ["no_pending_login": "当前没有等待验证码的登录", "unrecognized_code": "未识别到验证码", "sms_already_pending": "当前登录已有待处理短信"]
                return .init(status: .ignored, detail: "ignored：" + (labels[reason] ?? "接收端忽略此短信"))
            default: return .init(status: .failed, detail: "vpn-manager 返回未知状态。")
            }
        case .webhook:
            if !channel.responseContains.isEmpty && !(String(data: response.data, encoding: .utf8) ?? "").contains(channel.responseContains) {
                return .init(status: .failed, detail: "HTTP \(code)，响应未包含配置的成功标记。")
            }
            return .init(status: .succeeded, detail: "HTTP \(code)")
        }
    }
}
