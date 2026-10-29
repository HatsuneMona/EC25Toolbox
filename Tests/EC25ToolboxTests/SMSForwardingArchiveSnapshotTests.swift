import Foundation
import XCTest
@testable import EC25Toolbox

final class SMSForwardingArchiveSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_972_800)
    private var scope: SIMMessageScope { SIMMessageScope(eid: nil, iccid: "898600123456") }

    private func segment(_ index: Int = 1, body: String = "验证码 001234", sequence: Int? = nil,
                         scope: SIMMessageScope? = nil) -> SMSTransportSegmentRecord {
        let scope = scope ?? self.scope
        return SMSTransportSegmentRecord(
            id: SMSLogicalIdentity.segmentID(scopeID: scope.id, storage: "ME", index: index),
            scopeID: scope.id, eid: scope.eid, iccid: scope.iccid,
            storage: "ME", index: index, status: "REC READ", outgoing: false, unread: false,
            peer: "106900", body: body, binaryKind: nil, rawPDU: nil,
            reference: sequence == nil ? nil : 7, total: sequence == nil ? nil : 2, sequence: sequence,
            rawServiceTimestamp: "26/10/26,10:00:00+32", instant: now,
            sourceTimeZoneOffsetSeconds: 28800, centuryAnchor: now,
            assembly: .pending, consumedByLogicalID: nil, presentOnModem: true,
            firstSeenAt: now, updatedAt: now
        )
    }
    private func live(_ segment: SMSTransportSegmentRecord) -> SMSSegment {
        SMSSegment(storage: segment.storage, index: segment.index, status: segment.status,
                   outgoing: segment.outgoing, unread: segment.unread, sender: segment.peer,
                   date: segment.rawServiceTimestamp ?? "", body: segment.body,
                   binaryKind: segment.binaryKind.flatMap(BinarySMSKind.init(rawValue:)),
                   concatenation: segment.reference.map {
                       SMSConcatenation(reference: UInt16($0), total: segment.total!, sequence: segment.sequence!)
                   }, rawPDU: nil)
    }
    private func snapshot(_ input: [SMSTransportSegmentRecord], live current: [SMSSegment]? = nil,
                          scope: SIMMessageScope? = nil, alter: ((inout [SMSLogicalRecord]) -> Void)? = nil
    ) -> SMSForwardingArchiveSnapshot {
        let scope = scope ?? self.scope
        let outcome = SMSLogicalAssembler.assemble(segments: input, scope: scope, now: now)
        var segments = input
        for i in segments.indices where outcome.consumedSegmentIDs.contains(segments[i].id) {
            segments[i].assembly = .consumed
        }
        var records = outcome.logicals
        alter?(&records)
        return SMSForwardingArchiveSnapshot.make(records: records, segments: segments,
            liveSegments: current ?? input.map(live), scope: scope, moduleID: "serial-A", moduleName: "EC20")
    }
    func testReadSMSStillProducesIncomingEvent() {
        let result = snapshot([segment()])
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages.first?.body, "验证码 001234")
        XCTAssertEqual(result.messages.first?.receivedAt, now)
        XCTAssertEqual(result.observedComponentIDs.count, 1)
    }
    func testPendingFragmentsAreObservedUntilComplete() {
        let first = segment(body: "中文长短信", sequence: 1)
        let second = segment(2, body: "验证码001234", sequence: 2)
        let pending = snapshot([first])
        XCTAssertTrue(pending.messages.isEmpty)
        XCTAssertEqual(pending.observedComponentIDs.count, 1)
        let complete = snapshot([first, second])
        XCTAssertEqual(complete.messages.first?.body, "中文长短信验证码001234")
        XCTAssertEqual(complete.messages.first?.componentIDs.count, 2)
        XCTAssertTrue(pending.observedComponentIDs.isSubset(of: complete.observedComponentIDs))
    }
    func testCloudOnlyMessagesDoNotProduceEvents() {
        XCTAssertTrue(snapshot([segment()], live: []).messages.isEmpty)
        let first = segment(body: "云端片段", sequence: 1)
        let second = segment(2, body: "本地片段", sequence: 2)
        XCTAssertTrue(snapshot([first, second], live: [live(second)]).messages.isEmpty)
    }
    func testSlotReuseRequiresMatchingContent() {
        let archived = segment(body: "旧验证码")
        let reused = segment(body: "新验证码")
        XCTAssertTrue(snapshot([archived], live: [live(reused)]).messages.isEmpty)
        XCTAssertNotEqual(snapshot([archived]).messages.first?.id, snapshot([reused]).messages.first?.id)
    }
    func testIdentitySurvivesScopeAndSlotMigration() {
        let original = snapshot([segment()])
        let newScope = SIMMessageScope(eid: "NEW-EID", iccid: scope.iccid)
        let migrated = snapshot([segment(9, scope: newScope)], scope: newScope)
        XCTAssertEqual(original.messages.first?.id, migrated.messages.first?.id)
        XCTAssertEqual(original.observedComponentIDs, migrated.observedComponentIDs)
    }
    func testOutboundBinaryAndLegacyAreExcluded() {
        var outgoing = segment(); outgoing.outgoing = true
        XCTAssertTrue(snapshot([outgoing]).messages.isEmpty)
        var binary = segment(); binary.binaryKind = BinarySMSKind.simOTA.rawValue
        XCTAssertTrue(snapshot([binary]).messages.isEmpty)
        XCTAssertTrue(snapshot([segment()], alter: { $0[0].isUnresolvedLegacy = true }).messages.isEmpty)
        XCTAssertTrue(snapshot([segment()], alter: { $0[0].deletedAt = self.now }).messages.isEmpty)
    }
    func testUnknownSIMCannotForward() {
        let unknown = SIMMessageScope(eid: nil, iccid: nil)
        XCTAssertTrue(snapshot([segment(scope: unknown)], scope: unknown).messages.isEmpty)
    }
    func testTimestampFallbackRemainsArchiveFirstSeen() {
        var entry = segment(); entry.instant = nil
        XCTAssertEqual(snapshot([entry]).messages.first?.receivedAt, now)
    }
}
