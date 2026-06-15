import Foundation

/// One interrogable metric: how to fetch it (key+source), how to label/format it, and whether
/// higher is better (drives delta tinting). The Metric Explorer + Compare are built from this list.
struct MetricDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let category: String
    let unit: String
    let source: String       // "my-whoop" or "apple-health"
    let icon: String
    let decimals: Int
    let higherIsBetter: Bool?
    /// A short, plain-English one-liner for the metric (tile subtitle / catalog blurb). Optional —
    /// only the three headline scores (Charge / Effort / Rest) carry one today; everything else is nil.
    var description: String? = nil
    var id: String { source + ":" + key }

    /// True for the Effort metric (#268). Its stored value is 0–100; the effort-scale toggle converts
    /// the DISPLAYED number + unit onto WHOOP's 0–21 axis. Mirrors the Android `MetricSpec.whoopEffort`
    /// gate (`key == "strain"`) — the only value-converting metric in the catalog.
    private var isEffort: Bool { key == "strain" }

    func format(_ v: Double) -> String {
        let n = decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// Effort-aware plain format (#268): the Effort metric's stored 0–100 value is shown on the selected
    /// scale (its number + "/100"→"/21" unit); every other metric is scale-agnostic and falls through to
    /// the unit-less `format` above. Callers that don't carry an effort scale get `.hundred` (no change).
    func format(_ v: Double, effortScale: EffortScale) -> String {
        guard isEffort else { return format(v) }
        let n = UnitFormatter.effortDisplay(v, scale: effortScale)
        return "\(n) \(displayUnit(effortScale: effortScale))"
    }

    /// Unit-aware format: for the three SI-stored metrics that have a non-metric counterpart
    /// (weight/lean_mass in kg, skin_temp in °C) convert + relabel via `UnitFormatter`. The Effort
    /// metric follows its own 0–100↔0–21 scale (#268). Every other metric (%, bpm, ms, min, …) is
    /// scale-agnostic and falls through to the plain `format` above, so each toggle only ever touches
    /// the values that actually have a converted form.
    func format(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return isEffort ? format(v, effortScale: effortScale) : format(v)
        }
    }

    /// Like `format`, but for a DIFFERENCE between two values (e.g. the Δ StatTile). A temperature
    /// delta scales by 9/5 with NO +32 offset; mass/distance deltas scale by their plain factor; an
    /// Effort delta rescales 0–100→0–21 on the WHOOP scale (#268, no offset — it's a magnitude). The
    /// caller supplies the magnitude (sign is rendered separately).
    func formatDelta(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
        default:
            guard isEffort else { return format(v) }
            // A delta on the 0–100 axis rescales by the same ×21/100 factor (the offset-free `effortValue`).
            let n = UnitFormatter.effortDisplay(v, scale: effortScale)
            return "\(n) \(displayUnit(effortScale: effortScale))"
        }
    }

    /// The unit LABEL as displayed (e.g. the trailing chip in the Metric Explorer list), mapped to the
    /// active system. Only the convertible units change; everything else returns its stored label.
    func displayUnit(system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massUnit(system)
        case "°C":  return UnitFormatter.temperatureUnit(temperature)
        default:    return isEffort ? displayUnit(effortScale: effortScale) : unit
        }
    }

    /// The Effort metric's unit LABEL on the selected scale — "/100" or "/21" (#268). Non-Effort metrics
    /// return their stored label unchanged. Mirrors the Android `MetricSpec.displayUnit` swap.
    func displayUnit(effortScale: EffortScale) -> String {
        guard isEffort else { return unit }
        return "/" + UnitFormatter.effortScaleMax(effortScale)
    }
}

/// Canonical catalog — mirrors the WHOOP "Trend View" plus Apple Health body metrics.
/// Keys match exactly what the importers write into metricSeries.
enum MetricCatalog {
    static let categories = ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", "Average Heart Rate", "Heart", "bpm", "my-whoop", "heart", 0, nil),
        d("max_hr", "Max Heart Rate", "Heart", "bpm", "my-whoop", "bolt.heart", 0, nil),
        d("energy_kcal", "Calories", "Heart", "kcal", "my-whoop", "flame", 0, nil),
        d("vo2max", "VO₂ Max", "Heart", "", "apple-health", "lungs.fill", 1, true),
        d("fitness_age", "Fitness Age", "Heart", "yrs", "my-whoop", "figure.run", 0, false),
        d("vo2max_est", "VO₂ Max (estimated)", "Heart", "", "my-whoop", "lungs", 1, true),
        d("vitality", "Vitality", "Heart", "", "my-whoop", "sparkles", 0, true),
        d("body_age", "Body Age", "Heart", "yrs", "my-whoop", "figure.stand", 0, false),

        // ── Charge (was Recovery)
        d("recovery", "Charge", "Charge", "%", "my-whoop", "heart.circle", 0, true,
          "How recovered you are — led by HRV versus your personal baseline."),
        d("hrv", "Heart Rate Variability", "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("rhr", "Resting Heart Rate", "Charge", "bpm", "my-whoop", "heart", 0, false),
        d("resp_rate", "Respiratory Rate", "Charge", "rpm", "my-whoop", "lungs", 1, nil),
        d("spo2", "Blood Oxygen", "Charge", "%", "my-whoop", "drop", 0, true),
        d("skin_temp", "Skin Temperature", "Charge", "°C", "my-whoop", "thermometer", 1, nil),

        // ── Rest (was Sleep)
        d("sleep_performance", "Rest", "Rest", "%", "my-whoop", "moon.stars", 0, true,
          "How restorative your sleep was — duration, efficiency, deep+REM, timing."),
        d("in_bed_min", "Time in Bed", "Rest", "min", "my-whoop", "bed.double", 0, nil),
        d("sleep_total_min", "Asleep Time", "Rest", "min", "my-whoop", "moon.zzz", 0, true),
        d("hours_vs_needed_pct", "Hours vs Needed", "Rest", "%", "my-whoop", "gauge.medium", 0, true),
        d("sleep_consistency", "Sleep Consistency", "Rest", "%", "my-whoop", "calendar", 0, true),
        d("restorative_pct", "Restorative Sleep", "Rest", "%", "my-whoop", "sparkles", 0, true),
        d("restorative_min", "Restorative Sleep", "Rest", "min", "my-whoop", "sparkles", 0, true),
        d("sleep_efficiency", "Sleep Efficiency", "Rest", "%", "my-whoop", "bed.double.fill", 0, true),
        d("sleep_deep_min", "Deep (SWS) Sleep", "Rest", "min", "my-whoop", "moon.fill", 0, true),
        d("sleep_rem_min", "REM Sleep", "Rest", "min", "my-whoop", "moon.haze", 0, true),
        d("sleep_light_min", "Light Sleep", "Rest", "min", "my-whoop", "moon", 0, nil),
        d("sleep_need_min", "Sleep Need", "Rest", "min", "my-whoop", "gauge", 0, nil),
        d("sleep_debt_min", "Sleep Debt", "Rest", "min", "my-whoop", "exclamationmark.circle", 0, false),

        // ── Effort (was Strain)
        d("strain", "Effort", "Effort", "/100", "my-whoop", "flame", 1, nil,
          "Cardiovascular load for the day, on a 0–100 scale (was 0–21)."),
        d("steps", "Steps", "Effort", "", "apple-health", "figure.walk", 0, true),
        d("hr_zones13_min", "HR Zones 1–3", "Effort", "min", "my-whoop", "heart", 0, nil),
        d("hr_zones45_min", "HR Zones 4–5", "Effort", "min", "my-whoop", "heart.fill", 0, nil),
        d("hr_zones_all_min", "HR Zones (All)", "Effort", "min", "my-whoop", "heart.text.square", 0, nil),
        d("strength_min", "Strength Activity Time", "Effort", "min", "my-whoop", "dumbbell", 0, nil),
        d("active_kcal", "Active Energy", "Effort", "kcal", "apple-health", "flame.fill", 0, nil),

        // ── Health / Body
        d("weight", "Weight", "Health", "kg", "apple-health", "scalemass", 1, nil),
        d("body_fat", "Body Fat", "Health", "%", "apple-health", "percent", 1, false),
        d("lean_mass", "Lean Body Mass", "Health", "kg", "apple-health", "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", "apple-health", "figure", 1, nil),
        d("stress", "Day Stress", "Health", "/3", "my-whoop", "gauge.with.dots.needle.50percent", 1, false),

        // ── Nutrition (imported from a food-tracker CSV: calories-in alongside calories-out)
        d("calories_in", "Calories In", "Nutrition", "kcal", "nutrition-csv", "fork.knife", 0, nil),
        d("protein_g", "Protein", "Nutrition", "g", "nutrition-csv", "p.circle", 0, nil),
        d("carbs_g", "Carbs", "Nutrition", "g", "nutrition-csv", "c.circle", 0, nil),
        d("fat_g", "Fat", "Nutrition", "g", "nutrition-csv", "f.circle", 0, nil),

        // ── Mind (daily mood check-in, 1–5; non-clinical self-tracking)
        d("mood", "Mood", "Mind", "/5", "noop-mood", "face.smiling", 0, true),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?, _ description: String? = nil) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter,
                         description: description)
    }
}
