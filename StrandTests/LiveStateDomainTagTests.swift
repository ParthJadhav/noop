import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class LiveStateDomainTagTests: XCTestCase {

    // No domain => byte-identical to today's behaviour (no tag prefix).
    func testNilDomainLeavesLineUntagged() {
        let live = LiveState()
        live.append(log: "connected ok")
        XCTAssertEqual(live.log.last, "connected ok")
    }

    // A domain => a compact, parseable "[<id>] " marker is prefixed.
    func testDomainPrefixesCompactMarker() {
        let live = LiveState()
        live.append(log: "gate run kept", domain: .sleep)
        XCTAssertEqual(live.log.last, "[sleep] gate run kept")
    }

    // dataImport uses the wire id, not the rawValue.
    func testDataImportUsesWireId() {
        let live = LiveState()
        live.append(log: "parsed 10 rows", domain: .dataImport)
        XCTAssertEqual(live.log.last, "[import] parsed 10 rows")
    }

    // Redaction STILL runs, and it runs over the already-tagged text (the serial in the body is masked,
    // the tag is untouched).
    func testRedactionRunsAfterTagging() {
        let live = LiveState()
        live.append(log: "saw WHOOP 4C1594026 advertise", domain: .connection)
        XCTAssertEqual(live.log.last, "[connection] saw WHOOP <serial> advertise")
    }
}
