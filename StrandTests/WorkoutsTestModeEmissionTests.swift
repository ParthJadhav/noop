import XCTest
import CoreLocation
import StrandAnalytics
@testable import Strand

/// Proves the Workouts & GPS test mode (Test Centre) is GENUINELY zero-cost when off: the GPS-fix emitter in
/// GpsWorkoutRecorder is gated behind TestCentre.active(.workouts), so with the mode OFF an accepted fix
/// writes ZERO .workouts-tagged lines, and with it ON it writes a GPS-fix line. The CRITICAL property the
/// spec calls out is the mode-off path emitting nothing tagged. Twin intent of ConnectionTestModeEmissionTests.
@MainActor
final class WorkoutsTestModeEmissionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "testcentre.active.workouts")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "testcentre.active.workouts")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
        super.tearDown()
    }

    // Two well-separated, high-accuracy fixes a few seconds apart: the TrackFilter accepts both, so `ingest`
    // reaches the GPS-fix emit branch (two accepted points → a non-zero distance).
    private func fixes() -> [CLLocation] {
        let now = Date()
        let a = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5000, longitude: -0.1000),
                           altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now)
        let b = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5003, longitude: -0.1000),
                           altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                           timestamp: now.addingTimeInterval(3))
        return [a, b]
    }

    func testModeOffEmitsZeroWorkoutsLines() {
        XCTAssertFalse(TestCentre.active(.workouts))
        var captured: [String] = []
        let rec = GpsWorkoutRecorder()
        rec.workoutsLog = { captured.append($0) }
        rec.start(startMs: Int64(Date().timeIntervalSince1970 * 1000))
        rec.locationManager(CLLocationManager(), didUpdateLocations: fixes())
        XCTAssertTrue(captured.isEmpty, "mode OFF must emit zero .workouts lines, got \(captured)")
        rec.stop()
    }

    func testModeOnEmitsAGpsFixLine() {
        TestCentre.activate(.workouts)
        defer { TestCentre.deactivate(.workouts) }
        var captured: [String] = []
        let rec = GpsWorkoutRecorder()
        rec.workoutsLog = { captured.append($0) }
        rec.start(startMs: Int64(Date().timeIntervalSince1970 * 1000))
        rec.locationManager(CLLocationManager(), didUpdateLocations: fixes())
        XCTAssertFalse(captured.isEmpty, "mode ON must emit a GPS-fix line")
        XCTAssertTrue(captured.last?.hasPrefix("gps rawFixes=") ?? false, captured.last ?? "nil")
    }
}
