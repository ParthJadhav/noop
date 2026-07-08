import Foundation
import WhoopProtocol
import StrandAnalytics

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?
    /// Which family's framing to decode with. Set per connection by BLEManager. WHOOP 5.0/MG frames
    /// use the CRC16/offset-8 envelope; the biometric field decode for puffin is still a stub, so
    /// WHOOP 5 custom frames currently surface only their envelope (live HR/battery come from the
    /// standard 0x2A37/0x2A19 profiles instead).
    var family: DeviceFamily = .whoop4

    public init(state: LiveState) {
        self.state = state
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    public func handle(frame: [UInt8]) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if parsed.crcOK == false { return }

        // #987: stamp frame liveness for the Connection readout's "last frame" row. A plain (non-
        // published, see LiveState) Int write, so the raw flood costs no re-renders here.
        state.noteFrameRouted()

        // live perf: only republish when the value actually changed. The type-43 raw flood arrives
        // continuously and repeats the SAME frame type, and each `@Published` write fires
        // `objectWillChange` → a full LiveView.body re-eval (these frames are separate BLE
        // notifications, so SwiftUI can't coalesce them). Guarding collapses a steady flood to one
        // re-eval per genuine change instead of one per frame.
        if state.lastFrameType != parsed.typeName {
            // Connection test mode: one tagged line per genuine frame-TYPE transition (not per frame - the
            // existing change-guard naturally throttles it), so a report shows the live frame cadence. Gated
            // zero-cost: the .connection bool is read before any string is built, and we only ever reach here
            // on a real type change, so the raw flood is collapsed exactly as the perf guard intends.
            if TestCentre.active(.connection) {
                state.append(log: "frameTiming type=\(parsed.typeName) t=\(Int(Date().timeIntervalSince1970))s",
                             domain: .connection)
            }
            state.lastFrameType = parsed.typeName
        }

        switch parsed.typeName {
        case "REALTIME_DATA", "REALTIME_RAW_DATA":
            // Reject 0 / out-of-range spikes from realtime streams; AppModel medians the rest.
            // Some firmware exposes live BPM only on the R10/R11 raw stream after acknowledging
            // BLE_REALTIME_HR_ON, so the UI can consume it even though persistence still ignores raw43.
            // live perf: skip the publish when HR is unchanged — the raw flood carries the same HR
            // byte across many frames, so an unguarded write re-renders the whole console for nothing.
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220, state.heartRate != hr {
                state.heartRate = hr
                // Sleep & Rest test mode (Group E): bank the live HR sample for the readout's HR-density
                // figure. Gated on the zero-cost active() Bool, so this is a no-op when the mode is off.
                if TestCentre.active(.sleep) {
                    state.recordSleepLiveHr(ts: Int(Date().timeIntervalSince1970), bpm: hr)
                }
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            // setRRIntervals also feeds the Live console's rolling rrRecent buffer.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.setRRIntervals(rr)
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }
            // Firmware version from the connect handshake: WHOOP 4.0 decodes `fw_harvard`
            // (REPORT_VERSION_INFO), WHOOP 5/MG decodes `fw_version` (GET_HELLO). Take whichever the
            // decoder produced; one branch covers both families. It's stable for the connection, so
            // only republish on a real change. Surfaced on the Devices card.
            if let fw = parsed.parsed["fw_version"]?.stringValue ?? parsed.parsed["fw_harvard"]?.stringValue,
               state.strapFirmware != fw {
                state.strapFirmware = fw
            }
            // Advertising-name replies (WHOOP 4.0 / Harvard). GET (cmd 76) carries the current name in
            // its payload; SET (cmd 77) carries only a result byte. The schema has no field decode for
            // either, so pull them straight from the frame bytes. The COMMAND_RESPONSE inner is
            // [type,seq,cmd,origin_seq,result,payload…] starting at offset 4, with crc32 at `length`.
            // cmdName carries a "(rawValue)" suffix (Schema.enumName appends it, e.g.
            // "GET_ALARM_TIME(67)"), so match by prefix like every other cmdName consumer in the
            // codebase - never by equality, which is silently dead.
            if family == .whoop4, let cmd = parsed.cmdName {
                if cmd.hasPrefix("GET_ADVERTISING_NAME_HARVARD") {
                    if let name = Self.advertisingName(in: frame), !name.isEmpty {
                        state.advertisingName = name
                    }
                } else if cmd.hasPrefix("SET_ADVERTISING_NAME_HARVARD") {
                    state.renameStatus = Self.renameAck(for: Self.commandResultByte(in: frame))
                } else if cmd.hasPrefix("GET_ALARM_TIME") {
                    // Arm-readback diagnostic (#401 close-out): armStrapAlarm follows every WHOOP 4.0 arm
                    // with GET_ALARM_TIME (67) so the log proves what the STRAP believes is armed, not
                    // just what we sent. LOG-ONLY, never gates behaviour: the 4.0 response layout is
                    // undocumented, so the decode is defensive (SET-mirror form first, bare u32 second,
                    // plausibility-gated) and an unrecognised payload still logs its raw hex - which is
                    // exactly as diagnostic. Labelled "strap reports", not "verified" (one firmware's
                    // answer format must never mislead a triage).
                    if let epoch = Self.armedAlarmEpoch(in: frame) {
                        state.append(log: "Alarm: strap reports armed for \(Self.alarmLocalTime(epoch: epoch)) (epoch \(epoch))")
                    } else {
                        state.append(log: "Alarm: strap answered the alarm readback with an unrecognised payload (raw \(Self.commandResponsePayloadHex(in: frame) ?? "empty")) - layout undocumented, log-only")
                    }
                }
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                // #92: don't surface the live-HR stream toggle (BLE_REALTIME_HR_ON/OFF) in "Last
                // Event" — it's internal plumbing that fires on every connect and just confuses
                // users. Every other event (wrist, double-tap, battery, bonded…) still shows.
                if !ev.hasPrefix("BLE_REALTIME_HR") {
                    state.lastEvent = ev
                }
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                // Belt-and-suspenders: a BLE_BONDED event confirms the link is bonded.
                // (BLEManager also sets bonded=true when the confirmed write succeeds.)
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
                // BATTERY_LEVEL events carry the only charging flag the strap reports (wire
                // observation: u8 bit0, ~every 8 min on captured links). Flag only — battery %
                // keeps its family-specific source (#77). No freshness gate needed here: this
                // path never sees historical replay (backfill skips handle(frame:), see below).
                if ev.hasPrefix("BATTERY_LEVEL"),
                   let ch = parsed.parsed["battery_charging"]?.intValue {
                    state.charging = (ch != 0)
                }
                // Physical inputs the strap exposes — live only (this path never sees historical
                // replay, which goes through the Backfiller). Event strings are "NAME(rawValue)".
                if ev.hasPrefix("DOUBLE_TAP") {
                    state.onDoubleTap?()
                } else if ev.hasPrefix("WRIST_ON") {
                    if !state.worn { state.worn = true; state.onWristChange?(true) }
                } else if ev.hasPrefix("WRIST_OFF") {
                    if state.worn { state.worn = false; state.onWristChange?(false) }
                } else if ev.hasPrefix("STRAP_DRIVEN_ALARM_EXECUTED") {
                    // Fire observability (#401 close-out): Android has always logged this line
                    // (WhoopBleClient.handleFrame); iOS/macOS silently ran the callback, which is why a
                    // "did it actually buzz?" report could never be settled from a strap log ("log
                    // successes" forensics rule). With the armed line (armStrapAlarm) and the readback
                    // line (GET_ALARM_TIME) this makes every future report one-log decidable. The re-arm
                    // below writes a fresh "armed" line, so the two read as one sequence, not a bug.
                    state.append(log: "Alarm: strap-driven wake fired (event 57), re-arming the next day's instant")
                    // The strap fired its firmware smart alarm → re-arm the next day's instant (the
                    // alarm is a single absolute time with no recurrence). Belt-and-suspenders to the
                    // daily/foreground re-arm in AppModel, since this event isn't always observed.
                    state.onSmartAlarmFired?()
                }
            }

        default:
            break
        }
    }

    // MARK: - Advertising-name decode (WHOOP 4.0 / Harvard)

    /// Offset of the inner `[type][seq][cmd][origin_seq][result][payload…]` in a WHOOP 4.0 frame:
    /// SOF(1) + length(2) + crc8(1). Mirrors `WhoopCommand.frame` / `parseFrame`.
    private static let whoop4InnerOffset = 4

    /// Extract the advertising name from a GET_ADVERTISING_NAME COMMAND_RESPONSE: printable ASCII from
    /// the payload that follows [type,seq,cmd,origin_seq,result] (payload starts at inner+5), up to the
    /// crc32 trailer at `length`. Mirrors the whoop-rename prototype's `extract_name`. nil if too short.
    static func advertisingName(in frame: [UInt8]) -> String? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)        // crc32 starts here
        let start = whoop4InnerOffset + 5                        // skip type,seq,cmd,origin_seq,result
        guard length <= frame.count, start < length else { return nil }
        let printable = frame[start..<length].filter { $0 >= 32 && $0 < 127 }
        return String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The result byte of a COMMAND_RESPONSE: inner offset + 4 ([type,seq,cmd,origin_seq] then result).
    static func commandResultByte(in frame: [UInt8]) -> Int? {
        let idx = whoop4InnerOffset + 4
        return idx < frame.count ? Int(frame[idx]) : nil
    }

    // MARK: - Alarm-readback decode (WHOOP 4.0, GET_ALARM_TIME cmd 67 - #401 close-out)

    /// The payload of a WHOOP 4.0 COMMAND_RESPONSE: the bytes after [type,seq,cmd,origin_seq,result]
    /// (payload starts at inner+5) up to the crc32 trailer at `length`. Same envelope walk as
    /// `advertisingName(in:)`. nil when the frame is too short to carry any payload.
    nonisolated static func commandResponsePayload(in frame: [UInt8]) -> [UInt8]? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)        // crc32 starts here
        let start = whoop4InnerOffset + 5                        // skip type,seq,cmd,origin_seq,result
        guard length <= frame.count, start < length else { return nil }
        return Array(frame[start..<length])
    }

    /// Space-separated lowercase hex of a COMMAND_RESPONSE payload, for the raw-hex diagnostic fallback
    /// when a readback payload doesn't decode. nil when the frame carries no payload.
    nonisolated static func commandResponsePayloadHex(in frame: [UInt8]) -> String? {
        guard let payload = commandResponsePayload(in: frame), !payload.isEmpty else { return nil }
        return payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Plausibility gate for a readback epoch: a real armed alarm is near-now, so anything outside
    /// 2017..2100 (1_500_000_000 to 4_102_444_800) is garbage or a strap with no alarm armed - the
    /// caller falls back to the raw-hex line rather than logging a misleading date. Bounds inclusive.
    nonisolated static func isPlausibleAlarmEpoch(_ epoch: UInt32) -> Bool {
        // Both bounds fit UInt32 (max 4_294_967_295), so the range infers as ClosedRange<UInt32>.
        (1_500_000_000...4_102_444_800).contains(epoch)
    }

    /// Extract the armed-alarm epoch from a GET_ALARM_TIME (cmd 67) COMMAND_RESPONSE, defensively.
    /// The WHOOP 4.0 response layout is UNDOCUMENTED, so this tries the two shapes the firmware could
    /// plausibly answer with - the SET_ALARM_TIME mirror (`[form 0x01][u32 LE epoch]…`, matching the
    /// 9-byte payload we arm with) first, then a bare leading u32 LE - and accepts a candidate only when
    /// it passes `isPlausibleAlarmEpoch`. Anything else returns nil and the caller logs raw hex instead.
    /// Pure and CoreBluetooth-free so golden tests pin it (AlarmReadbackDecodeTests).
    nonisolated static func armedAlarmEpoch(in frame: [UInt8]) -> UInt32? {
        guard let payload = commandResponsePayload(in: frame) else { return nil }
        func u32le(at i: Int) -> UInt32? {
            guard payload.count >= i + 4 else { return nil }
            return UInt32(payload[i])
                | (UInt32(payload[i + 1]) << 8)
                | (UInt32(payload[i + 2]) << 16)
                | (UInt32(payload[i + 3]) << 24)
        }
        if payload.first == 0x01, let e = u32le(at: 1), isPlausibleAlarmEpoch(e) { return e }
        if let e = u32le(at: 0), isPlausibleAlarmEpoch(e) { return e }
        return nil
    }

    /// Local wall-clock render for the readback log line, matching armStrapAlarm's "EEE HH:mm zzz"
    /// format so the armed + strap-reports lines read as one sequence.
    nonisolated static func alarmLocalTime(epoch: UInt32) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm zzz"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// Human-readable ack for a SET_ADVERTISING_NAME result byte (same codes as the prototype:
    /// 0 Failure, 1 Success, 2 Pending, 3 Unsupported).
    static func renameAck(for result: Int?) -> String {
        switch result {
        case 1:  return "Renamed, your strap reboots to apply the new name."
        case 0:  return "The strap rejected the rename (failure)."
        case 2:  return "Rename pending…"
        case 3:  return "This strap firmware doesn't support renaming."
        default: return "Rename sent - re-scan to confirm the new name."
        }
    }

    /// Live-gesture freshness window (s). A DOUBLE_TAP / WRIST_ON / WRIST_OFF fires its live handler only
    /// if its event_timestamp is within this of `now` — so a *replayed historical* gesture during a
    /// backfill offload (old ts) is ignored, but a real-time one fires even mid-sync.
    static let liveGestureWindowSeconds = 45

    /// Parse an EVENT frame and fire ONLY the live physical-gesture handlers (double-tap / wrist) iff the
    /// event is recent. Called for offload frames during backfill — where `handle(frame:)` is skipped —
    /// so a real-time gesture still works mid-offload (#69: the 5/MG offload runs for minutes). `now`
    /// MUST be in the SAME clock domain as event_timestamp (the strap's RTC): the caller passes the
    /// strap's own clock-now (BLEManager.strapClockNow), so the gate is robust to a grossly-stale strap
    /// RTC (fix #72) — a live gesture is ~now in the strap's clock, a historical replay is old in it.
    /// Deliberately does NOT touch lastEvent / sync trigger / bonded / battery — those stay on the normal
    /// handle(frame:) path, so backfill UI behaviour is otherwise unchanged.
    func dispatchLiveGestureIfFresh(frame: [UInt8], now: Int = Int(Date().timeIntervalSince1970)) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok, parsed.crcOK != false else { return }
        guard parsed.typeName == "EVENT", let ev = parsed.parsed["event"]?.stringValue else { return }
        guard let ts = parsed.parsed["event_timestamp"]?.intValue, ts > 0 else { return }   // fail closed
        guard abs(now - ts) <= FrameRouter.liveGestureWindowSeconds else { return }
        if ev.hasPrefix("DOUBLE_TAP") {
            state.onDoubleTap?()
        } else if ev.hasPrefix("WRIST_ON") {
            if !state.worn { state.worn = true; state.onWristChange?(true) }
        } else if ev.hasPrefix("WRIST_OFF") {
            if state.worn { state.worn = false; state.onWristChange?(false) }
        }
    }
}
