package com.noop.ui

import com.noop.analytics.Sport
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the Today "workout in progress" indicator's pure pieces (the Android half of the iOS
 * ActiveWorkoutIndicatorTests): the shared elapsed-clock formatter, INCLUDING the H:MM:SS roll-over past one
 * hour, plus the sport label + visibility the card derives straight from [AppViewModel.ActiveWorkout]. Pure /
 * JVM, so no ViewModel (Context) or Compose host is stood up. The one-shot present/consume contract lives on
 * the AndroidViewModel and is verified by the instrumented path; here we pin the value logic the card shows.
 */
class ActiveWorkoutIndicatorTest {

    private fun sport(name: String) = Sport(exerciseType = 0, name = name, isDistanceSport = false)

    private fun workout(startMs: Long, sportName: String) =
        AppViewModel.ActiveWorkout(startMs = startMs, sport = sport(sportName), gpsEnabled = false)

    @Test
    fun elapsedClock_formatsMinutesSecondsUnderAnHour() {
        assertEquals("0:00", elapsedClock(0))
        assertEquals("1:05", elapsedClock(65))
        // 59:59 is the last reading before the hour roll-over.
        assertEquals("59:59", elapsedClock(59 * 60 + 59))
    }

    @Test
    fun elapsedClock_clampsNegativeToZero() {
        assertEquals("0:00", elapsedClock(-5))
    }

    @Test
    fun elapsedClock_extendsToHoursPastOneHour() {
        // Exactly one hour rolls over to H:MM:SS, NOT "60:00".
        assertEquals("1:00:00", elapsedClock(3_600))
        // 1h 23m 07s reads "1:23:07", not "83:07".
        assertEquals("1:23:07", elapsedClock(3_600 + 23 * 60 + 7))
        // Multi-hour stays correct (2h 05m 09s).
        assertEquals("2:05:09", elapsedClock(2 * 3_600 + 5 * 60 + 9))
    }

    @Test
    fun activeWorkout_carriesSportAndStartForTheCard() {
        // The card reads the sport label + start directly off the active workout; a null workout means the
        // indicator renders nothing (the `activeWorkout?.let { }` gate in TodayScreen).
        val w = workout(startMs = 100_000, sportName = "Cycling")
        assertEquals("Cycling", w.sport.name)

        // Elapsed shown for a workout that started 1h 23m 07s before "now" matches the shared formatter.
        val nowMs = w.startMs + (3_600 + 23 * 60 + 7) * 1000L
        val elapsedS = ((nowMs - w.startMs) / 1000).coerceAtLeast(0)
        assertEquals("1:23:07", elapsedClock(elapsedS))
    }
}
