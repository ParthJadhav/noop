# Live Sessions — Design Spec

**Status:** design locked 2026-07-04 (full autonomy granted). Next: implementation plan.
**Goal:** During a workout, NOOP holds you inside a recovery-gated heart-rate band and coaches you with WHOOP strap haptics, silence-first, fully on-device.
**Platforms:** macOS + iOS (shared Swift) and Android (Kotlin hand-port). Coaching logic lives in a shared, pure, unit-tested engine; only BLE + haptic transport differs per platform.

---

## 1. The USP, honestly

NOOP does **not** win on the raw concept. WHOOP's own Strain Coach already gates a target on Recovery and buzzes the strap. The daylight nobody else holds at once:

- **A continuous live band held the whole session** (WHOOP buzzes once, at a cumulative-strain milestone; we hold a band the entire time).
- **Fully local, no account, no subscription** (every audio-based live coach dies in a gym; every "daily readiness" system hands you a *fixed* zone and stops).
- **Silent-guardian restraint** — on a sensible day it never buzzes at all.

Ownable phrase: **recovery-gated + continuous live band + on-strap haptic + fully local.** Marketing leads with steady-state ("don't overcook your easy days"); interval precision is positioned as "sharper with a heart-rate strap."

---

## 2. Design principles (load-bearing, not decoration)

1. **Silence-first, but silence must be legible.** In-band = no buzz, ever. But a correctly-silent guardian looks identical to a dead app, so the ring *breathes* with each live HR sample and a "time held in band" fill grows all session. A glance proves it's working.
2. **Recovery-honest, and visibly so.** Show the recovery claim once at start ("today's ceiling is lower, Charge is 41%") and again on the summary, so it can never be mistaken for a fixed-zone alarm.
3. **Never fabricate a number.** Coach on a smoothed trend; reject impossible samples; on a real stream dropout the ring greys and coaching **stops**. This is the NOOP identity.
4. **Works with just a WHOOP, honest that it's the hard case.** Wrist optical is weakest on fast intensity changes; defended by grace windows, trend smoothing, shape-aware triggers. A chest strap / power meter sharpens the guardian, never changes the model or adds UI.
5. **One wrong buzz is unforgivable; a missed buzz is fine.** Trust is asymmetric. Bias hard toward not buzzing when unsure. Hysteresis, sustained dwell, cool-downs are core, not polish.
6. **A buzz vocabulary learnable in one session.** Exactly two signals, unmistakable by feel, no screen needed to decode them.

---

## 3. The v1 experience — "Silent Guardian"

Chosen over a richer "Guided Session" and an "Ambient always-on" variant (judged 8.6/10) with two mandatory grafts folded in.

- **Start (one tap, zero config).** A `Start session` button on Today, directly under this morning's Charge. Tap → near-empty screen: one soft ring, lit, and one line: *"Guarding your session. Silence means you're on track."* No zone picker, no target field, no sport selector. Everything derives from Charge + the strap-derived HR profile.
- **The one honest sentence about today** (first few seconds, then fades): *"Today's ceiling is lower, Charge is 41%."* / *"Charge is 82%, you've got room to send it."* Appears every session.
- **Proof-of-guarding (graft, core v1).** In-band, the ring breathes on each arriving HR sample; a thin "time held in band" fill accumulates all session. Silence gets a visible, earned artifact so a correct-silent session never looks like a crash. Single most important addition.
- **During.** Phone pocketed. Ring encodes state by colour + fill: in-band (lit, breathing), below (dim), above (hot), plus session time. **No live HR number by default** (long-press reveals it). State readable in under half a second without reading.
- **Grace + shape-aware triggers.** No "too easy" buzz in the first 60 s or ~45 s after a sharp climb. Ease-off fires only on a **fast step-change** breach that is **sustainedly** high past grace, never on honest slow drift.
- **End + look-back (graft, the payoff).** Tap to end (or auto-end on wrist-off / long HR-zero). Summary credits the invisible saves:
  - Streak/habit line: *"14 sessions guarded, you've honoured your ceiling on every low-Charge day this week."*
  - Surfaced near-misses: *"Twice you drifted toward a ceiling a 41% day can't pay for, you eased back before I had to buzz."*
  - Plain numbers: time in band / below / above, nudge count, ease-off count, one plain-English verdict.
  - One-tap honesty check: thumbs-down a buzz you thought was wrong (feeds the plausibility model, gives a non-silent off-ramp).
  - Persisted to local SQLite. Nothing leaves the phone.
- **Optional enrichment (no new UI).** Paired BLE HR chest strap → becomes the smoothed source (faster, shorter grace). Cycling power meter → band becomes a **power band**, identical silent-guardian behaviour.

**Out of v1 on purpose:** interval/structured-workout builder, pace/cadence coaching, manual zone editing, live graphs, multi-sport profiles, auto-detect of workout type. Ship the loop, not the dashboard.

---

## 4. Recovery → target logic

- **Zone model: %HRR (Karvonen).** `targetHR = restingHR + fraction × (HRmax − restingHR)`. %HRR ≈ %VO2reserve (ACSM 1998), truer than %HRmax across fitness levels. NOOP already derives resting HR; HRmax comes from strap-derived data if available, else an age estimate **clearly flagged** on the summary (never implying precision we don't have).
- **Band, not a line:** `[floor, ceiling]` in %HRR. Two-sided vocabulary needs two edges.
- **Charge scales ceiling + width:** low Charge → lower ceiling, narrower band ("today can't pay for hard"); high Charge → higher ceiling, wider band ("room to send it"). Ship a deliberately **conservative** curve v1 and widen with data, never the reverse. Exact anchors tuned during the spike session, not invented here.
- **Over-reach trigger (ease-off)** fires only when all hold: smoothed (10–15 s trailing median) HR above ceiling by a real margin; breach came from a fast step-change (not slow drift); HR sustainedly elevated (~20–30 s dwell) past grace.
- **Bounded ceiling-drift (in v1):** if HR sits just over the ceiling steadily and plausibly for long enough, the ceiling nudges up slightly rather than nagging, bounded, never below the recovery-set conservative floor. Main defence against a false ease-off on a genuinely strong day.
- **Never-fabricate guards:** samples above HRmax / impossible jumps rejected before they can trigger a cue; on stream dropout the ring greys and coaching stops. Instantaneous number is never the trigger and never shown by default.

---

## 5. Buzz language

Silence-first. Two signals, on the shipped Haptic Clock multi-pattern engine.

| State | Signal | Meaning |
|---|---|---|
| In band | nothing, ever | you're honouring today; silence is the reward |
| Too easy for today | soft double-tap (2-loop, gentle) | give a bit more |
| Too hard for today | firm triple (3-loop, heavier) | ease off, today can't pay for this |

Distinguishable by feel alone, mid-effort. Validate distinguishability during the spike.

**Rate limits:** dwell ~20–30 s out-of-band by a margin before any buzz; ≥45–60 s cool-down before the same direction repeats; **re-entry into the band is silent** (no "you're fixed" buzz); grace suppression as in §3.

---

## 6. Architecture

- **`LiveSessionEngine` (pure, shared, unit-tested).** Input: a stream of `(timestamp, hr, optionalPower)` samples + today's Charge + the user's HR profile (resting, HRmax). Output: a stream of `SessionState` (band edges, in/below/above, breathing pulse, accumulated in-band time) and discrete `CoachCue` events (`.pushNudge`, `.easeOff`) subject to all the smoothing / grace / dwell / cool-down / hysteresis rules. **No I/O, no BLE, no UI, no clock-of-its-own** (time is passed in), so it is fully deterministic and TDD-able with synthetic HR traces on every platform. Swift version first, Kotlin twin ported from the same test vectors.
- **Transport (per platform, thin).** Live-HR subscription (existing live path) feeds the engine; `CoachCue`s map to the existing haptic-command path (Haptic Clock engine). This is the only hardware-touching code and the only thing the spike gates.
- **Persistence.** A `LiveSession` record (start/end, band history, cue log, in/below/above totals, Charge-at-start, HR source) in the existing local SQLite store. Feeds the summary + streak.
- **Today integration.** `Start session` entry under the Charge ring; a live session screen; a summary sheet on end. Reuse the existing design-system ring / liquid aesthetic.
- **Background + battery.** Reuse the existing GPS-workout foreground-service / live-activity plumbing to keep BLE + haptics alive with the phone pocketed. Measure battery over a real session, state it honestly if material.

---

## 7. The transport risk (smaller than first framed; proven by beta, not by a test session)

The original framing overstated this. Two facts shrink it:

- **Both halves are already proven separately.** Streaming live HR for an hour is exactly what the Live screen does. Firing a buzz pattern on demand is exactly what the Haptic Clock does. The only genuinely new thing is the two coexisting, backgrounded, over a sustained period.
- **Silence-first means a tiny command rate.** With ~20–30 s dwell + 45–60 s cool-downs, a well-behaved session sends a *handful* of buzzes across an hour, not a stream. The "hammering the strap under load" fear never occurs by design, so throttling risk is low.

**No workout, no bike, and no test session from the maintainer.** The maintainer has no bike and won't run a session, so this feature must never depend on them testing it. Instead:

1. **Engineer the drop-tolerance in.** Silence-first already makes a *dropped* buzz harmless (a *wrong* buzz is the only unforgivable failure, and that's an accuracy concern, handled in §4). The transport queues one pending cue, drops stale cues rather than backing up, and if the strap NAKs/throttles a buzz it is simply skipped, never retried into a burst.
2. **Optional sedentary self-check (nice-to-have, not a gate).** The buzz-while-streaming loop can be exercised fully at rest, strap on a wrist at a desk, no exercise needed, if we ever want bench numbers. Not required to ship.
3. **Prove it in the wild via a BETA flag.** Ship the live-coaching path clearly labelled **beta / experimental** (NOOP's established pattern for safe-but-unproven-in-the-field features: band sleep-state, Oura, WHOOP 5/MG capture). Real users on real bikes/runs exercise the sustained loop on both strap generations; the feature degrades gracefully if the transport ever misbehaves, and we harden from real reports. No telemetry (offline-first); we rely on opt-in bug reports / Test Centre exports.

---

## 8. Build sequence

Engine-first, fully hardware-free, no test session from the maintainer at any point.

1. **`LiveSessionEngine` (Swift package) + full unit-test suite** — synthetic HR traces: warm-up, steady Zone 2, intervals, honest drift, stream dropout, above-HRmax spikes, cool-down/dwell/hysteresis. Headless swift-test, no strap. This is the bulk of the real logic and it is 100% testable on the bench.
2. **Kotlin twin** ported against the same test vectors (JVM tests).
3. **Transport adapter** — wire the engine's `CoachCue`s to the existing Haptic Clock buzz API and subscribe it to the existing live-HR publisher; drop-tolerant (skip, never burst-retry). Reuse the existing active-workout / Live Activity / Android foreground-service plumbing for background survival.
4. **Wiring + UI** — Today entry, live session screen, summary, `LiveSession` persistence record + migration.
5. **Ship the live-coaching path as clearly-labelled BETA** so real users' real workouts exercise the sustained transport loop on both strap generations; harden from opt-in reports. Steady-state is the hero; interval precision is "sharper with a HR strap."
6. **Central cross-platform build-verify + lockstep release.**

---

## 9. Decisions locked (were open questions)

- Charge→zone curve: conservative v1, tune with data.
- HRmax: strap-derived else age-estimate, flagged.
- Ceiling-drift: **in** v1 (minimal, bounded).
- Start: **manual only** v1 (matches manual-first); auto-detect later.
- Buzz patterns: reuse Haptic Clock 2-loop / 3-loop, validate distinguishability in the spike.
- Positioning: steady-state hero, interval precision = "sharper with a HR strap."

## 10. Honest weakness (recorded)

WHOOP-only is the primary promise and the weakest sensor case, on intervals specifically. The §4 mitigations make it viable, not effortless. If the spike shows optical is too noisy to coach on safely with just a WHOOP, the honest fallback is to keep WHOOP-only to steady-state (Zone 2 / tempo) and require a HR strap for interval-grade coaching. Decide after the spike, before over-promising.
