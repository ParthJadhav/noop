import XCTest
@testable import StrandAnalytics

/// Pins the exact line shapes the Display & Performance test mode emits and the readout parsers that read
/// them back, so a shared report reads identically on iOS, macOS and Android (the Kotlin DisplayTraceTest
/// pins the same shapes). Pure: no display link, no platform read, no clock.
final class DisplayTraceTests: XCTestCase {

    private func sampleMetrics() -> DisplayMetrics {
        DisplayMetrics(
            horizontalSizeClass: "compact", verticalSizeClass: "regular",
            widthPt: 390, heightPt: 844, scale: 3.0,
            safeTop: 47, safeBottom: 34, safeLeading: 0, safeTrailing: 0,
            dynamicType: "L", orientation: "portrait", theme: "dark")
    }

    func testDeviceMetricsLineShape() {
        let line = DisplayTrace.deviceMetricsLine(sampleMetrics())
        XCTAssertEqual(line,
            "deviceMetrics size=390x844pt @3.0x sizeClass=compact/regular "
            + "safeArea=t47 b34 l0 r0 dynamicType=L orientation=portrait theme=dark")
    }

    func testDeviceMetricsLineDegradesNilsToNa() {
        // macOS has no size class / Dynamic Type: a nil must print "n/a", never a fabricated value.
        let m = DisplayMetrics(
            horizontalSizeClass: nil, verticalSizeClass: nil,
            widthPt: 1440, heightPt: 900, scale: 2.0,
            safeTop: 0, safeBottom: 0, safeLeading: 0, safeTrailing: 0,
            dynamicType: nil, orientation: "landscape", theme: "light")
        let line = DisplayTrace.deviceMetricsLine(m)
        XCTAssertEqual(line,
            "deviceMetrics size=1440x900pt @2.0x sizeClass=n/a/n/a "
            + "safeArea=t0 b0 l0 r0 dynamicType=n/a orientation=landscape theme=light")
    }

    func testScaleUnknownPrintsQuestionMark() {
        var m = sampleMetrics()
        m = DisplayMetrics(
            horizontalSizeClass: m.horizontalSizeClass, verticalSizeClass: m.verticalSizeClass,
            widthPt: m.widthPt, heightPt: m.heightPt, scale: 0,
            safeTop: m.safeTop, safeBottom: m.safeBottom, safeLeading: m.safeLeading, safeTrailing: m.safeTrailing,
            dynamicType: m.dynamicType, orientation: m.orientation, theme: m.theme)
        XCTAssertTrue(DisplayTrace.deviceMetricsLine(m).contains("@?x"))
    }

    func testFrameSummaryLineShape() {
        let line = DisplayTrace.frameSummaryLine(
            frames: 60, meanMs: 16.71, p95Ms: 18.4, hitches: 2, worstMs: 41.93, hitchThresholdMs: 33)
        XCTAssertEqual(line,
            "frameSummary frames=60 mean=16.7ms p95=18.4ms hitches=2 worst=41.9ms threshold=33.0ms")
    }

    func testMemoryHighWaterLineShape() {
        // 187.46 is unambiguously above .45 in IEEE 754 (187.45 stores as 187.4499... and rounds DOWN),
        // so %.1f gives 187.5 identically on Swift and Kotlin. The input is chosen to exercise round-up at
        // the second decimal without depending on round-half-even of a non-representable .45.
        XCTAssertEqual(DisplayTrace.memoryHighWaterLine(peakMB: 187.46),
                       "memoryHighWater peak=187.5MB")
    }

    // MARK: - CAPTURE-D (#797): dataVolume line

    func testDataVolumeLineShape() {
        let line = DisplayTrace.dataVolumeLine(
            DataVolume(dbRows: 1_240_000, importedDays: 365, workouts: 42, lastRenderRows: 412))
        XCTAssertEqual(line,
            "dataVolume dbRows=1240000 importedDays=365 workouts=42 lastRenderRows=412")
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    func testDataVolumeLineNilLastRenderPrintsNa() {
        // No render measured yet → "n/a", never a fabricated 0.
        let line = DisplayTrace.dataVolumeLine(
            DataVolume(dbRows: 0, importedDays: 0, workouts: 0, lastRenderRows: nil))
        XCTAssertEqual(line, "dataVolume dbRows=0 importedDays=0 workouts=0 lastRenderRows=n/a")
    }

    func testReadoutParsesLatestDeviceMetrics() {
        let tail = [
            "[display] deviceMetrics size=320x568pt @2.0x sizeClass=compact/compact safeArea=t0 b0 l0 r0 dynamicType=M orientation=portrait theme=light",
            "[display] frameSummary frames=60 mean=16.7ms p95=18.4ms hitches=0 worst=20.1ms threshold=33.0ms",
            "[display] deviceMetrics size=390x844pt @3.0x sizeClass=compact/regular safeArea=t47 b34 l0 r0 dynamicType=L orientation=portrait theme=dark",
        ]
        XCTAssertEqual(DisplayReadout.deviceMetricsNow(taggedTail: tail),
            "size=390x844pt @3.0x sizeClass=compact/regular safeArea=t47 b34 l0 r0 dynamicType=L orientation=portrait theme=dark")
        XCTAssertEqual(DisplayReadout.frameSummaryNow(taggedTail: tail),
            "frames=60 mean=16.7ms p95=18.4ms hitches=0 worst=20.1ms threshold=33.0ms")
    }

    func testReadoutNilWhenNoLine() {
        XCTAssertNil(DisplayReadout.deviceMetricsNow(taggedTail: []))
        XCTAssertNil(DisplayReadout.frameSummaryNow(taggedTail: ["[display] deviceMetrics size=1x1pt @1.0x sizeClass=n/a/n/a safeArea=t0 b0 l0 r0 dynamicType=n/a orientation=portrait theme=light"]))
    }
}
