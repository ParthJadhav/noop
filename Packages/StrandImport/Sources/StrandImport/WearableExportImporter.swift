import Foundation
import ZIPFoundation

// MARK: - Offline file-import of a user's OWN Oura / Fitbit / Garmin data export
//
// A sibling to the wave-1 `ActivityFileImporter` (GPX/TCX/FIT workouts). Where that imports a single
// activity FILE, this imports the WELLNESS export each of these brands lets the user download of their
// own account — fully offline, no cloud API, no login. NOOP ingests the file the user already owns and
// maps it onto NOOP's DAILY metrics + sleep sessions (NOT workouts — workouts stay wave-1's lane).
//
//   • Oura   — the Account → Export Data JSON: sleep periods (stages/durations/HRV/RHR/breath),
//              daily readiness (RHR, temperature deviation, score), daily activity (steps/calories).
//   • Fitbit — Google Takeout → Fitbit → JSON: per-day sleep-*.json, resting_heart_rate-*.json,
//              steps-*.json, heart_rate-*.json.
//   • Garmin — Garmin Connect "Export Your Data" (GDPR) ZIP: DI_Connect_Wellness *_sleepData.json,
//              daily RHR / steps / stress JSON. (The FIT activity files in the same ZIP are wave-1's.)
//
// HONEST DATA: only fields the export actually carries are written; unknown stays nil. A brand's OWN
// score (Oura "readiness", any "sleep score") is stored under a REFERENCE key only — it is NEVER
// surfaced as NOOP's Charge/Effort/Rest. NOOP recomputes its own scores downstream from the raw
// RHR/HRV/sleep inputs, exactly as for any imported source. Every imported row is tagged with the
// brand's source id ("oura-import" / "fitbit-import" / "garmin-import").
//
// STAY OFFLINE: nothing here touches the network. SECURITY: every byte is UNTRUSTED — the read is
// byte-capped, the ZIP walk reuses the wave-1 zip-bomb budget (per-entry uncompressed ceiling + a
// running extract budget + CRC verify), JSON numerics are finite/range-checked (no trapping
// Int(Double)), and per-collection counts are capped so a crafted export can't OOM us.
//
// LICENSE: the file shapes are DOCUMENTED format facts (Oura account export, Fitbit Takeout, Garmin
// GDPR wellness). No GPL/AGPL code is copied — this is NOOP's own clean implementation.

public struct WearableExportImporter {

    public init() {}

    /// Hard ceilings (DoS guards, parity with ActivityFileImporter / WhoopExportImporter).
    /// A whole multi-year wellness export is tens of MB of JSON; 256 MB per entry is generous.
    public static let maxBytes = 256 << 20
    /// Per-entry uncompressed ceiling for the ZIP walk (zip-bomb guard).
    static let maxEntryBytes = 256 << 20
    /// Max files we read out of a folder/zip — a real export is a few hundred per-day JSONs.
    static let maxFiles = 200_000
    /// Max parsed rows (days / sleep periods) we retain — bounds memory against a crafted export.
    static let maxRows = 5_000_000

    // MARK: - Public entry point

    /// Parse a wearable export at `url` (a single `.json`, a folder, or a `.zip`). Auto-detects the
    /// brand by content. Throws `ImportError` on an unreadable / unrecognised input.
    public func `import`(from url: URL) throws -> WearableImportResult {
        let files = try collectFiles(from: url)
        guard !files.isEmpty else { throw ImportError.emptyExport("No readable JSON/CSV in \(url.lastPathComponent)") }

        guard let brand = Self.detectBrand(files) else {
            throw ImportError.emptyExport("Not an Oura, Fitbit or Garmin data export")
        }

        let parsed: (days: [WearableDailyRow], sleeps: [WearableSleepSession])
        switch brand {
        case .oura:   parsed = OuraExportParser.parse(files)
        case .fitbit: parsed = FitbitExportParser.parse(files)
        case .garmin: parsed = GarminExportParser.parse(files)
        }

        let days = Array(parsed.days.sorted { $0.day < $1.day }.prefix(Self.maxRows))
        let sleeps = Array(parsed.sleeps.sorted { $0.start < $1.start }.prefix(Self.maxRows))

        if days.isEmpty && sleeps.isEmpty {
            // A lone Oura `heartrate.csv` is a raw HR-sample file, not a daily summary, so it carries no
            // recovery/sleep/HRV NOOP can map. Say so plainly and point at the right file (#857) instead of
            // a brand-generic "no usable data".
            if brand == .oura, Self.onlyHeartRateCSV(files) {
                throw ImportError.emptyExport(
                    "That file is Oura's raw heart-rate log, which has no daily sleep or recovery values to "
                    + "import. Export your Oura data as JSON (Account → Export Data), or pick the daily/readiness "
                    + "CSV, and import that instead.")
            }
            throw ImportError.emptyExport("\(brand.displayName) export held no sleep or daily wellness data")
        }
        return WearableImportResult(brand: brand, days: days, sleeps: sleeps,
                                    summary: Self.summarize(brand: brand, days: days, sleeps: sleeps))
    }

    /// True when every collected file is a raw heart-rate CSV (no daily-summary CSV/JSON among them): the
    /// exact case in #857 where the user picked Oura's `heartrate.csv`.
    static func onlyHeartRateCSV(_ files: [String: Data]) -> Bool {
        guard !files.isEmpty else { return false }
        return files.keys.allSatisfy { name in
            name.hasSuffix(".csv") && (name.contains("heartrate") || name.contains("heart_rate"))
        }
    }

    /// Pure entry point for tests: parse already-loaded files (lowercased filename → bytes) of a known
    /// brand. No filesystem / zip involved.
    public static func parse(brand: WearableBrand, files: [String: Data]) -> WearableImportResult {
        let parsed: (days: [WearableDailyRow], sleeps: [WearableSleepSession])
        switch brand {
        case .oura:   parsed = OuraExportParser.parse(files)
        case .fitbit: parsed = FitbitExportParser.parse(files)
        case .garmin: parsed = GarminExportParser.parse(files)
        }
        let days = parsed.days.sorted { $0.day < $1.day }
        let sleeps = parsed.sleeps.sorted { $0.start < $1.start }
        return WearableImportResult(brand: brand, days: days, sleeps: sleeps,
                                    summary: summarize(brand: brand, days: days, sleeps: sleeps))
    }

    // MARK: - Brand detection (by content, not trust)

    /// Sniff the collected files to decide which brand this is. Filename hints first (cheap), then a
    /// JSON-key probe of a sample file so a renamed/zipped export still routes correctly.
    static func detectBrand(_ files: [String: Data]) -> WearableBrand? {
        let names = Set(files.keys)

        // Garmin GDPR: the wellness folder + its *_sleepData.json / *_UserBioMetricProfileData files.
        if names.contains(where: { $0.contains("sleepdata") || $0.contains("di_connect") || $0.contains("userbiometric") || $0.contains("_summarizedactivities") }) {
            return .garmin
        }
        // Fitbit Takeout: per-day sleep-*/resting_heart_rate-*/steps-* files under a Fitbit folder.
        if names.contains(where: { $0.hasPrefix("sleep-") || $0.hasPrefix("resting_heart_rate-") || $0.hasPrefix("steps-") || $0.contains("fitbit") }) {
            return .fitbit
        }
        // Oura: a single account-export JSON (often "oura_*"), or one whose top-level keys are Oura's.
        if names.contains(where: { $0.contains("oura") }) { return .oura }
        // Oura CSV export: the per-category files a user can download alongside (or instead of) the JSON,
        // e.g. `heartrate.csv` / `readiness.csv` / `sleep.csv`. Routing these to Oura (rather than failing
        // brand detection) lets the importer give an HONEST per-file outcome instead of an opaque error
        // (#857): a daily-summary CSV imports, a lone raw `heartrate.csv` reports "no daily wellness data".
        if names.contains(where: { ouraCSVFilenames.contains(where: $0.contains) }) { return .oura }

        // Content probe: look at the shape of the sample files (JSON keys, or an Oura CSV header).
        for (name, data) in files.prefix(8) {
            if let b = brandFromJSONShape(data) { return b }
            if name.hasSuffix(".csv"), OuraExportParser.looksLikeOuraCSV(CSVTable(data: data).normalizedHeaders) {
                return .oura
            }
        }
        return nil
    }

    /// Filename fragments that identify an Oura per-category CSV export (lowercased, substring match).
    static let ouraCSVFilenames: [String] = ["heartrate", "heart_rate", "readiness", "sleep_periods"]

    /// Probe a JSON blob's top-level / sample-element keys to spot a brand even when the filename
    /// gives nothing away. Bounded: only the first object is inspected.
    private static func brandFromJSONShape(_ data: Data) -> WearableBrand? {
        guard let obj = try? JSONSerialization.jsonObject(with: BOM.stripUTF8(data)) else { return nil }
        // Oura account export: a dict keyed by "sleep" / "daily_readiness" / "daily_activity".
        if let dict = obj as? [String: Any] {
            let keys = Set(dict.keys.map { $0.lowercased() })
            if !keys.isDisjoint(with: ["sleep", "daily_readiness", "daily_activity", "readiness", "activity"]),
               OuraExportParser.looksLikeOura(dict) {
                return .oura
            }
            // Garmin single-day blob.
            if dict["calendarDate"] != nil && (dict["deepSleepSeconds"] != nil || dict["restingHeartRate"] != nil) {
                return .garmin
            }
        }
        // A bare array element shape (Fitbit per-day file / Garmin sleepData array).
        if let arr = obj as? [[String: Any]], let first = arr.first {
            if first["dateOfSleep"] != nil || (first["dateTime"] != nil && first["value"] != nil) { return .fitbit }
            if first["sleepStartTimestampGMT"] != nil || first["deepSleepSeconds"] != nil { return .garmin }
        }
        return nil
    }

    // MARK: - File collection (single file / folder / zip)

    /// Return `[lowercasedRelativePath: rawData]` for every JSON/CSV in the input. A single `.json` is
    /// returned as one entry; a folder is walked; a `.zip` is extracted with the wave-1 zip-bomb guard.
    func collectFiles(from url: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.fileNotFound(url.path)
        }

        if isDir.boolValue { return try loadFromFolder(url) }

        let ext = url.pathExtension.lowercased()
        if ext == "zip" { return try loadFromZip(url) }
        // A bare data file (Oura's single JSON, or a single Garmin/Fitbit JSON). Try zip first in case
        // it's a zip without the extension, else read it whole.
        if let z = try? loadFromZip(url), !z.isEmpty { return z }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes, let data = try? Data(contentsOf: url) else {
            throw ImportError.notAZipOrFolder(url.path)
        }
        guard Self.isWellnessFile(url.lastPathComponent.lowercased(), data: data) else {
            throw ImportError.notAZipOrFolder(url.path)
        }
        return [url.lastPathComponent.lowercased(): data]
    }

    private func loadFromFolder(_ folder: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else {
            throw ImportError.fileNotFound(folder.path)
        }
        let base = folder.path
        for case let u as URL in e {
            if result.count >= Self.maxFiles { break }
            let name = u.lastPathComponent.lowercased()
            guard name.hasSuffix(".json") || name.hasSuffix(".csv") else { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.maxEntryBytes { continue }
            guard let data = try? Data(contentsOf: u) else { continue }
            guard Self.isWellnessFile(name, data: data) else { continue }
            // Key on the path RELATIVE to the folder so brand detection can see "di_connect/..." etc.
            let rel = u.path.hasPrefix(base) ? String(u.path.dropFirst(base.count)).lowercased() : name
            result[rel.hasPrefix("/") ? String(rel.dropFirst()) : rel] = data
        }
        return result
    }

    private func loadFromZip(_ zipURL: URL) throws -> [String: Data] {
        let archive: Archive
        do { archive = try Archive(url: zipURL, accessMode: .read) }
        catch { throw ImportError.notAZipOrFolder(zipURL.path) }

        var result: [String: Data] = [:]
        for entry in archive {
            if result.count >= Self.maxFiles { break }
            guard entry.type == .file else { continue }
            let path = entry.path.lowercased()
            let base = (entry.path as NSString).lastPathComponent.lowercased()
            guard base.hasSuffix(".json") || base.hasSuffix(".csv") else { continue }   // skip FIT/GPX/etc.
            let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
            if declared > Self.maxEntryBytes { continue }
            var buffer = Data()
            var written = 0
            do {
                _ = try archive.extract(entry) { chunk in
                    written += chunk.count
                    if written > Self.maxEntryBytes { throw CancellationError() }
                    buffer.append(chunk)
                }
            } catch { continue }   // corrupt / truncated / oversized → skip, never import partial
            guard !buffer.isEmpty, Self.isWellnessFile(base, data: buffer) else { continue }
            if result[path] == nil { result[path] = buffer }
        }
        return result
    }

    /// True if this file is one we care about (a wellness JSON/CSV). Filters out a brand's bulky
    /// non-wellness JSON (e.g. settings, device, social) so a huge export doesn't load needless bytes.
    /// Permissive by content: an unknown JSON file is kept only if its name hints at sleep/HR/steps/etc.
    static func isWellnessFile(_ name: String, data: Data) -> Bool {
        if name.hasSuffix(".csv") {
            return name.contains("sleep") || name.contains("heart") || name.contains("step")
                || name.contains("stress") || name.contains("activit") || name.contains("readiness")
                || name.contains("wellness") || name.contains("rhr")
                // Oura's daily-summary CSV can be named generically (#857): keep the common names so the
                // summary file reaches the parser instead of being filtered out.
                || name.contains("oura") || name.contains("daily") || name.contains("trend")
        }
        // JSON: name-based wellness hints (covers Fitbit/Garmin per-day files + Oura's single export).
        let hints = ["sleep", "heart", "rate", "step", "stress", "activit", "readiness",
                     "wellness", "rhr", "oura", "calorie", "spo2", "respiration", "temperature",
                     "biometric", "summarizedactivities", "di_connect"]
        return hints.contains(where: { name.contains($0) })
    }

    // MARK: - Summary

    static func summarize(brand: WearableBrand, days: [WearableDailyRow], sleeps: [WearableSleepSession]) -> ImportSummary {
        var dates: [Date] = []
        for d in days { if let dt = dayDate(d.day) { dates.append(dt) } }
        dates += sleeps.map(\.start)
        return ImportSummary(
            sourceKind: brand.dataSourceKind,
            recordCount: days.count + sleeps.count,
            earliest: dates.min(),
            latest: dates.max(),
            countsByCategory: ["days": days.count, "sleepSessions": sleeps.count])
    }

    /// A one-line human status string for the import UI. Honest: only what was imported.
    public static func summaryText(_ r: WearableImportResult) -> String {
        var parts = ["Imported \(r.brand.displayName)"]
        if !r.days.isEmpty { parts.append("\(r.days.count) days") }
        if !r.sleeps.isEmpty { parts.append("\(r.sleeps.count) sleeps") }
        if r.days.isEmpty && r.sleeps.isEmpty { parts.append("nothing usable") }
        if let first = r.days.first?.day, let last = r.days.last?.day, first != last {
            parts.append("\(first) to \(last)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared date helpers

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayDate(_ s: String) -> Date? { dayFormatter.date(from: s) }

    /// The UTC calendar-day string for a date.
    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
}

// MARK: - JSON value coercion (shared by the brand parsers; crafted-input safe)

enum WearableJSON {
    /// Parse a blob into a top-level dictionary, or nil. Bounded by the caller's byte cap.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: BOM.stripUTF8(data))) as? [String: Any]
    }
    static func array(_ data: Data) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: BOM.stripUTF8(data))) as? [Any]
    }

    static func dbl(_ v: [String: Any], _ k: String) -> Double? {
        if let d = v[k] as? Double { return d.isFinite ? d : nil }
        if let n = v[k] as? Int { return Double(n) }
        if let n = v[k] as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = v[k] as? String, let d = Double(s) { return d.isFinite ? d : nil }
        return nil
    }

    /// Finite + Int-range checked Double→Int (never traps on attacker NaN/inf/huge values).
    static func int(_ v: [String: Any], _ k: String) -> Int? {
        guard let d = dbl(v, k), d >= -9e18, d <= 9e18 else { return nil }
        return Int(d)
    }

    static func str(_ v: [String: Any], _ k: String) -> String? { v[k] as? String }

    /// 0 (or negative) HR / score values mean "not measured" → nil rather than a misleading zero.
    static func posInt(_ v: [String: Any], _ k: String) -> Int? {
        guard let n = int(v, k), n > 0 else { return nil }
        return n
    }
    static func posDbl(_ v: [String: Any], _ k: String) -> Double? {
        guard let d = dbl(v, k), d > 0 else { return nil }
        return d
    }
}
