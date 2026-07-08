package com.noop.ingest

import androidx.health.connect.client.records.ExerciseSessionRecord as EX

/**
 * Single source of truth for Health Connect exercise-type <-> label, shared by [HealthConnectImporter]
 * (int -> label) and [com.noop.analytics.WorkoutSport] (the picker + writeback). Reference the library
 * constants, never hardcoded ints — the ints have changed / been wrong before (#53).
 */
object ExerciseTypes {
    /** Ordered for the picker: common / distance first, then the rest, then Other. */
    val NAMES: Map<Int, String> = linkedMapOf(
        EX.EXERCISE_TYPE_RUNNING to "Running",
        EX.EXERCISE_TYPE_WALKING to "Walking",
        EX.EXERCISE_TYPE_HIKING to "Hiking",
        EX.EXERCISE_TYPE_BIKING to "Cycling",
        EX.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "Open-water swim",
        EX.EXERCISE_TYPE_ROWING to "Rowing",
        EX.EXERCISE_TYPE_RUNNING_TREADMILL to "Treadmill run",
        EX.EXERCISE_TYPE_BIKING_STATIONARY to "Indoor cycle",
        EX.EXERCISE_TYPE_SWIMMING_POOL to "Pool swim",
        EX.EXERCISE_TYPE_ROWING_MACHINE to "Row machine",
        EX.EXERCISE_TYPE_ELLIPTICAL to "Elliptical",
        EX.EXERCISE_TYPE_STRENGTH_TRAINING to "Strength",
        EX.EXERCISE_TYPE_WEIGHTLIFTING to "Weightlifting",
        EX.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING to "HIIT",
        EX.EXERCISE_TYPE_YOGA to "Yoga",
        EX.EXERCISE_TYPE_PILATES to "Pilates",
        EX.EXERCISE_TYPE_BOXING to "Boxing",
        EX.EXERCISE_TYPE_BASKETBALL to "Basketball",
        EX.EXERCISE_TYPE_SOCCER to "Soccer",
        EX.EXERCISE_TYPE_BASEBALL to "Baseball",
        EX.EXERCISE_TYPE_BADMINTON to "Badminton",
        EX.EXERCISE_TYPE_TENNIS to "Tennis",
        EX.EXERCISE_TYPE_SQUASH to "Squash",
        EX.EXERCISE_TYPE_RACQUETBALL to "Racquetball",
        EX.EXERCISE_TYPE_TABLE_TENNIS to "Table tennis",
        EX.EXERCISE_TYPE_VOLLEYBALL to "Volleyball",
        // Martial arts covers the user-requested Jiu-Jitsu plus karate/judo/MMA etc. (#768).
        EX.EXERCISE_TYPE_MARTIAL_ARTS to "Martial arts",
        EX.EXERCISE_TYPE_DANCING to "Dancing",
        EX.EXERCISE_TYPE_GOLF to "Golf",
        EX.EXERCISE_TYPE_ROCK_CLIMBING to "Climbing",
        EX.EXERCISE_TYPE_STRETCHING to "Stretching",
        // Snow sports have a route, so they default GPS on (see DISTANCE_TYPES). (#768)
        EX.EXERCISE_TYPE_SKIING to "Skiing",
        EX.EXERCISE_TYPE_SNOWBOARDING to "Snowboarding",
        EX.EXERCISE_TYPE_OTHER_WORKOUT to "Other",
    )

    /**
     * Sports the user can pick that Health Connect has NO dedicated type for, so they ride on a
     * fallback HC type (here "Other") while keeping their own NOOP label. Kept OUT of [NAMES] because
     * that map is int-keyed — "Padel" and "Other" would collide on EXERCISE_TYPE_OTHER_WORKOUT — and
     * because an inbound HC record of that type must still read back as the generic name, not Padel.
     * Padel (#77 / #152): a racquet sport HC doesn't enumerate yet → writes as "Other", stays "Padel"
     * on our own rows. List the display name + the HC type it falls back to.
     */
    val EXTRA: List<Pair<String, Int>> = listOf(
        "Padel" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        // Pickleball (#768): a fast-growing racquet sport HC has no type for → writes as "Other",
        // stays "Pickleball" on our own rows. No route → GPS off.
        "Pickleball" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        // Bowling (D#850): HC has no type for it → writes as "Other", stays "Bowling" on our own
        // rows. No route → GPS off.
        "Bowling" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        // #714 indoor treadmill walk. HC has a treadmill-RUN type but no treadmill-WALK type, so this
        // rides on plain WALKING for writeback while keeping its own "Treadmill walk" label. Kept OUT of
        // DISTANCE_TYPES so GPS defaults off (an indoor session has no route).
        "Treadmill walk" to EX.EXERCISE_TYPE_WALKING,
        // #714 bodybuilding. No dedicated HC type, so it rides on STRENGTH_TRAINING for writeback and
        // keeps "Bodybuilding" on our own rows. No route → GPS off.
        "Bodybuilding" to EX.EXERCISE_TYPE_STRENGTH_TRAINING,
    )

    /** Types where a route makes sense -> GPS defaults on. */
    val DISTANCE_TYPES: Set<Int> = setOf(
        EX.EXERCISE_TYPE_RUNNING,
        EX.EXERCISE_TYPE_WALKING,
        EX.EXERCISE_TYPE_HIKING,
        EX.EXERCISE_TYPE_BIKING,
        EX.EXERCISE_TYPE_SWIMMING_OPEN_WATER,
        EX.EXERCISE_TYPE_ROWING,
        // Snow sports cover ground → a route makes sense, GPS defaults on. (#768)
        EX.EXERCISE_TYPE_SKIING,
        EX.EXERCISE_TYPE_SNOWBOARDING,
    )

    fun nameFor(type: Int): String = NAMES[type] ?: "Workout"
}
