// Minimal stand-ins for types that AudioDeviceModels.swift references.
struct AudioRoutePlan: Equatable, Sendable {}

enum CallPhase: String, Equatable, Sendable {
    case idle, incoming, answering, dialing, alerting, active, held, ending, ended, failed, missed
}
