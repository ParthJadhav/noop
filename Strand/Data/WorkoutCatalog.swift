import Foundation

/// The named-sport catalogue for the workout pickers (manual add/edit + live tracking), the Apple-side
/// mirror of Android's `WorkoutSport.all` (built from `ExerciseTypes.NAMES` + `EXTRA`). The two lists
/// MUST stay in lockstep , the stored `WorkoutRow.sport` is a cross-platform value (it round-trips
/// through CSV / Apple-Health export), so a sport named here must read identically on Android and
/// vice-versa.
///
/// Apple has no Health Connect, so unlike Android we carry no exercise-type int , just the display
/// name and whether a route makes sense (drives the "· GPS" hint and a sensible GPS default, parity
/// with Android's `Sport.isDistanceSport`). The names are DATA, not UI literals: they're persisted
/// verbatim as the sport label and must never be localised (a translated name would split one sport
/// into two). Free-text stays allowed everywhere , this catalogue is the suggestion set, not a
/// whitelist (#519).
enum WorkoutCatalog {

    /// One selectable activity. `name` is the verbatim stored/display label.
    struct Sport: Identifiable, Hashable {
        let name: String
        /// Types where a route makes sense → GPS hint / default on.
        let isDistanceSport: Bool
        var id: String { name }
    }

    /// Ordered to match Android `WorkoutSport.all`: common / distance first, the rest, the EXTRA
    /// sports HC has no type for (Padel , #77/#152), then the generic "Other" last. Distance flags
    /// mirror Android `ExerciseTypes.DISTANCE_TYPES`.
    static let all: [Sport] = [
        Sport(name: "Running", isDistanceSport: true),
        Sport(name: "Walking", isDistanceSport: true),
        Sport(name: "Hiking", isDistanceSport: true),
        Sport(name: "Cycling", isDistanceSport: true),
        Sport(name: "Open-water swim", isDistanceSport: true),
        Sport(name: "Rowing", isDistanceSport: true),
        Sport(name: "Treadmill run", isDistanceSport: false),
        // Indoor treadmill walk (#714). Distance off so GPS stays defaulted off, like Treadmill run.
        Sport(name: "Treadmill walk", isDistanceSport: false),
        Sport(name: "Indoor cycle", isDistanceSport: false),
        Sport(name: "Pool swim", isDistanceSport: false),
        Sport(name: "Row machine", isDistanceSport: false),
        Sport(name: "Elliptical", isDistanceSport: false),
        Sport(name: "Strength", isDistanceSport: false),
        // Bodybuilding (#714). A strength-style session with no route, so GPS off.
        Sport(name: "Bodybuilding", isDistanceSport: false),
        Sport(name: "Weightlifting", isDistanceSport: false),
        Sport(name: "HIIT", isDistanceSport: false),
        Sport(name: "Yoga", isDistanceSport: false),
        Sport(name: "Pilates", isDistanceSport: false),
        Sport(name: "Boxing", isDistanceSport: false),
        Sport(name: "Basketball", isDistanceSport: false),
        Sport(name: "Soccer", isDistanceSport: false),
        Sport(name: "Baseball", isDistanceSport: false),
        Sport(name: "Badminton", isDistanceSport: false),
        Sport(name: "Tennis", isDistanceSport: false),
        Sport(name: "Squash", isDistanceSport: false),
        Sport(name: "Racquetball", isDistanceSport: false),
        Sport(name: "Table tennis", isDistanceSport: false),
        Sport(name: "Volleyball", isDistanceSport: false),
        // Martial arts covers the user-requested Jiu-Jitsu plus karate/judo/MMA etc. (#768)
        Sport(name: "Martial arts", isDistanceSport: false),
        Sport(name: "Dancing", isDistanceSport: false),
        Sport(name: "Golf", isDistanceSport: false),
        Sport(name: "Climbing", isDistanceSport: false),
        Sport(name: "Stretching", isDistanceSport: false),
        // Snow sports cover ground → a route makes sense, so GPS defaults on. (#768)
        Sport(name: "Skiing", isDistanceSport: true),
        Sport(name: "Snowboarding", isDistanceSport: true),
        // EXTRA , no Health Connect type, still first-class here. (#77/#152, #768)
        Sport(name: "Padel", isDistanceSport: false),
        Sport(name: "Pickleball", isDistanceSport: false),
        // Bowling (D#850): light lane sport, no route, so GPS stays off.
        Sport(name: "Bowling", isDistanceSport: false),
        Sport(name: "Other", isDistanceSport: false),
    ]

    /// The default sport for a live workout when the user starts one without picking , the generic
    /// "Other", matching Android `WorkoutSport.default`. (The auto-detector relabels detected bouts;
    /// this is only the manual-start fallback.)
    static let defaultSportName = "Other"

    /// Case-insensitive lookup of the suggestion matching a (possibly free-typed) label, or nil for
    /// an off-catalogue sport , which is still valid, just not in the suggestion set.
    static func sport(named name: String) -> Sport? {
        let q = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// Catalogue filtered by a search query (empty → the whole list). Names only, case-insensitive.
    static func matching(_ query: String) -> [Sport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }
}
