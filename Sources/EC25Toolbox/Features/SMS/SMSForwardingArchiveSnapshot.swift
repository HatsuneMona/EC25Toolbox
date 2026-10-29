import CryptoKit
import Foundation

/// Only a successful modem listing supplies this snapshot. Archive/cloud
/// projections by themselves must never become forwarding events.
struct SMSForwardingArchiveSnapshot {
    var messages: [SMSForwardingMessage]
    var observedComponentIDs: Set<String>

    static func make(
        records: [SMSLogicalRecord],
        segments: [SMSTransportSegmentRecord],
        liveSegments: [SMSSegment],
        scope: SIMMessageScope,
        moduleID: String,
        moduleName: String
    ) -> Self {
        guard let iccid = scope.iccid else {
            return Self(messages: [], observedComponentIDs: [])
        }
        // Match content as well as location: modem slots are reused, and a
        // cloud merge can contain an older segment at the same location.
        let liveByLocation = Dictionary(grouping: liveSegments) {
            SMSMessageLocation(storage: $0.storage, index: $0.index)
        }
        var verified: [String: SMSTransportSegmentRecord] = [:]
        for segment in segments where segment.scopeID == scope.id && !segment.outgoing {
            let location = SMSMessageLocation(storage: segment.storage, index: segment.index)
            guard liveByLocation[location]?.contains(where: { live in
                !live.outgoing && live.sender == segment.peer && live.body == segment.body
                    && live.date == (segment.rawServiceTimestamp ?? "")
                    && live.binaryKind?.rawValue == segment.binaryKind
                    && live.concatenation.map({ Int($0.reference) }) == segment.reference
                    && live.concatenation.map({ Int($0.total) }) == segment.total
                    && live.concatenation.map({ Int($0.sequence) }) == segment.sequence
            }) == true else { continue }
            verified[segment.id] = segment
        }
        let componentIDs = verified.mapValues { segment in
            digest([
                iccid, segment.peer, segment.rawServiceTimestamp ?? "", segment.body,
                segment.reference.map(String.init) ?? "",
                segment.total.map(String.init) ?? "",
                segment.sequence.map(String.init) ?? "",
                segment.binaryKind ?? ""
            ])
        }
        let messages = records.compactMap { record -> SMSForwardingMessage? in
            guard record.scopeID == scope.id, !record.outgoing, record.deletedAt == nil,
                  record.binaryKind == nil, record.isUnresolvedLegacy != true,
                  !record.segmentIDs.isEmpty,
                  record.segmentIDs.allSatisfy({ verified[$0]?.assembly == .consumed }),
                  record.origin == "ME" || record.origin == "SM"
            else { return nil }
            return SMSForwardingMessage(
                id: digest([iccid, record.peer, record.rawServiceTimestamp ?? "", record.body]),
                sender: record.peer,
                body: record.body,
                receivedAt: record.instant ?? record.firstSeenAt,
                moduleID: moduleID,
                moduleName: moduleName,
                simID: iccid,
                simName: "SIM …" + String(iccid.suffix(4)),
                componentIDs: record.segmentIDs.compactMap { componentIDs[$0] }
            )
        }
        return Self(messages: messages, observedComponentIDs: Set(componentIDs.values))
    }

    private static func digest(_ fields: [String]) -> String {
        // JSON keeps field boundaries unambiguous even when SMS text includes
        // separators, quotes or newlines.
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
