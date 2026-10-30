import Combine
import Foundation

private struct SMSForwardingDocument: Codable {
    var schemaVersion = 1
    var configuration = SMSForwardingConfiguration()
    var jobs: [SMSForwardingJob] = []
    var baselineScopes: Set<String> = []
    var seenMessages: Set<String> = []
    var blockedComponents: [String: Set<String>] = [:]
}

/// One app-wide durable outbox, shared by all modem sessions and settings views.
/// Archive synchronization calls ingest only after its own durable write succeeds.
@MainActor
final class SMSForwardingStore: ObservableObject {
    static let shared = SMSForwardingStore()
    @Published private(set) var configuration = SMSForwardingConfiguration()
    @Published private(set) var jobs: [SMSForwardingJob] = []
    @Published private(set) var lastError: String?
    @Published private(set) var baselineStatus = "启用后等待设备完成短信同步，建立历史短信基线。"

    private var document = SMSForwardingDocument()
    private let fileURL: URL
    private let secretStorage: any SMSForwardingSecretStorage
    private let transport: any SMSForwardingTransport
    private let now: () -> Date
    private let autoStart: Bool
    private var storageHealthy = true
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var workerSleeping = false
    private var activeChannelID: UUID?
    private static let retryDelays: [TimeInterval] = [5, 30, 120]

    init(directory: URL? = nil, secretStorage: (any SMSForwardingSecretStorage)? = nil,
         transport: any SMSForwardingTransport = SMSForwardingURLTransport(),
         now: @escaping () -> Date = Date.init, autoStart: Bool = true) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EC25 Toolbox/SMSForwarding", isDirectory: true)
        self.fileURL = base.appendingPathComponent("forwarding-v1.json")
        self.secretStorage = secretStorage ?? SMSForwardingFileSecrets(directory: base)
        self.transport = transport
        self.now = now
        self.autoStart = autoStart
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let loaded = try JSONDecoder().decode(SMSForwardingDocument.self, from: Data(contentsOf: fileURL))
                guard loaded.schemaVersion == 1 else { throw SMSForwardingError.persistence }
                document = loaded
                // At-least-once transport: an interrupted request may have reached
                // its receiver. Keep the same SMS timestamp and durable job ID.
                for index in document.jobs.indices where document.jobs[index].status == .sending {
                    document.jobs[index].status = .queued
                    document.jobs[index].nextAttemptAt = now()
                    document.jobs[index].detail = "上次发送中断，等待恢复"
                }
                configuration = document.configuration
                jobs = document.jobs
            } catch {
                storageHealthy = false
                lastError = "短信转发状态文件无法读取，已暂停发送；原文件保留。"
            }
        }
        // Copy any pre-file credentials now, while the user is at the keyboard.
        if autoStart { for channel in configuration.channels { _ = try? self.secretStorage.read(id: channel.id) } }
        kick()
    }

    var allowsModemCleanup: Bool { storageHealthy }

    func secrets(for id: UUID) throws -> SMSForwardingSecrets { try secretStorage.read(id: id) }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != configuration.enabled else { return }
        try change { next in
            next.configuration.enabled = enabled
            // Re-enabling deliberately takes a fresh device baseline. Messages
            // received while disabled cannot become an accidental backlog.
            next.baselineScopes.removeAll()
            next.blockedComponents.removeAll()
            if !enabled { Self.cancelPending(&next, detail: "转发已关闭") }
        }
        baselineStatus = enabled ? "等待设备完成短信同步，建立历史短信基线。" : "短信转发已关闭。"
        if !enabled { stopWorker() }
        kick()
    }

    func saveChannel(_ channel: SMSForwardingChannel, secrets: SMSForwardingSecrets) throws {
        try SMSForwardingSender.validate(channel: channel, secrets: secrets)
        let oldSecret = try secretStorage.read(id: channel.id)
        try secretStorage.save(secrets, id: channel.id)
        do {
            try change { next in
                if let index = next.configuration.channels.firstIndex(where: { $0.id == channel.id }) {
                    next.configuration.channels[index] = channel
                    // Do not send an old queued SMS to a newly edited destination.
                    Self.cancelPending(&next, channelID: channel.id, detail: "通道配置已修改，请按需手动重试")
                } else { next.configuration.channels.append(channel) }
            }
        } catch {
            try? secretStorage.save(oldSecret, id: channel.id)
            throw error
        }
        if activeChannelID == channel.id { stopWorker() }
        kick()
    }

    func deleteChannel(id: UUID) throws {
        try change { next in
            next.configuration.channels.removeAll { $0.id == id }
            for index in next.configuration.rules.indices { next.configuration.rules[index].channelIDs.removeAll { $0 == id } }
            Self.cancelPending(&next, channelID: id, detail: "通道已删除")
        }
        if activeChannelID == id { stopWorker() }
        kick()
        try secretStorage.delete(id: id)
    }

    func saveRule(_ rule: SMSForwardingRule) throws {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SMSForwardingError.invalid("请输入规则名称。") }
        if !rule.pattern.isEmpty {
            guard (try? NSRegularExpression(pattern: rule.pattern)) != nil else { throw SMSForwardingError.invalid("正文正则表达式无效。") }
        }
        guard !rule.channelIDs.isEmpty else { throw SMSForwardingError.invalid("请至少选择一个转发通道。") }
        let available = Set(configuration.channels.map(\.id))
        guard Set(rule.channelIDs).isSubset(of: available) else { throw SMSForwardingError.invalid("规则包含已删除的通道，请重新选择。") }
        try change { next in
            if let index = next.configuration.rules.firstIndex(where: { $0.id == rule.id }) { next.configuration.rules[index] = rule }
            else { next.configuration.rules.append(rule) }
        }
    }

    func deleteRule(id: UUID) throws {
        try change { $0.configuration.rules.removeAll { $0.id == id } }
    }

    func preview(channel: SMSForwardingChannel, secrets: SMSForwardingSecrets,
                 message: SMSForwardingMessage = .sample()) throws -> String {
        try SMSForwardingSender.preview(channel: channel, secrets: secrets, message: message)
    }

    func testChannel(id: UUID) throws {
        guard let channel = configuration.channels.first(where: { $0.id == id }), channel.enabled else {
            throw SMSForwardingError.invalid("请先保存并启用通道。")
        }
        try SMSForwardingSender.validate(channel: channel, secrets: secretStorage.read(id: id))
        let date = now()
        try change { next in
            next.jobs.append(SMSForwardingJob(channelID: id, channelName: channel.name, message: .sample(at: date), createdAt: date, updatedAt: date, isTest: true))
        }
        kick()
    }

    func retry(jobID: UUID) throws {
        guard let job = document.jobs.first(where: { $0.id == jobID }), !job.status.isPending else { return }
        guard let channel = configuration.channels.first(where: { $0.id == job.channelID }), channel.enabled else {
            throw SMSForwardingError.invalid("目标通道不存在或已关闭。")
        }
        guard configuration.enabled || job.isTest else { throw SMSForwardingError.invalid("请先启用短信转发。") }
        if channel.kind == .vpnManager, let expiry = vpnExpiry(job.message) { throw SMSForwardingError.invalid(expiry.detail) }
        try change { next in
            guard let index = next.jobs.firstIndex(where: { $0.id == jobID }) else { return }
            next.jobs[index].status = .queued
            next.jobs[index].attempts = 0
            next.jobs[index].nextAttemptAt = now()
            next.jobs[index].updatedAt = now()
            next.jobs[index].detail = "等待手动重试"
        }
        kick()
    }

    /// Only physically observed, fully assembled incoming messages belong here.
    /// observedComponentIDs includes pending fragments, so historical partial
    /// messages present at first enable do not escape the no-backfill baseline.
    func ingest(messages: [SMSForwardingMessage], observedComponentIDs: Set<String>,
                moduleID: String, simID: String, isCompleteSnapshot: Bool) {
        guard configuration.enabled, storageHealthy, !simID.isEmpty else { return }
        let scope = moduleID + "|" + simID
        do {
            if !document.baselineScopes.contains(scope) {
                guard isCompleteSnapshot else {
                    baselineStatus = "等待设备完成 ME/SM 短信同步后建立基线。"
                    return
                }
                try change { next in
                    next.baselineScopes.insert(scope)
                    next.blockedComponents[scope] = observedComponentIDs
                    for message in messages { next.seenMessages.insert(scope + "|" + message.id) }
                }
                baselineStatus = "已建立短信基线，等待新短信。"
                return
            }
            let date = now()
            try change { next in
                for message in messages {
                    guard message.moduleID == moduleID, message.simID == simID else { continue }
                    let key = scope + "|" + message.id
                    guard next.seenMessages.insert(key).inserted else { continue }
                    guard Set(message.componentIDs).isDisjoint(with: next.blockedComponents[scope] ?? []) else { continue }
                    let matched = next.configuration.rules.filter { $0.matches(message) }
                    let targets = Set(matched.flatMap(\.channelIDs))
                    for channel in next.configuration.channels where channel.enabled && targets.contains(channel.id) {
                        next.jobs.append(SMSForwardingJob(channelID: channel.id, channelName: channel.name, message: message, createdAt: date, updatedAt: date))
                    }
                }
            }
            kick()
        } catch { lastError = error.localizedDescription }
    }

    /// Incoming calls go only to generic webhook channels (e.g. Bark) whose rules
    /// match; verification-code and chat-bot channels never receive call alerts.
    /// The message ID carries the call epoch, so a re-posted banner cannot duplicate.
    func ingestIncomingCall(caller: String, epoch: Int, moduleID: String, moduleName: String, simID: String, simName: String) {
        guard configuration.enabled, storageHealthy else { return }
        let date = now()
        let message = SMSForwardingMessage.call(epoch: epoch, caller: caller, at: date, moduleID: moduleID,
                                                moduleName: moduleName, simID: simID, simName: simName)
        do {
            try change { next in
                guard next.seenMessages.insert(moduleID + "|" + message.id).inserted else { return }
                let targets = Set(next.configuration.rules.filter { $0.matches(message) }.flatMap(\.channelIDs))
                for channel in next.configuration.channels where channel.enabled && channel.kind == .webhook && targets.contains(channel.id) {
                    next.jobs.append(SMSForwardingJob(channelID: channel.id, channelName: channel.name, message: message, createdAt: date, updatedAt: date))
                }
            }
            kick()
        } catch { lastError = error.localizedDescription }
    }

    private func vpnExpiry(_ message: SMSForwardingMessage) -> SMSForwardingOutcome? {
        let age = now().timeIntervalSince(message.receivedAt)
        if age > 180 { return .init(status: .expired, detail: "短信已超过 vpn-manager 的三分钟有效窗口。") }
        if age < -30 { return .init(status: .failed, detail: "短信时间超前超过 30 秒，请检查设备时间。") }
        return nil
    }

    private static func cancelPending(_ next: inout SMSForwardingDocument, channelID: UUID? = nil, detail: String) {
        for index in next.jobs.indices where next.jobs[index].status.isPending && (channelID == nil || next.jobs[index].channelID == channelID) {
            next.jobs[index].status = .cancelled
            next.jobs[index].detail = detail
            next.jobs[index].nextAttemptAt = nil
        }
    }

    private func change(_ edit: (inout SMSForwardingDocument) throws -> Void) throws {
        guard storageHealthy else { throw SMSForwardingError.persistence }
        var next = document
        try edit(&next)
        // Keep pending work plus the latest 1,000 completed entries. Durable
        // seen identities are retained independently, so pruning is not replay.
        let finished = next.jobs.filter { !$0.status.isPending }
        if finished.count > 1_000 {
            let removed = Set(finished.prefix(finished.count - 1_000).map(\.id))
            next.jobs.removeAll { removed.contains($0.id) }
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: fileURL, options: .atomic)
        } catch {
            lastError = SMSForwardingError.persistence.localizedDescription
            storageHealthy = false
            stopWorker()
            throw SMSForwardingError.persistence
        }
        document = next
        configuration = next.configuration
        jobs = next.jobs
        lastError = nil
    }

    private func stopWorker() {
        worker?.cancel()
        worker = nil
        workerID = nil
        workerSleeping = false
        activeChannelID = nil
    }
    private func kick() {
        if workerSleeping { stopWorker() }
        guard autoStart, storageHealthy, worker == nil,
              document.jobs.contains(where: { $0.status.isPending && (configuration.enabled || $0.isTest) }) else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            await self?.runLoop(id: id)
        }
    }
    private func runLoop(id: UUID) async {
        defer { if workerID == id { worker = nil; workerID = nil } }
        while !Task.isCancelled, workerID == id {
            if await processNextReady() { continue }
            let future = document.jobs.filter { $0.status.isPending && (configuration.enabled || $0.isTest) }.compactMap(\.nextAttemptAt).min()
            guard let date = future else { break }
            let delay = max(0.05, date.timeIntervalSince(now()))
            workerSleeping = true
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            workerSleeping = false
        }
    }

    /// Deterministic single-step pump for tests; production uses the worker loop.
    @discardableResult
    func processNextReady() async -> Bool {
        guard storageHealthy, !Task.isCancelled,
              let job = document.jobs.first(where: {
                  ($0.status == .queued || $0.status == .retrying) && (configuration.enabled || $0.isTest)
                    && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now())
              }) else { return false }
        guard let channel = configuration.channels.first(where: { $0.id == job.channelID }), channel.enabled else {
            return finish(jobID: job.id, outcome: .init(status: .cancelled, detail: "通道已关闭或删除"))
        }
        if channel.kind == .vpnManager, let expiry = vpnExpiry(job.message) { return finish(jobID: job.id, outcome: expiry) }
        if job.message.isCall, now().timeIntervalSince(job.message.receivedAt) > 90 {
            return finish(jobID: job.id, outcome: .init(status: .expired, detail: "来电提醒已超过 90 秒，不再补发。"))
        }
        // Initial send plus three retries. An interrupted fourth attempt cannot
        // silently gain another automatic delivery after restart.
        guard job.attempts < 4 else {
            return finish(jobID: job.id, outcome: .init(status: .failed, detail: "已达到最大自动发送次数，请检查记录后手动重试。"))
        }
        let request: URLRequest
        do {
            request = try SMSForwardingSender.request(channel: channel, secrets: secretStorage.read(id: channel.id), message: job.message, now: now())
            try change { next in
                guard let index = next.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                next.jobs[index].attempts += 1
                next.jobs[index].status = .sending
                next.jobs[index].nextAttemptAt = nil
                next.jobs[index].updatedAt = now()
                next.jobs[index].detail = "发送中"
            }
        } catch {
            // All validation/storage errors are locally generated and do not
            // include the endpoint, headers or a server-supplied response body.
            return finish(jobID: job.id, outcome: .init(status: .failed, detail: (error as? SMSForwardingError)?.localizedDescription ?? "通道配置无效。"))
        }
        let outcome: SMSForwardingOutcome
        activeChannelID = channel.id
        defer { if activeChannelID == channel.id { activeChannelID = nil } }
        do {
            outcome = SMSForwardingSender.outcome(channel: channel, response: try await transport.send(request))
        } catch {
            guard !Task.isCancelled else { return false }
            let network = error as? URLError
            let retryableCodes: Set<URLError.Code> = [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable]
            outcome = .init(status: .failed, detail: network == nil ? "发送失败，请检查通道配置。" : "网络请求失败（\(network!.code.rawValue)）", retryable: network.map { retryableCodes.contains($0.code) } ?? false)
        }
        guard !Task.isCancelled, document.jobs.first(where: { $0.id == job.id })?.status == .sending else { return false }
        return finish(jobID: job.id, outcome: outcome)
    }

    @discardableResult
    private func finish(jobID: UUID, outcome: SMSForwardingOutcome) -> Bool {
        do {
            try change { next in
                guard let index = next.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                let attempts = next.jobs[index].attempts
                let date = now()
                next.jobs[index].status = outcome.status
                next.jobs[index].detail = outcome.detail
                next.jobs[index].updatedAt = date
                next.jobs[index].nextAttemptAt = nil
                if outcome.retryable, attempts > 0, attempts <= Self.retryDelays.count {
                    let retryAt = date.addingTimeInterval(Self.retryDelays[attempts - 1])
                    let isVPN = next.configuration.channels.first(where: { $0.id == next.jobs[index].channelID })?.kind == .vpnManager
                    if isVPN && retryAt.timeIntervalSince(next.jobs[index].message.receivedAt) > 180 {
                        next.jobs[index].status = .expired
                        next.jobs[index].detail = "下一次重试将超出验证码有效窗口，已停止。"
                    } else {
                        next.jobs[index].status = .retrying
                        next.jobs[index].nextAttemptAt = retryAt
                    }
                }
            }
            return true
        } catch { return false }
    }
}
