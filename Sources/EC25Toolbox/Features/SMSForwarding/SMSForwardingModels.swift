import Foundation

struct SMSForwardingMessage: Codable, Equatable, Sendable {
    var id: String
    var sender: String
    var body: String
    /// The modem's service timestamp (or the archive's original first-seen time).
    /// Never replace it with a retry time.
    var receivedAt: Date
    var moduleID: String
    var moduleName: String
    var simID: String
    var simName: String
    var componentIDs: [String]

    /// Incoming calls reuse the SMS job pipeline; the ID prefix marks them.
    var isCall: Bool { id.hasPrefix("call:") }

    static func call(epoch: Int, caller: String, at date: Date, moduleID: String, moduleName: String,
                     simID: String, simName: String) -> Self {
        Self(id: "call:\(moduleID):\(epoch):\(Int64(date.timeIntervalSince1970))", sender: caller, body: "来电",
             receivedAt: date, moduleID: moduleID, moduleName: moduleName, simID: simID, simName: simName, componentIDs: [])
    }

    static func sample(at date: Date = Date()) -> Self {
        Self(id: UUID().uuidString, sender: "EC25 Toolbox 测试", body: "【测试消息】短信转发配置测试。", receivedAt: date,
             moduleID: "test", moduleName: "测试模块", simID: "test", simName: "测试 SIM", componentIDs: [])
    }
}

enum SMSForwardingChannelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case feishu, webhook, vpnManager
    var id: String { rawValue }
    var title: String {
        switch self { case .feishu: "飞书群机器人"; case .webhook: "通用 Webhook"; case .vpnManager: "vpn-manager" }
    }
}
enum SMSForwardingHTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH"
    var id: String { rawValue }
}
enum SMSForwardingBodyFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case json, form, text
    var id: String { rawValue }
    var title: String { switch self { case .json: "JSON"; case .form: "表单"; case .text: "纯文本" } }
}

struct SMSForwardingChannel: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "新通道"
    var enabled = true
    var kind: SMSForwardingChannelKind = .feishu
    var method: SMSForwardingHTTPMethod = .post
    var bodyFormat: SMSForwardingBodyFormat = .json
    /// JSON/form templates are JSON objects with placeholders in string values.
    /// Substitution is structural, so SMS quotes/newlines cannot break JSON.
    var bodyTemplate = "{\"from\":\"${from}\",\"content\":\"${content}\",\"timestamp\":\"${timestamp}\"}"
    var titleTemplate = "${module}短信"
    var contentTemplate = "时间：${receive_time}\n来源：${from}\n\n${content}\n\n${module} · ${sim}"
    var responseContains = ""
}

/// Stored only in Keychain. URLs frequently contain a bot token; headers may
/// contain authorization, so neither belongs in the settings JSON or logs.
struct SMSForwardingSecrets: Codable, Equatable, Sendable {
    var endpoint = ""
    var signingSecret = ""
    var headers: [String: String] = [:]
}

struct SMSForwardingRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "新规则"
    var enabled = true
    var moduleID = ""
    var simID = ""
    var senderContains = ""
    /// One keyword per line, all required.
    var keywords = ""
    var pattern = ""
    var channelIDs: [UUID] = []

    func matches(_ message: SMSForwardingMessage) -> Bool {
        guard enabled,
              moduleID.isEmpty || moduleID == message.moduleID,
              simID.isEmpty || simID == message.simID,
              senderContains.isEmpty || message.sender.contains(senderContains) else { return false }
        let words = keywords.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard words.allSatisfy({ message.body.contains($0) }) else { return false }
        guard !pattern.isEmpty else { return true }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: message.body, range: NSRange(message.body.startIndex..., in: message.body)) != nil
    }
}

struct SMSForwardingConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var channels: [SMSForwardingChannel] = []
    var rules: [SMSForwardingRule] = []
}

enum SMSForwardingJobStatus: String, Codable, CaseIterable, Sendable {
    case queued, sending, retrying, succeeded, ignored, failed, expired, cancelled
    var isPending: Bool { self == .queued || self == .sending || self == .retrying }
    var title: String {
        switch self {
        case .queued: "等待发送"; case .sending: "发送中"; case .retrying: "等待重试"
        case .succeeded: "已发送"; case .ignored: "已忽略"; case .failed: "失败"
        case .expired: "已过期"; case .cancelled: "已取消"
        }
    }
}
struct SMSForwardingJob: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var channelID: UUID
    var channelName: String
    var message: SMSForwardingMessage
    var status: SMSForwardingJobStatus = .queued
    var attempts = 0
    var nextAttemptAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Bounded, credential-free status text. Never save arbitrary server bodies.
    var detail = "等待发送"
    var isTest = false
}

enum SMSForwardingError: LocalizedError {
    case invalid(String)
    case persistence
    case keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .persistence: "无法保存短信转发状态，已暂停发送。请检查本机存储。"
        case .keychain(let status): "无法访问短信转发凭据（Keychain 状态 \(status)）。"
        }
    }
}
