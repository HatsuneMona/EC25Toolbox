import Foundation

/// Opt-in loopback control for an external SIP bridge.
///
/// Enable with `defaults write ing.fuyaoskyrocket.ec25toolbox localControlEnabled -bool YES`
/// (optional `localControlPort`, default 48561) and restart the app. The bearer
/// token lives in `Application Support/EC25 Toolbox/LocalControl/token`.
extension ModemStore {
    static let localControlDefaultPort = 48_561

    /// True while the loopback control is enabled: the external bridge then
    /// handles call audio. `localControlExternalAudio = NO` keeps Toolbox's own.
    var localControlOwnsCallAudio: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "localControlEnabled")
            && (defaults.object(forKey: "localControlExternalAudio") as? Bool ?? true)
    }

    func startLocalControlIfEnabled() {
        stopLocalControl()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "localControlEnabled") else { return }
        let port = defaults.object(forKey: "localControlPort") as? Int ?? Self.localControlDefaultPort
        do {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EC25 Toolbox/LocalControl", isDirectory: true)
            let token = try LocalControlToken.loadOrCreate(in: directory)
            let server = LocalControlServer(
                snapshot: { [weak self] in
                    await self?.localControlSnapshot() ?? .init(phase: "unavailable", number: nil, epoch: 0)
                },
                command: { [weak self] command, epoch in
                    await self?.localControlPerform(command, epoch: epoch) ?? .refused("unavailable")
                }
            )
            try server.start(port: port, token: token)
            localControlServer = server
            log("local control listening on 127.0.0.1:\(port)")
        } catch {
            log("local control failed: \(error.localizedDescription)")
        }
    }

    func stopLocalControl() {
        localControlServer?.stop()
        localControlServer = nil
    }

    func localControlSnapshot() -> LocalControlServer.Snapshot {
        .init(phase: callMachine.phase.rawValue, number: callMachine.number, epoch: callMachine.callEpoch)
    }

    /// Runs the same user actions as the call banner. An explicit `epoch`
    /// binds the command to one call so a late request cannot steer another.
    func localControlPerform(_ command: LocalControlServer.Command, epoch: Int?) -> LocalControlServer.Outcome {
        if let epoch, epoch != callMachine.callEpoch { return .refused("stale_epoch") }
        switch command {
        case .answer:
            guard callMachine.phase == .incoming else { return .refused("no_incoming_call") }
            answer()
        case let .dial(number):
            guard !callMachine.hasLiveCall else { return .refused("call_in_progress") }
            guard state.connected else { return .refused("modem_offline") }
            dial(number: number)
        case .hangUp:
            switch callMachine.phase {
            case .incoming:
                reject()
            case .dialing, .alerting, .answering, .active, .held:
                hangUp()
            default:
                return .refused("no_call")
            }
        }
        return .accepted
    }
}
