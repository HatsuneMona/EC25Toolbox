import SwiftUI

/// Shared settings for all modem sessions. Editors own a draft until Save;
/// opening a channel or rendering its preview never sends a request.
struct SMSForwardingSettingsView: View {
    @ObservedObject private var forwarding = SMSForwardingStore.shared
    @State private var section = ForwardingSection.channels
    @State private var channelDraft: ForwardingChannelDraft?
    @State private var ruleDraft: SMSForwardingRule?
    @State private var actionError: String?
    @State private var notice: String?
    @State private var visibleLogCount = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MacSettingsGroup("forwarding.general") {
                MacSettingsToggleRow(
                    title: "forwarding.enabled",
                    help: "forwarding.enabled.help",
                    isOn: Binding(
                        get: { forwarding.configuration.enabled },
                        set: { value in perform { try forwarding.setEnabled(value) } }
                    )
                )
            }

            if let error = actionError ?? forwarding.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(localized("forwarding.sections"), selection: $section) {
                ForEach(ForwardingSection.allCases) { item in
                    Text(localized(item.titleKey)).tag(item)
                }
            }
            .pickerStyle(.segmented)

            switch section {
            case .channels: channels
            case .rules: rules
            case .records: records
            }
        }
        .sheet(item: $channelDraft) { draft in
            ForwardingChannelEditor(channel: draft.channel, secrets: draft.secrets) { channel, secrets in
                try forwarding.saveChannel(channel, secrets: secrets)
            }
        }
        .sheet(item: $ruleDraft) { rule in
            ForwardingRuleEditor(rule: rule, channels: forwarding.configuration.channels) { rule in
                try forwarding.saveRule(rule)
            }
        }
    }

    private var channels: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localized("forwarding.channels.help"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu {
                    ForEach(SMSForwardingChannelKind.allCases, id: \.self) { kind in
                        Button(localized(kind.titleKey)) { newChannel(kind: kind) }
                    }
                } label: {
                    Label(localized("forwarding.channel.add"), systemImage: "plus")
                }
                .fixedSize()
            }
            if forwarding.configuration.channels.isEmpty {
                emptyState("forwarding.channels.empty", symbol: "arrowshape.turn.up.right")
            }
            ForEach(forwarding.configuration.channels) { channel in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(channel.name).font(.headline)
                                Text(localized(channel.kind.titleKey))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(localized(channel.enabled ? "forwarding.on" : "forwarding.off"))
                                .font(.caption).foregroundStyle(channel.enabled ? .primary : .secondary)
                        }
                        if channel.kind == .vpnManager {
                            Text(localized("forwarding.vpn.test.help"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        channelActions(channel)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func channelActions(_ channel: SMSForwardingChannel) -> some View {
        HStack(spacing: 8) {
            Button(localized("forwarding.edit")) {
                perform {
                    channelDraft = ForwardingChannelDraft(
                        channel: channel, secrets: try forwarding.secrets(for: channel.id)
                    )
                }
            }
            Button(localized("forwarding.test.send")) {
                perform {
                    try forwarding.testChannel(id: channel.id)
                    notice = localized("forwarding.test.queued")
                    section = .records
                }
            }
            .disabled(!channel.enabled)
            .help(localized(channel.kind == .vpnManager ? "forwarding.vpn.test.help" : "forwarding.test.help"))
            Spacer(minLength: 0)
            Button(role: .destructive) {
                perform { try forwarding.deleteChannel(id: channel.id) }
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel(localized("forwarding.channel.delete"))
            .help(localized("forwarding.channel.delete"))
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(localized("forwarding.rules.help"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    var rule = SMSForwardingRule()
                    rule.name = localized("forwarding.rule.newName")
                    ruleDraft = rule
                } label: {
                    Label(localized("forwarding.rule.add"), systemImage: "plus")
                }
                .fixedSize()
                .disabled(forwarding.configuration.channels.isEmpty)
            }
            if forwarding.configuration.rules.isEmpty {
                emptyState("forwarding.rules.empty", symbol: "line.3.horizontal.decrease.circle")
            }
            ForEach(forwarding.configuration.rules) { rule in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(rule.name).font(.headline)
                            Spacer(minLength: 8)
                            Text(localized(rule.enabled ? "forwarding.on" : "forwarding.off"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(ruleSummary(rule)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(channelNames(for: rule)).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(localized("forwarding.edit")) { ruleDraft = rule }
                            Spacer()
                            Button(role: .destructive) {
                                perform { try forwarding.deleteRule(id: rule.id) }
                            } label: { Image(systemName: "trash") }
                            .accessibilityLabel(localized("forwarding.rule.delete"))
                            .help(localized("forwarding.rule.delete"))
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("forwarding.records.help"))
                .font(.caption).foregroundStyle(.secondary)
            if forwarding.jobs.isEmpty {
                emptyState("forwarding.records.empty", symbol: "clock")
            }
            ForEach(Array(forwarding.jobs.sorted { $0.createdAt > $1.createdAt }.prefix(visibleLogCount))) { job in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.channelName).font(.headline)
                                Text(job.createdAt, style: .date)
                                    + Text(" ") + Text(job.createdAt, style: .time)
                            }
                            .font(.caption)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(localized(job.status.titleKey))
                                    .foregroundStyle(job.status.tint)
                                if job.isTest {
                                    Text(localized("forwarding.test.badge"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(job.detail).font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let next = job.nextAttemptAt, job.status == .retrying {
                            HStack {
                                Text(localized("forwarding.records.next"))
                                Text(next, style: .time)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup(localized("forwarding.records.details")) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(localized("forwarding.sender") + ": " + job.message.sender)
                                Text(localized("forwarding.module") + ": " + job.message.moduleName)
                                Text("SIM: " + job.message.simName)
                                Text(localized("forwarding.records.attempts") + ": " + String(job.attempts))
                                Text(job.message.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 5)
                        }
                        if job.status == .failed || job.status == .cancelled {
                            Button(localized("forwarding.retry")) {
                                perform { try forwarding.retry(jobID: job.id) }
                            }
                            .disabled(!forwarding.configuration.enabled && !job.isTest)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if forwarding.jobs.count > visibleLogCount {
                Button(localized("forwarding.records.more")) { visibleLogCount += 100 }
            }
        }
    }

    private func newChannel(kind: SMSForwardingChannelKind) {
        var channel = SMSForwardingChannel()
        channel.kind = kind
        channel.name = localized(kind.titleKey)
        let secrets = SMSForwardingSecrets()
        channelDraft = ForwardingChannelDraft(channel: channel, secrets: secrets)
    }

    private func channelNames(for rule: SMSForwardingRule) -> String {
        let names = forwarding.configuration.channels
            .filter { rule.channelIDs.contains($0.id) }.map(\.name)
        return localized("forwarding.rule.targets") + ": " + names.joined(separator: "、")
    }

    private func ruleSummary(_ rule: SMSForwardingRule) -> String {
        var parts: [String] = []
        if !rule.moduleID.isEmpty { parts.append(localized("forwarding.module") + ": " + rule.moduleID) }
        if !rule.simID.isEmpty { parts.append("SIM: " + rule.simID) }
        if !rule.senderContains.isEmpty { parts.append(localized("forwarding.sender") + ": " + rule.senderContains) }
        if !rule.keywords.isEmpty { parts.append(localized("forwarding.keywords") + ": " + rule.keywords.replacingOccurrences(of: "\n", with: "、")) }
        if !rule.pattern.isEmpty { parts.append(localized("forwarding.regex") + ": " + rule.pattern) }
        return parts.isEmpty ? localized("forwarding.rules.all") : parts.joined(separator: " · ")
    }

    private func perform(_ operation: () throws -> Void) {
        actionError = nil
        notice = nil
        do { try operation() } catch { actionError = error.localizedDescription }
    }

    private func emptyState(_ key: String, symbol: String) -> some View {
        Label(localized(key), systemImage: symbol)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
    }
}

private enum ForwardingSection: String, CaseIterable, Identifiable {
    case channels, rules, records
    var id: Self { self }
    var titleKey: String { "forwarding.section.\(rawValue)" }
}

private struct ForwardingChannelDraft: Identifiable {
    var channel: SMSForwardingChannel
    var secrets: SMSForwardingSecrets
    var id: UUID { channel.id }
}

private struct ForwardingChannelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var channel: SMSForwardingChannel
    @State private var endpoint: String
    @State private var signingSecret: String
    @State private var headersJSON: String
    @State private var showEndpoint = false
    @State private var preview: String?
    @State private var error: String?
    let save: (SMSForwardingChannel, SMSForwardingSecrets) throws -> Void

    init(channel: SMSForwardingChannel, secrets: SMSForwardingSecrets,
         save: @escaping (SMSForwardingChannel, SMSForwardingSecrets) throws -> Void) {
        _channel = State(initialValue: channel)
        _endpoint = State(initialValue: secrets.endpoint)
        _signingSecret = State(initialValue: secrets.signingSecret)
        let data = try? JSONSerialization.data(withJSONObject: secrets.headers, options: [.prettyPrinted, .sortedKeys])
        _headersJSON = State(initialValue: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("forwarding.channel.editor")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    field("forwarding.name", text: $channel.name)
                    Toggle(localized("forwarding.channel.enabled"), isOn: $channel.enabled)
                    Picker(localized("forwarding.channel.kind"), selection: $channel.kind) {
                        ForEach(SMSForwardingChannelKind.allCases, id: \.self) { kind in
                            Text(localized(kind.titleKey)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localized("forwarding.endpoint")).font(.headline)
                        if showEndpoint {
                            TextField("https://…", text: $endpoint).textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("https://…", text: $endpoint).textFieldStyle(.roundedBorder)
                        }
                        Toggle(localized("forwarding.endpoint.show"), isOn: $showEndpoint)
                            .font(.caption)
                    }
                    if channel.kind == .feishu {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(localized("forwarding.signingSecret")).font(.headline)
                            SecureField(localized("forwarding.optional"), text: $signingSecret)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("forwarding.titleTemplate", text: $channel.titleTemplate)
                        editor("forwarding.contentTemplate", text: $channel.contentTemplate, height: 100)
                        templateHelp
                    } else if channel.kind == .webhook {
                        HStack(spacing: 18) {
                            Picker(localized("forwarding.method"), selection: $channel.method) {
                                ForEach(SMSForwardingHTTPMethod.allCases, id: \.self) { method in
                                    Text(method.rawValue.uppercased()).tag(method)
                                }
                            }
                            Picker(localized("forwarding.bodyFormat"), selection: $channel.bodyFormat) {
                                ForEach(SMSForwardingBodyFormat.allCases, id: \.self) { format in
                                    Text(localized(format.titleKey)).tag(format)
                                }
                            }
                        }
                        editor("forwarding.bodyTemplate", text: $channel.bodyTemplate, height: 130)
                        templateHelp
                        Text(localized("forwarding.bodyTemplate.help"))
                            .font(.caption).foregroundStyle(.secondary)
                        field("forwarding.responseContains", text: $channel.responseContains)
                        Text(localized("forwarding.responseContains.help"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(localized("forwarding.vpn.help"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    editor("forwarding.headers", text: $headersJSON, height: 80)
                    Text(localized("forwarding.headers.help"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(localized("forwarding.preview")) {
                        perform {
                            preview = try SMSForwardingStore.shared.preview(channel: channel, secrets: makeSecrets())
                        }
                    }
                    if let preview {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(localized("forwarding.preview.title")).font(.headline)
                            Text(preview).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(localized("forwarding.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(localized("forwarding.save")) {
                    perform {
                        try save(channel, makeSecrets())
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: 680, minHeight: 440, idealHeight: 650, maxHeight: 800)
    }

    private var templateHelp: some View {
        Text(localized("forwarding.template.help"))
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func makeSecrets() throws -> SMSForwardingSecrets {
        let raw = headersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = (raw.isEmpty ? "{}" : raw).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let headers = object as? [String: String] else {
            throw ForwardingEditorError.invalidHeaders
        }
        var secrets = SMSForwardingSecrets()
        secrets.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.signingSecret = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.headers = headers
        return secrets
    }

    private func perform(_ operation: () throws -> Void) {
        error = nil
        do { try operation() } catch { self.error = error.localizedDescription }
    }

    private func field(_ key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(key)).font(.headline)
            TextField("", text: text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(localized(key))
        }
    }

    private func editor(_ key: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(key)).font(.headline)
            TextEditor(text: text).font(.system(.callout, design: .monospaced))
                .frame(minHeight: height)
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel(localized(key))
        }
    }
}

private struct ForwardingRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modem: ModemStore
    @State private var rule: SMSForwardingRule
    @State private var error: String?
    let channels: [SMSForwardingChannel]
    let save: (SMSForwardingRule) throws -> Void

    init(rule: SMSForwardingRule, channels: [SMSForwardingChannel],
         save: @escaping (SMSForwardingRule) throws -> Void) {
        _rule = State(initialValue: rule)
        self.channels = channels
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("forwarding.rule.editor")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    field("forwarding.name", text: $rule.name)
                    Toggle(localized("forwarding.rule.enabled"), isOn: $rule.enabled)
                    Text(localized("forwarding.rule.filters.help"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    field("forwarding.module.filter", text: $rule.moduleID)
                    Button(localized("forwarding.module.useCurrent")) {
                        rule.moduleID = modem.moduleSerialNumber ?? modem.moduleIdentifier
                    }
                    .help(modem.moduleDisplayName)
                    field("forwarding.sim.filter", text: $rule.simID)
                    Button(localized("forwarding.sim.useCurrent")) {
                        rule.simID = modem.currentSIMMessageScope().iccid ?? ""
                    }
                    .disabled(modem.currentSIMMessageScope().iccid == nil)
                    field("forwarding.sender.filter", text: $rule.senderContains)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localized("forwarding.keywords")).font(.headline)
                        TextEditor(text: $rule.keywords).font(.body)
                            .frame(minHeight: 65).padding(5)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .accessibilityLabel(localized("forwarding.keywords"))
                        Text(localized("forwarding.keywords.help"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    field("forwarding.regex", text: $rule.pattern)
                    Text(localized("forwarding.regex.help"))
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(localized("forwarding.rule.targets")).font(.headline)
                    ForEach(channels) { channel in
                        Toggle(isOn: Binding(
                            get: { rule.channelIDs.contains(channel.id) },
                            set: { selected in
                                if selected {
                                    if !rule.channelIDs.contains(channel.id) { rule.channelIDs.append(channel.id) }
                                } else { rule.channelIDs.removeAll { $0 == channel.id } }
                            }
                        )) {
                            HStack {
                                Text(channel.name)
                                if !channel.enabled {
                                    Text(localized("forwarding.off")).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.trailing, 6)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(localized("forwarding.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(localized("forwarding.save")) {
                    do {
                        try save(rule)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 680, minHeight: 440, idealHeight: 650, maxHeight: 800)
    }

    private func field(_ key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(key)).font(.headline)
            TextField(key == "forwarding.name" ? "" : localized("forwarding.optional"), text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(localized(key))
        }
    }
}

private enum ForwardingEditorError: LocalizedError {
    case invalidHeaders
    var errorDescription: String? { localized("forwarding.headers.invalid") }
}

private extension SMSForwardingChannelKind {
    var titleKey: String {
        switch self {
        case .feishu: "forwarding.kind.feishu"
        case .webhook: "forwarding.kind.webhook"
        case .vpnManager: "forwarding.kind.vpnManager"
        }
    }
}

private extension SMSForwardingBodyFormat {
    var titleKey: String {
        switch self {
        case .json: "forwarding.format.json"
        case .form: "forwarding.format.form"
        case .text: "forwarding.format.text"
        }
    }
}

private extension SMSForwardingJobStatus {
    var titleKey: String { "forwarding.status.\(rawValue)" }
    var tint: Color {
        switch self {
        case .succeeded: .green
        case .failed, .expired: .red
        case .queued, .sending, .retrying: .orange
        case .ignored, .cancelled: .secondary
        }
    }
}
