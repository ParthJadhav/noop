import XCTest
@testable import Strand
import StrandAnalytics

/// Locks the prefilled new-issue URL (spec section 5.2): it must bind bug_report.yml's existing
/// id fields (version/platform/os_version/test_profile/title) and self-apply the "bug,test:<id>"
/// labels, with every component percent-encoded. The repo is NoopApp/noop (bug_report.yml line 10).
final class TestReportLinkTests: XCTestCase {

    func testSleepProfileURLEncodesEveryFieldAndLabel() {
        let url = TestReportLink.reportURL(
            profile: .sleep, title: "no score last night",
            version: "7.3.0", platform: "iOS", osVersion: "18.5")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://github.com/NoopApp/noop/issues/new?"))
        XCTAssertTrue(s.contains("template=bug_report.yml"))
        // Label component: "bug,test:sleep" with the comma percent-encoded.
        XCTAssertTrue(s.contains("labels=bug%2Ctest:sleep"))
        XCTAssertTrue(s.contains("version=7.3.0"))
        XCTAssertTrue(s.contains("platform=iOS"))
        XCTAssertTrue(s.contains("os_version=18.5"))
        XCTAssertTrue(s.contains("test_profile=sleep"))
        // Title is "[sleep] no score last night", brackets and spaces percent-encoded.
        XCTAssertTrue(s.contains("title=%5Bsleep%5D%20no%20score%20last%20night"))
    }

    func testDataImportProfileUsesImportWireIdNotRawValue() {
        // The dataImport case maps to the wire id "import" (TestDomain contract); the URL must
        // carry test_profile=import and labels=bug,test:import, never "dataImport".
        let url = TestReportLink.reportURL(
            profile: .dataImport, title: "x", version: "7.3.0", platform: "Android", osVersion: "15")
        let s = url!.absoluteString
        XCTAssertTrue(s.contains("test_profile=import"))
        XCTAssertTrue(s.contains("labels=bug%2Ctest:import"))
    }

    func testMasterProfileLabelIsTestAll() {
        let url = TestReportLink.reportURL(
            profile: .master, title: "x", version: "7.3.0", platform: "macOS", osVersion: "14.5")
        XCTAssertTrue(url!.absoluteString.contains("labels=bug%2Ctest:all"))
    }

    // MARK: - CAPTURE-A (#812): prefill log + what_happens so a no-attachment report isn't empty

    func testNoReportTextOmitsLogAndWhatHappensParams() {
        // The legacy 5-field call (no reportText / seed) must compose the SAME URL as before , no log=,
        // no what_happens= , so existing callers are unchanged.
        let url = TestReportLink.reportURL(
            profile: .sleep, title: "x", version: "7.3.0", platform: "iOS", osVersion: "18.5")
        let s = url!.absoluteString
        XCTAssertFalse(s.contains("&log="))
        XCTAssertFalse(s.contains("what_happens="))
    }

    func testReportTextPrefillsLogFieldWithDetailsTail() {
        // A report.txt tail is wrapped in a <details> block and bound to the form's `log` id.
        let report = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let url = TestReportLink.reportURL(
            profile: .sleep, title: "no score", version: "7.3.0", platform: "iOS", osVersion: "18.5",
            reportText: report, whatHappensSeed: "Saw no recovery score this morning")
        let s = url!.absoluteString
        // The field id is exactly `log` (bug_report.yml id: log) and `what_happens` (id: what_happens).
        XCTAssertTrue(s.contains("&log="))
        XCTAssertTrue(s.contains("what_happens="))
        // The <details> wrapper and a recent line are present (percent-encoded). The tail is the LAST
        // logTailLines, so the newest line is in and line 1 is out.
        let decoded = url!.absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(decoded.contains("<details>"))
        XCTAssertTrue(decoded.contains("line 200"))
        XCTAssertFalse(decoded.contains("line 1\n"))      // line 1 trimmed off the log tail
        XCTAssertTrue(decoded.contains("Saw no recovery score this morning"))
        // No em-dash leaks into the composed URL (hard rule).
        XCTAssertFalse(decoded.contains("\u{2014}"))
    }

    func testOversizedLogIsDroppedNotTruncated() {
        // M2 (#812): a tail so long the URL would breach maxURLLength must DROP the log param entirely
        // (never a truncated <details>), while keeping the short id fields + what_happens seed so the
        // submitted body is still non-empty. The full trace travels in the attached .zip, not the URL.
        let huge = (1...TestReportLink.logTailLines).map { _ in String(repeating: "x", count: 500) }
            .joined(separator: "\n")
        let url = TestReportLink.reportURL(
            profile: .sleep, title: "x", version: "7.3.0", platform: "iOS", osVersion: "18.5",
            reportText: huge, whatHappensSeed: "it broke")
        let s = url!.absoluteString
        XCTAssertFalse(s.contains("&log="))                              // dropped, not truncated
        XCTAssertTrue(s.contains("what_happens="))                       // seed kept, body still non-empty
        XCTAssertLessThanOrEqual(s.count, TestReportLink.maxURLLength)   // under the GitHub prefill ceiling
    }

    func testLogDetailsBlockEmptyTextYieldsNil() {
        XCTAssertNil(TestReportLink.logDetailsBlock(reportText: ""))
        XCTAssertNil(TestReportLink.logDetailsBlock(reportText: "\n\n   \n"))
        // A blank report contributes NO log param (the URL still forms from the required fields).
        let url = TestReportLink.reportURL(
            profile: .sleep, title: "x", version: "7.3.0", platform: "iOS", osVersion: "18.5",
            reportText: "   \n  ")
        XCTAssertFalse(url!.absoluteString.contains("&log="))
    }

    func testWhatHappensSeedJoinsAnsweredPromptsInOrder() {
        let qs = [
            Question(id: "q1", prompt: "Which screen", kind: .text),
            Question(id: "q2", prompt: "Did it recover", kind: .yesNo),
            Question(id: "q3", prompt: "Unanswered", kind: .text),
        ]
        let seed = TestReportLink.whatHappensSeed(
            questionnaire: qs, answers: ["q1": "Sleep tab", "q2": "No", "q3": "  "])
        XCTAssertEqual(seed, "Which screen: Sleep tab\nDid it recover: No")   // q3 blank → skipped, order kept
        XCTAssertNil(TestReportLink.whatHappensSeed(questionnaire: qs, answers: [:]))
    }
}
