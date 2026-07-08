import Foundation

// DisplayTrace.swift - pure values + line formatters for the Display & Performance test mode.
//
// The Display mode captures UI/runtime diagnostics: the device metrics (size class, safe-area insets,
// Dynamic Type, orientation, theme), a rolling frame-time / hitch summary, and the memory high-water.
// The platform layer READS the live values (UITraitCollection / UIScreen on iOS, NSScreen on macOS,
// the Configuration on Android) and feeds them to these PURE formatters, so the exact line shapes are
// pinned by a fixture and read identically in a shared report on either platform.
//
// DisplayMetrics is the value carrier (every field already resolved by the caller, so this stays pure -
// no UIKit / AppKit import, no clock, no IO, no PII). DisplayTrace formats the three tagged-line shapes.
// DisplayReadout parses the deviceMetrics line back into the single liveReadout id the in-app panel
// binds (deviceMetricsNow). No em-dashes anywhere. The Kotlin twin is DisplayTrace.kt.

/// A platform-resolved snapshot of the display environment. Every field is already read by the caller
/// (UITraitCollection / UIScreen, NSScreen, or the Android Configuration), so this type is pure data and
/// the formatter below has no platform dependency. Optionals are for metrics a platform cannot offer
/// (e.g. a true size class is iOS-only); the formatter prints "n/a" for a nil, never fabricating a value.
public struct DisplayMetrics: Sendable, Equatable {
    /// Horizontal size class, "compact" / "regular" / nil where the platform has no size class (macOS).
    public let horizontalSizeClass: String?
    /// Vertical size class, same convention.
    public let verticalSizeClass: String?
    /// Logical points wide / tall of the key window (or the screen on macOS).
    public let widthPt: Double
    public let heightPt: Double
    /// Backing scale (UIScreen.scale / NSScreen.backingScaleFactor); 0 when unknown.
    public let scale: Double
    /// Safe-area insets in points (top, bottom, leading, trailing). Zeroed where there is no notch / inset.
    public let safeTop: Double
    public let safeBottom: Double
    public let safeLeading: Double
    public let safeTrailing: Double
    /// Dynamic Type / font scale: the content-size category name on iOS (e.g. "L", "XXL", "AX3"), or a
    /// scale-factor label on Android ("1.30"). nil where the platform exposes neither (macOS).
    public let dynamicType: String?
    /// "portrait" / "landscape" / "unknown".
    public let orientation: String
    /// "light" / "dark".
    public let theme: String

    public init(horizontalSizeClass: String?, verticalSizeClass: String?,
                widthPt: Double, heightPt: Double, scale: Double,
                safeTop: Double, safeBottom: Double, safeLeading: Double, safeTrailing: Double,
                dynamicType: String?, orientation: String, theme: String) {
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.widthPt = widthPt; self.heightPt = heightPt; self.scale = scale
        self.safeTop = safeTop; self.safeBottom = safeBottom
        self.safeLeading = safeLeading; self.safeTrailing = safeTrailing
        self.dynamicType = dynamicType; self.orientation = orientation; self.theme = theme
    }
}

/// A platform-resolved snapshot of the on-device DATA VOLUME (CAPTURE-D / #797): the read-set that backs
/// the screens, so import-driven lag shows what it's rendering over, not just frame stats. Every count is
/// already read from the STORE by the caller (never via the Repository / @Published view-models), so this
/// type is pure data and the formatter below has no store dependency.
public struct DataVolume: Sendable, Equatable {
    /// Total raw stream rows in the store (HR + RR + events + the biometric streams) , the dominant cost.
    public let dbRows: Int
    /// Number of distinct days that carry IMPORTED daily metrics (the #799 import surface).
    public let importedDays: Int
    /// Total detected/recorded workout rows.
    public let workouts: Int
    /// Rows touched by the most recent render the caller measured, or nil when it hasn't measured one yet.
    public let lastRenderRows: Int?

    public init(dbRows: Int, importedDays: Int, workouts: Int, lastRenderRows: Int?) {
        self.dbRows = dbRows; self.importedDays = importedDays
        self.workouts = workouts; self.lastRenderRows = lastRenderRows
    }
}

public enum DisplayTrace {

    /// The data-volume line (CAPTURE-D / #797): one upfront `.display` summary of the store's read-set, so a
    /// "feels laggy after import" report shows HOW MUCH data the screens are rendering over (db rows,
    /// imported days, workouts, last render's row count), not only frame timings. A nil `lastRenderRows`
    /// (no render measured yet) prints "n/a" rather than fabricating a 0.
    public static func dataVolumeLine(_ v: DataVolume) -> String {
        let last = v.lastRenderRows.map(String.init) ?? "n/a"
        return "dataVolume dbRows=\(v.dbRows) importedDays=\(v.importedDays) "
            + "workouts=\(v.workouts) lastRenderRows=\(last)"
    }

    /// The device-metrics line: one upfront `.display` summary of the resolved DisplayMetrics, so a
    /// "screen looks wrong" report carries the exact layout environment the screen was rendered in. All
    /// numbers are rounded to whole points (sub-point precision is noise for a layout bug). A nil size
    /// class / Dynamic Type prints "n/a" rather than a fabricated value.
    public static func deviceMetricsLine(_ m: DisplayMetrics) -> String {
        let h = m.horizontalSizeClass ?? "n/a"
        let v = m.verticalSizeClass ?? "n/a"
        let dt = m.dynamicType ?? "n/a"
        return "deviceMetrics "
            + "size=\(pt(m.widthPt))x\(pt(m.heightPt))pt @\(scaleLabel(m.scale))x "
            + "sizeClass=\(h)/\(v) "
            + "safeArea=t\(pt(m.safeTop)) b\(pt(m.safeBottom)) l\(pt(m.safeLeading)) r\(pt(m.safeTrailing)) "
            + "dynamicType=\(dt) orientation=\(m.orientation) theme=\(m.theme)"
    }

    /// The rolling frame-time / hitch summary line: a periodic digest (NOT a per-frame line) of the
    /// frame-time monitor's last window. `meanMs` / `p95Ms` describe the frame-duration distribution,
    /// `hitches` is the count of frames over the hitch threshold this window, and `worstMs` is the single
    /// longest frame. Emitted on a cadence (e.g. once a window of N frames), never every frame, so the
    /// trace itself is not a performance cost. `frames` is the window size the digest summarises.
    public static func frameSummaryLine(frames: Int, meanMs: Double, p95Ms: Double,
                                        hitches: Int, worstMs: Double, hitchThresholdMs: Double) -> String {
        "frameSummary frames=\(frames) mean=\(ms(meanMs))ms p95=\(ms(p95Ms))ms "
            + "hitches=\(hitches) worst=\(ms(worstMs))ms threshold=\(ms(hitchThresholdMs))ms"
    }

    /// The memory high-water line: the peak resident footprint seen while the mode was active, in MB. The
    /// caller reads the live footprint (phys_footprint via task_info on Apple, Debug / Runtime on Android)
    /// and tracks the maximum; this formats that single peak so a "feels laggy / killed" report shows how
    /// close the app ran to its memory ceiling.
    public static func memoryHighWaterLine(peakMB: Double) -> String {
        "memoryHighWater peak=\(ms(peakMB))MB"
    }

    /// Round a point value to a whole number for the line ("390"). Negative insets clamp to 0 (an inset is
    /// never negative; a stray negative is a read glitch, not real layout).
    static func pt(_ v: Double) -> String { String(Int((max(0, v)).rounded())) }

    /// Backing scale to one decimal ("2.0" / "3.0"); "?" when the caller could not read it (0).
    static func scaleLabel(_ v: Double) -> String { v > 0 ? String(format: "%.1f", v) : "?" }

    /// Millisecond / MB value to one decimal so the distribution reads cleanly without sub-tenth noise.
    static func ms(_ v: Double) -> String { String(format: "%.1f", max(0, v)) }
}

/// Pure values for the Display & Performance live-readout panel. Parses the `.display`-tagged log tail
/// the device-metrics emitter writes, so the panel reflects exactly the metrics line in the report
/// without the platform layer having to expose new published properties. No state, no IO, no em-dashes.
/// The Kotlin twin is the DisplayReadout object in DisplayTrace.kt.
public enum DisplayReadout {

    /// The most recent device-metrics summary for the `deviceMetricsNow` id: everything after the
    /// "deviceMetrics " marker on the last device-metrics line in the tagged tail, so the panel reads the
    /// same size / size-class / Dynamic Type / orientation / theme the report carries. nil when no metrics
    /// line is present yet (the emitter writes one on activate and on each trait change).
    public static func deviceMetricsNow(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "deviceMetrics ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }

    /// The most recent frame-summary fragment for an at-a-glance perf read (mean / p95 / hitches), or nil
    /// when the frame monitor has not yet emitted a window. Parsed off the same tagged tail; the panel uses
    /// it as a secondary readout line under the device metrics.
    public static func frameSummaryNow(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "frameSummary ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }
}
