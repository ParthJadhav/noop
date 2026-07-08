import Foundation

// Framing: the two framing layers that ride on the same characteristics (OURA_PROTOCOL.md s2).
//   - Outer command / command-response frame:  op(1) len(1) body(len)        (s2.1)
//   - Extended / secure-session frame (0x2F):   2F len subop subop-body       (s2.2)
//   - Inner event record (TLV):                 type(1) len(1) rt:u32LE payload (s2.3)
// All multi-byte integers are little-endian unless a decoder states otherwise (OURA_PROTOCOL.md s2.1).
//
// The first byte disambiguates layers: a value present in the opcode table (s4) is an outer frame;
// otherwise it is an inner event record. The OuraDriver routes on this; Framing exposes pure parsers
// plus a defensive Reassembler that buffers partial trailing bytes across notifications (s2.4).
//
// Platform-pure, value types only. Facts cited per OURA_PROTOCOL.md s2.

// MARK: - Outer command / response frame

/// A parsed outer frame: `op len body` (OURA_PROTOCOL.md s2.1). `body` is the `len` bytes after the
/// header. Multiple outer frames may be packed into one notification; the consumer loops 2+len.
public struct OuraOuterFrame: Equatable, Sendable {
    public let op: UInt8
    public let body: [UInt8]
    public init(op: UInt8, body: [UInt8]) { self.op = op; self.body = body }

    /// Total wire length of this frame (header + body).
    public var totalLength: Int { 2 + body.count }
}

/// A parsed secure-session sub-frame: the first body byte of a 0x2F frame is the sub-op
/// (OURA_PROTOCOL.md s2.2 / s4.2). `subBody` is the remaining body bytes after the sub-op.
public struct OuraSecureFrame: Equatable, Sendable {
    public let subop: UInt8
    public let subBody: [UInt8]
    public init(subop: UInt8, subBody: [UInt8]) { self.subop = subop; self.subBody = subBody }
}

public enum OuraFraming {
    /// The secure-session / extended opcode. Per OURA_PROTOCOL.md s2.2 / s4.1.
    public static let secureSessionOp: UInt8 = 0x2F

    /// The GetEvents response / summary outer opcode (OURA_PROTOCOL.md s5.2). Below the event-tag range
    /// (tags are >= 0x41), so a caller that fails to special-case it and lets it fall through to the TLV
    /// decoder gets a safe no-op ("unknown tag") with correct byte accounting, never a misdecode.
    public static let getEventsResponseOp: UInt8 = 0x11

    /// The GetBattery response outer opcode (OURA_PROTOCOL.md s4.1/s6.10). Below the event-tag range
    /// (tags are >= 0x41), so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
    /// caller fails to special-case it.
    public static let batteryResponseOp: UInt8 = 0x0D

    /// Parse a 0x11 GetEvents response body: `status:1 sub_status:1 last_ring_timestamp:4LE pad:2`
    /// (OURA_PROTOCOL.md s5.2). `status` 0x00 = empty/no more; any other value = data follows. The
    /// `last_ring_timestamp` is the new cursor to resume the fetch from. Returns nil on a short body
    /// (never guesses a cursor).
    public static func parseGetEventsResponse(_ body: [UInt8]) -> (cursor: UInt32, moreData: Bool)? {
        guard body.count >= 6 else { return nil }
        let status = body[0]
        let cursor = UInt32(body[2]) | (UInt32(body[3]) << 8) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 24)
        return (cursor, status != 0x00)
    }

    /// Parse one outer frame from the front of `bytes`. Returns nil on a short buffer (header or body
    /// not fully present), so a caller can wait for more bytes. Per OURA_PROTOCOL.md s2.1.
    public static func parseOuterFrame(_ bytes: [UInt8]) -> OuraOuterFrame? {
        guard bytes.count >= 2 else { return nil }
        let op = bytes[0]
        let len = Int(bytes[1])
        guard bytes.count >= 2 + len else { return nil }
        return OuraOuterFrame(op: op, body: Array(bytes[2..<(2 + len)]))
    }

    /// Split a notification value that may pack several outer frames back to back. Stops and returns
    /// what it parsed when a trailing partial frame is found (the Reassembler handles re-buffering for
    /// the stream case). Per OURA_PROTOCOL.md s2.1 (loop consume(2+len)).
    public static func parseOuterFrames(_ bytes: [UInt8]) -> [OuraOuterFrame] {
        var out: [OuraOuterFrame] = []
        var i = 0
        while i + 2 <= bytes.count {
            let len = Int(bytes[i + 1])
            let total = 2 + len
            guard i + total <= bytes.count else { break }
            out.append(OuraOuterFrame(op: bytes[i], body: Array(bytes[(i + 2)..<(i + total)])))
            i += total
        }
        return out
    }

    /// Interpret an outer frame whose op is 0x2F as a secure-session sub-frame (OURA_PROTOCOL.md s2.2).
    /// Returns nil when the op is not 0x2F or the body is empty.
    public static func parseSecureFrame(_ frame: OuraOuterFrame) -> OuraSecureFrame? {
        guard frame.op == secureSessionOp, let subop = frame.body.first else { return nil }
        return OuraSecureFrame(subop: subop, subBody: Array(frame.body.dropFirst()))
    }
}

// MARK: - Inner event record (TLV)

/// A parsed TLV inner event record (OURA_PROTOCOL.md s2.3):
///   type(1) len(1) ctr:u16LE ses:u16LE payload(len-4)
/// `ringTimestamp` is stored as a single u32 LE = (session << 16) | counter (the two views are
/// equivalent per the s2.3 note). `payload` is the `len-4` bytes after the 4 timestamp bytes.
public struct OuraRecord: Equatable, Sendable {
    public let type: UInt8
    public let ringTimestamp: UInt32
    public let payload: [UInt8]
    public init(type: UInt8, ringTimestamp: UInt32, payload: [UInt8]) {
        self.type = type
        self.ringTimestamp = ringTimestamp
        self.payload = payload
    }

    /// Low 16 bits = the per-record counter. Per OURA_PROTOCOL.md s2.3.
    public var counter: UInt16 { UInt16(ringTimestamp & 0xFFFF) }
    /// High 16 bits = the session id. Per OURA_PROTOCOL.md s2.3.
    public var session: UInt16 { UInt16((ringTimestamp >> 16) & 0xFFFF) }

    /// Total wire length of this record = len + 2 (header byte + len byte). Per OURA_PROTOCOL.md s2.3.
    public var totalLength: Int { payload.count + 4 + 2 }
}

public extension OuraFraming {
    /// The minimum legal TLV `len` field: it must cover the 4 timestamp bytes. Per OURA_PROTOCOL.md s2.3.
    static let minRecordLen = 4

    /// Parse one TLV inner record from the front of `bytes`. Returns nil when the header or the full
    /// `len`-described body is not present (so the Reassembler can wait), or when `len < 4` (a record
    /// must cover its 4 timestamp bytes). A malformed/short record decodes to nil, never a guess
    /// (honest-data invariant). Per OURA_PROTOCOL.md s2.3.
    static func parseRecord(_ bytes: [UInt8]) -> OuraRecord? {
        guard bytes.count >= 2 else { return nil }
        let type = bytes[0]
        let len = Int(bytes[1])
        guard len >= minRecordLen else { return nil }
        let total = 2 + len
        guard bytes.count >= total else { return nil }
        // ringTimestamp is the 4 bytes at offset 2 as a u32 LE (counter low, session high).
        let rt = UInt32(bytes[2])
            | (UInt32(bytes[3]) << 8)
            | (UInt32(bytes[4]) << 16)
            | (UInt32(bytes[5]) << 24)
        let payload = Array(bytes[6..<total])
        return OuraRecord(type: type, ringTimestamp: rt, payload: payload)
    }
}

// MARK: - Reassembler

/// Accumulate BLE notification fragments into complete TLV inner records. A record never spans two
/// notifications in the verified corpus, but the parser is still defensive: it buffers partial
/// trailing bytes across feeds and only emits complete `2 + len` records (OURA_PROTOCOL.md s2.4).
///
/// This handles BOTH the multi-record-per-notification case (several records packed into one value)
/// and the partial-trailing-bytes case (a record split across two notifications). Mirrors the
/// WhoopProtocol Reassembler shape but for the Oura TLV layout, value-type and platform-pure.
public final class OuraReassembler {
    private var buf: [UInt8] = []

    /// A declared total beyond this is a corrupt/misaligned length, not a real record. The largest
    /// real Oura record is ~18 bytes (s6); cap generously at one MTU (247) so a bit-flipped length
    /// byte resyncs instead of stalling. `len` is a single byte (max 255), so 2 + 255 = 257 is the
    /// hard ceiling regardless; this constant documents the intent.
    public static let maxRecordBytes = 257

    public init() {}

    /// Feed one notification value. Returns every complete TLV record now available, in order. Partial
    /// trailing bytes are retained for the next feed. Per OURA_PROTOCOL.md s2.3 / s2.4.
    public func feed(_ fragment: [UInt8]) -> [OuraRecord] {
        buf.append(contentsOf: fragment)
        var out: [OuraRecord] = []
        while buf.count >= 2 {
            let len = Int(buf[1])
            // A record must cover its 4 timestamp bytes. A len < 4 here is a misaligned byte: drop one
            // and resync rather than emit garbage (honest-data invariant).
            if len < OuraFraming.minRecordLen {
                buf.removeFirst(1)
                continue
            }
            let total = 2 + len
            if buf.count < total {
                break   // wait for the rest of this record
            }
            if let rec = OuraFraming.parseRecord(Array(buf[0..<total])) {
                out.append(rec)
            }
            buf.removeFirst(total)
        }
        return out
    }

    /// Discard any buffered partial bytes (call on disconnect so a half-record does not bleed into the
    /// next session). Mirrors the StandardHRSource stop()/reset discipline.
    public func reset() {
        buf.removeAll(keepingCapacity: true)
    }

    /// Number of bytes currently buffered awaiting completion (observability only).
    public var bufferedByteCount: Int { buf.count }
}
