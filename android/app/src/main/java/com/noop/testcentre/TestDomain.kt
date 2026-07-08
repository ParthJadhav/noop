package com.noop.testcentre

/**
 * The domain tag stamped on each Test Centre log line and used to filter the export bundle.
 *
 * Direct twin of the Swift TestDomain (StrandAnalytics/TestDomain.swift), kept byte-aligned by a
 * parity test (spec section 10). Phase 1 declares the full id set so later phases only flip emitters
 * on; only SLEEP and BATTERY have emitters wired now. UNIVERSAL is the preamble plus the three derived
 * traces; MASTER is "log everything". Note IMPORT carries the wire id "import" (the Swift dataImport
 * case avoids the Swift reserved word; Kotlin uses IMPORT directly but keeps the same id string).
 */
enum class TestDomain(val id: String) {
    UNIVERSAL("universal"), SLEEP("sleep"), CONNECTION("connection"), WORKOUTS("workouts"),
    DISPLAY("display"), IMPORT("import"), STEPS("steps"), NOTIFICATIONS("notifications"),
    BATTERY("battery"), RECOVERY("recovery"), HRV("hrv"), SOURCES("sources"),
    STRESS("stress"), LONGEVITY("longevity"), MASTER("master");

    /** GitHub label the deep-link self-applies, e.g. "test:sleep". MASTER becomes "test:all". */
    val githubLabel: String get() = if (this == MASTER) "test:all" else "test:$id"
}
