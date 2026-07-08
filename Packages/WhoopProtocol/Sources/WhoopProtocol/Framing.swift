import Foundation

// CRC8 lookup table (poly 0x07). Ported verbatim from framing.py.
private let crc8Table: [UInt8] = [
    0x00, 0x07, 0x0E, 0x09, 0x1C, 0x1B, 0x12, 0x15, 0x38, 0x3F, 0x36, 0x31, 0x24, 0x23, 0x2A, 0x2D,
    0x70, 0x77, 0x7E, 0x79, 0x6C, 0x6B, 0x62, 0x65, 0x48, 0x4F, 0x46, 0x41, 0x54, 0x53, 0x5A, 0x5D,
    0xE0, 0xE7, 0xEE, 0xE9, 0xFC, 0xFB, 0xF2, 0xF5, 0xD8, 0xDF, 0xD6, 0xD1, 0xC4, 0xC3, 0xCA, 0xCD,
    0x90, 0x97, 0x9E, 0x99, 0x8C, 0x8B, 0x82, 0x85, 0xA8, 0xAF, 0xA6, 0xA1, 0xB4, 0xB3, 0xBA, 0xBD,
    0xC7, 0xC0, 0xC9, 0xCE, 0xDB, 0xDC, 0xD5, 0xD2, 0xFF, 0xF8, 0xF1, 0xF6, 0xE3, 0xE4, 0xED, 0xEA,
    0xB7, 0xB0, 0xB9, 0xBE, 0xAB, 0xAC, 0xA5, 0xA2, 0x8F, 0x88, 0x81, 0x86, 0x93, 0x94, 0x9D, 0x9A,
    0x27, 0x20, 0x29, 0x2E, 0x3B, 0x3C, 0x35, 0x32, 0x1F, 0x18, 0x11, 0x16, 0x03, 0x04, 0x0D, 0x0A,
    0x57, 0x50, 0x59, 0x5E, 0x4B, 0x4C, 0x45, 0x42, 0x6F, 0x68, 0x61, 0x66, 0x73, 0x74, 0x7D, 0x7A,
    0x89, 0x8E, 0x87, 0x80, 0x95, 0x92, 0x9B, 0x9C, 0xB1, 0xB6, 0xBF, 0xB8, 0xAD, 0xAA, 0xA3, 0xA4,
    0xF9, 0xFE, 0xF7, 0xF0, 0xE5, 0xE2, 0xEB, 0xEC, 0xC1, 0xC6, 0xCF, 0xC8, 0xDD, 0xDA, 0xD3, 0xD4,
    0x69, 0x6E, 0x67, 0x60, 0x75, 0x72, 0x7B, 0x7C, 0x51, 0x56, 0x5F, 0x58, 0x4D, 0x4A, 0x43, 0x44,
    0x19, 0x1E, 0x17, 0x10, 0x05, 0x02, 0x0B, 0x0C, 0x21, 0x26, 0x2F, 0x28, 0x3D, 0x3A, 0x33, 0x34,
    0x4E, 0x49, 0x40, 0x47, 0x52, 0x55, 0x5C, 0x5B, 0x76, 0x71, 0x78, 0x7F, 0x6A, 0x6D, 0x64, 0x63,
    0x3E, 0x39, 0x30, 0x37, 0x22, 0x25, 0x2C, 0x2B, 0x06, 0x01, 0x08, 0x0F, 0x1A, 0x1D, 0x14, 0x13,
    0xAE, 0xA9, 0xA0, 0xA7, 0xB2, 0xB5, 0xBC, 0xBB, 0x96, 0x91, 0x98, 0x9F, 0x8A, 0x8D, 0x84, 0x83,
    0xDE, 0xD9, 0xD0, 0xD7, 0xC2, 0xC5, 0xCC, 0xCB, 0xE6, 0xE1, 0xE8, 0xEF, 0xFA, 0xFD, 0xF4, 0xF3,
]

/// CRC-8 (poly 0x07) over `bytes[from..<(to ?? count)]`. The optional range defaults to the whole
/// array, so existing callers are unchanged; passing a range lets the frame validator checksum a slice
/// in place rather than slicing out a fresh `Array(frame[...])` for every frame on the offload path.
public func crc8(_ bytes: [UInt8], _ from: Int = 0, _ to: Int? = nil) -> UInt8 {
    let upper = to ?? bytes.count
    var crc: UInt8 = 0
    var i = from
    while i < upper {
        crc = crc8Table[Int(crc ^ bytes[i])]
        i += 1
    }
    return crc
}

// Standard zlib CRC-32 (reflected, poly 0xEDB88320), table built in code.
private let crc32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        table[i] = c
    }
    return table
}()

/// Standard zlib CRC-32 over `bytes[from..<(to ?? count)]`. The optional range defaults to the whole
/// array (existing callers unchanged); the validator passes a range to checksum the inner record or
/// payload in place, skipping the per-frame sub-array copy that added up over a multi-night offload.
public func crc32(_ bytes: [UInt8], _ from: Int = 0, _ to: Int? = nil) -> UInt32 {
    let upper = to ?? bytes.count
    var crc: UInt32 = 0xFFFFFFFF
    var i = from
    while i < upper {
        crc = crc32Table[Int((crc ^ UInt32(bytes[i])) & 0xFF)] ^ (crc >> 8)
        i += 1
    }
    return crc ^ 0xFFFFFFFF
}

/// CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) over `bytes[from..<(to ?? count)]`. Used for the
/// Whoop 5.0 frame header check. The optional range defaults to the whole array; the validator passes
/// a range so the 6-byte header check needs no `Array(frame[0..<6])` copy.
public func crc16Modbus(_ bytes: [UInt8], _ from: Int = 0, _ to: Int? = nil) -> UInt16 {
    let upper = to ?? bytes.count
    var crc: UInt16 = 0xFFFF
    var i = from
    while i < upper {
        crc ^= UInt16(bytes[i])
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xA001
            } else {
                crc >>= 1
            }
        }
        i += 1
    }
    return crc
}

public struct FrameCheck: Equatable {
    public let ok: Bool
    public let length: Int?
    public let crc8OK: Bool?
    public let crc32OK: Bool?
    public init(ok: Bool, length: Int? = nil, crc8OK: Bool? = nil, crc32OK: Bool? = nil) {
        self.ok = ok
        self.length = length
        self.crc8OK = crc8OK
        self.crc32OK = crc32OK
    }
}

@inline(__always)
private func u16le(_ bytes: [UInt8], _ off: Int) -> Int {
    Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
}

@inline(__always)
private func u32le(_ bytes: [UInt8], _ off: Int) -> UInt32 {
    UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8)
        | (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24)
}

/// Validate a complete frame envelope and both CRCs.
/// Frame: [0xAA][len u16 LE][crc8(len)][...inner...][crc32 u32 LE], total = len + 4.
public func verifyFrame(_ frame: [UInt8]) -> FrameCheck {
    if frame.count < 8 || frame[0] != 0xAA {
        return FrameCheck(ok: false)
    }
    let length = u16le(frame, 1)
    // Ranged CRCs checksum the frame in place, with no per-frame sub-array allocation.
    let crc8OK = crc8(frame, 1, 3) == frame[3]
    var crc32OK: Bool? = nil
    // length must cover at least the envelope's inner bytes (mirrors framing.py).
    if 7 <= length && length + 4 <= frame.count {
        // inner record = frame[4..<length]
        crc32OK = crc32(frame, 4, length) == u32le(frame, length)
    }
    let ok = crc8OK && (crc32OK ?? false)
    return FrameCheck(ok: ok, length: length, crc8OK: crc8OK, crc32OK: crc32OK)
}

/// Family-aware frame validation.
///
/// `whoop4` behaves EXACTLY like the no-family `verifyFrame(_:)` above (back-compat). `whoop5`
/// uses the Whoop 5.0 envelope reverse-engineered from Goose:
///
///   [0]   SOF 0xAA
///   [1]   format byte (0x01)
///   [2-3] declaredLength u16 LE  (= payload length + 4)
///   [4-5] header bytes
///   [6-7] CRC16-Modbus over frame[0..<6], u16 LE
///   [8..] payload (length = declaredLength - 4)
///   tail  CRC32 (zlib, LE) over the payload, 4 bytes
///   total = declaredLength + 8
///
/// For whoop5 the `crc8OK` field of the result carries the CRC16 header outcome (so callers get a
/// single uniform "header CRC ok?" signal regardless of family).
public func verifyFrame(_ frame: [UInt8], family: DeviceFamily) -> FrameCheck {
    switch family {
    case .whoop4:
        return verifyFrame(frame)
    case .whoop5:
        return verifyFrameWhoop5(frame)
    }
}

private func verifyFrameWhoop5(_ frame: [UInt8]) -> FrameCheck {
    // Minimum whoop5 frame: 8 header bytes (incl. CRC16) + 4 CRC32 trailer = 12.
    if frame.count < 12 || frame[0] != 0xAA {
        return FrameCheck(ok: false)
    }
    let declaredLength = u16le(frame, 2)
    // declaredLength counts payload + the 4-byte CRC32 trailer (mirrors Goose v5Frames/v5Payload).
    guard declaredLength >= 4 else {
        return FrameCheck(ok: false, length: declaredLength)
    }
    let total = declaredLength + 8

    // Header CRC16-Modbus over the first 6 bytes, stored LE at frame[6..8]. Ranged, no copy.
    let wantHeaderCRC = crc16Modbus(frame, 0, 6)
    let gotHeaderCRC = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
    let headerCRCOK = wantHeaderCRC == gotHeaderCRC

    var crc32OK: Bool? = nil
    if frame.count >= total {
        // payload spans [8, total-4); CRC32 trailer is the final 4 bytes of the frame.
        let payloadEnd = total - 4
        // payload = frame[8..<payloadEnd], checksummed in place.
        let want = crc32(frame, 8, payloadEnd)
        let got = u32le(frame, payloadEnd)
        crc32OK = want == got
    }

    let ok = headerCRCOK && (crc32OK ?? false)
    // Report the header outcome through crc8OK so callers have a single header-CRC signal.
    return FrameCheck(ok: ok, length: declaredLength, crc8OK: headerCRCOK, crc32OK: crc32OK)
}

/// Reconstruct a complete frame from a bare payload (data == frame[7:]).
/// Some captures store only the data portion; rebuild the envelope with a correct zlib
/// crc32 and a placeholder crc8 byte (0x00). Mirrors framing.py frame_from_payload.
public func frameFromPayload(_ data: [UInt8], type: UInt8, seq: UInt8 = 0, cmd: UInt8 = 0) -> [UInt8] {
    let inner: [UInt8] = [type, seq, cmd] + data
    let length = inner.count + 4
    var frame: [UInt8] = [0xAA, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), 0x00]
    frame.append(contentsOf: inner)
    let c = crc32(inner)
    frame.append(UInt8(c & 0xFF))
    frame.append(UInt8((c >> 8) & 0xFF))
    frame.append(UInt8((c >> 16) & 0xFF))
    frame.append(UInt8((c >> 24) & 0xFF))
    return frame
}

/// EXPERIMENTAL: build a WHOOP 5.0/MG ("puffin") command frame in the CRC16 envelope (docs/PROTOCOL.md
/// §2.2). The inner record is `[type][seq][cmd] + payload`; `declLen = innerLen + 4` (the CRC32 tail);
/// the CRC16-Modbus covers the first six header bytes. `type` defaults to 35 (COMMAND) and `header`
/// to `[0x00, 0x01]`, mirroring the structure of the only puffin frame we know a real strap accepts
/// (the static CLIENT_HELLO). The returned frame round-trips through `verifyFrame(_:family:.whoop5)`.
/// Whether a 5/MG strap *acts* on a given command is exactly what experimentation discovers, so the
/// app gates any sending behind an opt-in switch and only writes to the puffin command characteristic.
public func puffinCommandFrame(cmd: UInt8, seq: UInt8, payload: [UInt8] = [0x00],
                               type: UInt8 = 35, header: [UInt8] = [0x00, 0x01]) -> [UInt8] {
    // Pad the inner record to a 4-byte boundary before length/CRC, exactly as the strap's maverick
    // framing does (pad4). No-op for the 4-aligned commands shipped so far (toggle HR, historical),
    // but REQUIRED for the 12-byte haptics payload (inner 15 → 16) — otherwise the declared length and
    // CRC32 cover the wrong byte count and the strap rejects the frame (#48).
    var inner: [UInt8] = [type, seq, cmd] + payload
    let pad = (4 - inner.count % 4) % 4
    if pad > 0 { inner += [UInt8](repeating: 0, count: pad) }
    let declLen = inner.count + 4
    var frame: [UInt8] = [0xAA, 0x01,
                          UInt8(declLen & 0xFF), UInt8((declLen >> 8) & 0xFF),
                          header[0], header[1]]
    let c16 = crc16Modbus(Array(frame[0..<6]))
    frame.append(UInt8(c16 & 0xFF)); frame.append(UInt8((c16 >> 8) & 0xFF))
    frame.append(contentsOf: inner)
    let c32 = crc32(inner)
    frame.append(UInt8(c32 & 0xFF)); frame.append(UInt8((c32 >> 8) & 0xFF))
    frame.append(UInt8((c32 >> 16) & 0xFF)); frame.append(UInt8((c32 >> 24) & 0xFF))
    return frame
}

/// Accumulate BLE notification fragments into complete frames.
/// A complete frame is `length + 4` bytes where length = u16 LE at buf[1..3].
/// Mirrors framing.py Reassembler.
public final class Reassembler {
    // Backed by a flat byte buffer plus a read cursor rather than draining off the front. The earlier
    // form called buf.removeFirst(n), which shifts the whole tail down on every completed frame, so
    // draining one frame was O(n) and the historical offload (thousands of ~1.9 KB records over a
    // multi-night sync) paid it repeatedly. Here fragments append into [buf], [head] advances past
    // consumed bytes, and the leftover tail is compacted to the front once per feed(). Output frames are
    // byte-identical and in the same order. This mirrors the Android Reassembler window.
    private var buf: [UInt8] = []
    private var head = 0   // index of the first byte not yet consumed
    private let family: DeviceFamily

    /// ~4× the largest real WHOOP frame (~1920 B raw/historical). A declared total beyond this is a
    /// corrupt or misaligned length (a bit-flip, or a spurious 0xAA injected mid-frame), not a real
    /// frame — so drop that SOF and resync rather than wait forever for bytes that can't arrive.
    /// Mirrors the Android `Framing.kt` cap. (Reimplemented from @vulnix0x4's PR #374.)
    static let maxFrameBytes = 8192

    /// `family` selects the frame-length convention:
    /// - WHOOP 4.0 reads a u16 length at `buf[1..3]`, total = `length + 4`.
    /// - WHOOP 5.0 ("puffin") reads a u16 declared length at `buf[2..4]` (after the `0xAA` SOF and
    ///   the `0x01` format byte), total = `declLength + 8` — the extra 4 covers the format byte and
    ///   the CRC16 header that 5.0 inserts ahead of the inner record.
    ///
    /// Defaults to `.whoop4` so existing callers and tests are byte-for-byte unchanged.
    public init(family: DeviceFamily = .whoop4) {
        self.family = family
    }

    public func feed(_ fragment: [UInt8]) -> [[UInt8]] {
        buf.append(contentsOf: fragment)
        var out: [[UInt8]] = []
        while true {
            guard let sof = indexOfSOF() else {
                // No SOF left in the window: nothing here is salvageable, so drop it all.
                buf.removeAll(keepingCapacity: true)
                head = 0
                break
            }
            // Skip any leading bytes ahead of the SOF instead of physically removing them.
            if sof > head { head = sof }
            let avail = buf.count - head
            // Both families need at least 4 bytes to read their declared length.
            if avail < 4 {
                break
            }
            let total: Int
            switch family {
            case .whoop4:
                total = (Int(buf[head + 1]) | (Int(buf[head + 2]) << 8)) + 4
            case .whoop5:
                total = (Int(buf[head + 2]) | (Int(buf[head + 3]) << 8)) + 8
            }
            if total > Reassembler.maxFrameBytes {
                // Impossibly large declared length → this 0xAA is garbage. Drop it and resync to the
                // next SOF instead of stalling the live stream until a reconnect.
                head += 1
                continue
            }
            if avail < total {
                break
            }
            out.append(Array(buf[head..<(head + total)]))
            head += total
        }
        compact()
        return out
    }

    /// Index of the first 0xAA at or after `head` in the live window, or nil if none remain.
    private func indexOfSOF() -> Int? {
        var i = head
        while i < buf.count {
            if buf[i] == 0xAA { return i }
            i += 1
        }
        return nil
    }

    /// Slide the unconsumed tail back to offset 0 so `head` can't drift forever and the buffer stays
    /// small. compact() runs at the end of every feed(), so `head` is always 0 when the next append
    /// lands. The leftover is at most one in-progress frame (< maxFrameBytes), so the move is bounded.
    private func compact() {
        if head == 0 { return }
        if head >= buf.count {
            buf.removeAll(keepingCapacity: true)
        } else {
            buf.removeFirst(head)
        }
        head = 0
    }
}
