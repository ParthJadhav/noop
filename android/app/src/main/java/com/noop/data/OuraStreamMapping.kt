package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.protocol.SkinTempSample
import com.noop.protocol.Spo2Sample
import com.noop.protocol.Streams
import com.noop.protocol.WhoopEvent

/**
 * Pure, JVM-testable mapping from the Oura ring's decoded [OuraEvent]s onto the datastore's
 * protocol [Streams] shape, so the WHOOP-isolated `OuraLiveSource` can persist its samples through
 * the SAME [WhoopRepository.insert] path (via [StreamPersistence.toBatch]) the WHOOP pipeline uses,
 * without duplicating row construction in the (untestable) app/BLE target. Kotlin twin of the Swift
 * `OuraStreamMapping` (WhoopStore), built from the architecture plan's section-4 table.
 *
 * HONEST-DATA INVARIANT (hard): we surface ONLY the ring's decoded raw signals and its OWN open
 * event tags. We never read or display Oura's encrypted readiness/sleep scores. NOOP computes its
 * own Charge/Rest downstream:
 *   - the IBI stream becomes [Streams.rr], from which RecoveryScorer reconstructs NOOP's OWN RMSSD;
 *   - the HR stream feeds resting-HR + strain;
 *   - the ring's open 0x5D HRV tag is recorded as an `OURA_HRV` diagnostic event carrying ITS RAW
 *     decoded fields (time_ms/b1/b2) ONLY, never a fabricated rmssd_ms (the int8 b1/b2 byte->ms
 *     scale is not Tier-A; NOOP's scoring RMSSD comes from `rr`, not this tag);
 *   - the open sleep-phase tags become `OURA_SLEEP_PHASE` events folded into a sleep session.
 *
 * Each event carries a ring-clock `ringTimestamp` (not wall-clock). To stay pure and avoid baking a
 * clock model in here, the caller supplies an [anchor] resolving a ring timestamp to wall-clock unix
 * seconds (driven by the ring's 0x42/0x85 time-sync events upstream). When the anchor cannot place a
 * record (anchor returns null), the sample is DROPPED rather than stamped with a guessed time
 * (honest-data invariant), a ts-less biometric row is unstorable anyway.
 */
object OuraStreamMapping {

    /** The event `kind` recorded for the ring's own open HRV (0x5D) tag. Must match Swift exactly. */
    const val EVENT_HRV = "OURA_HRV"

    /** The event `kind` recorded for the ring's own open sleep-phase (0x49.../0x58) tags. */
    const val EVENT_SLEEP_PHASE = "OURA_SLEEP_PHASE"

    /**
     * Fold a batch of decoded [events] into a protocol [Streams] for one flush. [anchor] maps a
     * ring-clock timestamp to wall-clock unix seconds (null => drop the sample). Pure: no BLE, no DB,
     * no clock, fully JVM-unit-testable. Tier-B events never reach scoring; if any leak in (they only
     * appear when the driver's allowTierB is set), they are ignored here so they cannot fabricate a
     * stream value.
     */
    fun streams(events: List<OuraEvent>, anchor: (Long) -> Int?): Streams {
        val out = Streams()
        for (ev in events) {
            when (ev) {
                is OuraEvent.Hr -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.hr.add(com.noop.protocol.HrSample(ts, ev.value.bpm))
                }

                is OuraEvent.Ibi -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.rr.add(com.noop.protocol.RrInterval(ts, ev.value.ibiMs))
                }

                is OuraEvent.Hrv -> {
                    // The ring's OWN open HRV tag, recorded raw for diagnostics/parity. NOT Oura's
                    // readiness score, and NOT used as NOOP's RMSSD (that comes from `rr`).
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_HRV,
                            payload = linkedMapOf(
                                "time_ms" to ev.value.timeMs,
                                "b1" to ev.value.b1,
                                "b2" to ev.value.b2,
                            ),
                        ),
                    )
                }

                is OuraEvent.Spo2 -> {
                    // The ring exposes ONE combined SpO2 reading (not separate red/ir channels): its
                    // raw value goes in `red`; `ir` stays 0 (an unread channel, never a fabricated
                    // second reading). `unit` carries the decoder's own scale tag so downstream never
                    // assumes a percentage, mirroring the Swift twin's SpO2Sample(unit:).
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.spo2.add(Spo2Sample(ts = ts, red = ev.value.value, ir = 0, unit = ev.value.unit))
                }

                is OuraEvent.Temp -> {
                    // The ring exposes skin temperature in degrees C; the store's raw integer uses the
                    // codebase-wide CENTI-degree-C convention (°C = raw / 100, the scale the analytics
                    // reader divides by), so persist celsius * 100 and tag the unit. PARITY: the Swift
                    // twin stores the IDENTICAL celsius * 100, so the same decoded celsius yields the same
                    // raw integer on both platforms.
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.skinTemp.add(
                        SkinTempSample(
                            ts = ts,
                            raw = Math.round(ev.value.celsius * 100.0).toInt(),
                            unit = "centi_c",
                        ),
                    )
                }

                is OuraEvent.SleepPhaseEvent -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_SLEEP_PHASE,
                            payload = linkedMapOf<String, Any?>(
                                "phase" to ev.value.stage.raw,
                                "index" to ev.value.index,
                            ),
                        ),
                    )
                }

                is OuraEvent.Battery -> {
                    // Live battery percent. No ring timestamp on a battery reading (it is a command
                    // response), so it is stamped by the live source's `onBattery` path, not persisted
                    // as a tied-to-ts row here. Leave the batch's battery list empty (honest: no faked ts).
                }

                // Motion / state / time-sync / rtc / debug / TierB / ActivityInfo never map onto a
                // scored stream. In particular the 0x50 activity/MET decode (PR #960) NEVER mints a
                // `steps` row: the formula is third-party and unvalidated (Tier B, OURA_PROTOCOL.md
                // s6.13), and MET is not a step count - fabricating one would break the honest-data
                // invariant and the per-source day-owner rules.
                else -> Unit
            }
        }
        return out
    }
}
