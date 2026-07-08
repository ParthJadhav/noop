package com.noop.oura

// Framing: the two framing layers that ride on the same characteristics (OURA_PROTOCOL.md s2). Kotlin
// twin of Framing.swift.
//   - Outer command / command-response frame:  op(1) len(1) body(len)        (s2.1)
//   - Extended / secure-session frame (0x2F):   2F len subop subop-body       (s2.2)
//   - Inner event record (TLV):                 type(1) len(1) rt:u32LE payload (s2.3)
// All multi-byte integers are little-endian unless a decoder states otherwise (OURA_PROTOCOL.md s2.1).
//
// The first byte disambiguates layers: a value present in the opcode table (s4) is an outer frame;
// otherwise it is an inner event record. The OuraDriver routes on this; Framing exposes pure parsers
// plus a defensive Reassembler that buffers partial trailing bytes across notifications (s2.4).
//
// DIVERGENCE FROM SWIFT (deliberate): the Swift port uses [UInt8]. Kotlin's signed Byte makes the
// bit-math noisy, so this twin carries unsigned bytes as IntArray values 0..255. The wire layout,
// offsets, and arithmetic are byte-for-byte identical to the Swift version; only the storage type
// differs. The OuraReassembler.feed entry point accepts a ByteArray (the BLE callback type) and
// widens to unsigned internally.
//
// Platform-pure, value types only. Facts cited per OURA_PROTOCOL.md s2.

/**
 * A parsed outer frame: `op len body` (OURA_PROTOCOL.md s2.1). `body` is the `len` bytes after the
 * header. Multiple outer frames may be packed into one notification; the consumer loops 2+len.
 */
data class OuraOuterFrame(val op: Int, val body: IntArray) {
    /** Total wire length of this frame (header + body). */
    val totalLength: Int get() = 2 + body.size

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraOuterFrame) return false
        return op == other.op && body.contentEquals(other.body)
    }

    override fun hashCode(): Int = 31 * op + body.contentHashCode()
}

/**
 * A parsed secure-session sub-frame: the first body byte of a 0x2F frame is the sub-op
 * (OURA_PROTOCOL.md s2.2 / s4.2). `subBody` is the remaining body bytes after the sub-op.
 */
data class OuraSecureFrame(val subop: Int, val subBody: IntArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraSecureFrame) return false
        return subop == other.subop && subBody.contentEquals(other.subBody)
    }

    override fun hashCode(): Int = 31 * subop + subBody.contentHashCode()
}

/**
 * A parsed TLV inner event record (OURA_PROTOCOL.md s2.3):
 *   type(1) len(1) ctr:u16LE ses:u16LE payload(len-4)
 * `ringTimestamp` is stored as a single u32 LE = (session << 16) | counter (the two views are
 * equivalent per the s2.3 note). `payload` is the `len-4` bytes after the 4 timestamp bytes.
 *
 * `ringTimestamp` is kept as a Long holding the unsigned 32-bit value (0..0xFFFFFFFF), the Kotlin
 * stand-in for Swift's UInt32.
 */
data class OuraRecord(val type: Int, val ringTimestamp: Long, val payload: IntArray) {
    /** Low 16 bits = the per-record counter. Per OURA_PROTOCOL.md s2.3. */
    val counter: Int get() = (ringTimestamp and 0xFFFFL).toInt()

    /** High 16 bits = the session id. Per OURA_PROTOCOL.md s2.3. */
    val session: Int get() = ((ringTimestamp shr 16) and 0xFFFFL).toInt()

    /** Total wire length of this record = len + 2 (header byte + len byte). Per OURA_PROTOCOL.md s2.3. */
    val totalLength: Int get() = payload.size + 4 + 2

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraRecord) return false
        return type == other.type && ringTimestamp == other.ringTimestamp &&
            payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int {
        var h = type
        h = 31 * h + ringTimestamp.hashCode()
        h = 31 * h + payload.contentHashCode()
        return h
    }
}

/**
 * The parsed result of a 0x11 GetEvents response (OURA_PROTOCOL.md s5.2). Kotlin twin of the Swift
 * `(cursor: UInt32, moreData: Bool)` tuple. `cursor` is the new resume cursor (an unsigned 32-bit ring
 * timestamp carried as a Long, 0..0xFFFFFFFF); `moreData` is true while the ring still has banked events
 * to hand over.
 */
data class GetEventsSummary(val cursor: Long, val moreData: Boolean)

object OuraFraming {
    /** The secure-session / extended opcode. Per OURA_PROTOCOL.md s2.2 / s4.1. */
    const val secureSessionOp = 0x2F

    /**
     * The GetEvents response / summary outer opcode (OURA_PROTOCOL.md s5.2). Below the event-tag range
     * (tags are >= 0x41), so a caller that fails to special-case it and lets it fall through to the TLV
     * decoder gets a safe no-op ("unknown tag") with correct byte accounting, never a misdecode. Kotlin
     * twin of Swift's getEventsResponseOp.
     */
    const val getEventsResponseOp = 0x11

    /**
     * The GetBattery response outer opcode (OURA_PROTOCOL.md s4.1/s6.10). Below the event-tag range
     * (tags are >= 0x41), so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
     * caller fails to special-case it. Kotlin twin of Swift's batteryResponseOp.
     */
    const val batteryResponseOp = 0x0D

    /** The minimum legal TLV `len` field: it must cover the 4 timestamp bytes. Per OURA_PROTOCOL.md s2.3. */
    const val minRecordLen = 4

    /**
     * Parse a 0x11 GetEvents response body: `status:1 sub_status:1 last_ring_timestamp:4LE pad:2`
     * (OURA_PROTOCOL.md s5.2). `status` 0x00 = empty/no more; any other value = data follows. The
     * `last_ring_timestamp` is the new cursor to resume the fetch from. Returns null on a short body
     * (never guesses a cursor). Kotlin twin of Swift's parseGetEventsResponse; `cursor` is the unsigned
     * 32-bit ring timestamp carried as a Long (0..0xFFFFFFFF).
     */
    fun parseGetEventsResponse(body: IntArray): GetEventsSummary? {
        if (body.size < 6) return null
        val status = body[0]
        val cursor = (body[2].toLong() and 0xFFL) or
            ((body[3].toLong() and 0xFFL) shl 8) or
            ((body[4].toLong() and 0xFFL) shl 16) or
            ((body[5].toLong() and 0xFFL) shl 24)
        return GetEventsSummary(cursor = cursor, moreData = status != 0x00)
    }

    /**
     * Parse one outer frame from the front of `bytes`. Returns null on a short buffer (header or body
     * not fully present), so a caller can wait for more bytes. Per OURA_PROTOCOL.md s2.1.
     */
    fun parseOuterFrame(bytes: IntArray): OuraOuterFrame? {
        if (bytes.size < 2) return null
        val op = bytes[0]
        val len = bytes[1]
        if (bytes.size < 2 + len) return null
        return OuraOuterFrame(op = op, body = bytes.copyOfRange(2, 2 + len))
    }

    /**
     * Split a notification value that may pack several outer frames back to back. Stops and returns
     * what it parsed when a trailing partial frame is found (the Reassembler handles re-buffering for
     * the stream case). Per OURA_PROTOCOL.md s2.1 (loop consume(2+len)).
     */
    fun parseOuterFrames(bytes: IntArray): List<OuraOuterFrame> {
        val out = ArrayList<OuraOuterFrame>()
        var i = 0
        while (i + 2 <= bytes.size) {
            val len = bytes[i + 1]
            val total = 2 + len
            if (i + total > bytes.size) break
            out.add(OuraOuterFrame(op = bytes[i], body = bytes.copyOfRange(i + 2, i + total)))
            i += total
        }
        return out
    }

    /**
     * Interpret an outer frame whose op is 0x2F as a secure-session sub-frame (OURA_PROTOCOL.md s2.2).
     * Returns null when the op is not 0x2F or the body is empty.
     */
    fun parseSecureFrame(frame: OuraOuterFrame): OuraSecureFrame? {
        if (frame.op != secureSessionOp || frame.body.isEmpty()) return null
        return OuraSecureFrame(subop = frame.body[0], subBody = frame.body.copyOfRange(1, frame.body.size))
    }

    /**
     * Parse one TLV inner record from the front of `bytes`. Returns null when the header or the full
     * `len`-described body is not present (so the Reassembler can wait), or when `len < 4` (a record
     * must cover its 4 timestamp bytes). A malformed/short record decodes to null, never a guess
     * (honest-data invariant). Per OURA_PROTOCOL.md s2.3.
     */
    fun parseRecord(bytes: IntArray): OuraRecord? {
        if (bytes.size < 2) return null
        val type = bytes[0]
        val len = bytes[1]
        if (len < minRecordLen) return null
        val total = 2 + len
        if (bytes.size < total) return null
        // ringTimestamp is the 4 bytes at offset 2 as a u32 LE (counter low, session high).
        val rt = (bytes[2].toLong() and 0xFFL) or
            ((bytes[3].toLong() and 0xFFL) shl 8) or
            ((bytes[4].toLong() and 0xFFL) shl 16) or
            ((bytes[5].toLong() and 0xFFL) shl 24)
        val payload = bytes.copyOfRange(6, total)
        return OuraRecord(type = type, ringTimestamp = rt, payload = payload)
    }
}

/**
 * Accumulate BLE notification fragments into complete TLV inner records. A record never spans two
 * notifications in the verified corpus, but the parser is still defensive: it buffers partial
 * trailing bytes across feeds and only emits complete `2 + len` records (OURA_PROTOCOL.md s2.4).
 *
 * This handles BOTH the multi-record-per-notification case (several records packed into one value)
 * and the partial-trailing-bytes case (a record split across two notifications). Mirrors the Swift
 * OuraReassembler, value-type and platform-pure.
 */
class OuraReassembler {
    private val buf = ArrayList<Int>()

    /** Feed one notification value (BLE callback ByteArray). Convenience over [feed]. */
    fun feed(fragment: ByteArray): List<OuraRecord> =
        feed(IntArray(fragment.size) { fragment[it].toInt() and 0xFF })

    /**
     * Feed one notification value. Returns every complete TLV record now available, in order. Partial
     * trailing bytes are retained for the next feed. Per OURA_PROTOCOL.md s2.3 / s2.4.
     */
    fun feed(fragment: IntArray): List<OuraRecord> {
        for (b in fragment) buf.add(b and 0xFF)
        val out = ArrayList<OuraRecord>()
        while (buf.size >= 2) {
            val len = buf[1]
            // A record must cover its 4 timestamp bytes. A len < 4 here is a misaligned byte: drop one
            // and resync rather than emit garbage (honest-data invariant).
            if (len < OuraFraming.minRecordLen) {
                buf.removeAt(0)
                continue
            }
            val total = 2 + len
            if (buf.size < total) break   // wait for the rest of this record
            val slice = IntArray(total) { buf[it] }
            OuraFraming.parseRecord(slice)?.let { out.add(it) }
            repeat(total) { buf.removeAt(0) }
        }
        return out
    }

    /**
     * Discard any buffered partial bytes (call on disconnect so a half-record does not bleed into the
     * next session). Mirrors the StandardHRSource stop()/reset discipline.
     */
    fun reset() {
        buf.clear()
    }

    /** Number of bytes currently buffered awaiting completion (observability only). */
    val bufferedByteCount: Int get() = buf.size

    companion object {
        /**
         * A declared total beyond this is a corrupt/misaligned length, not a real record. The largest
         * real Oura record is ~18 bytes (s6); `len` is a single byte (max 255), so 2 + 255 = 257 is
         * the hard ceiling regardless; this constant documents the intent.
         */
        const val maxRecordBytes = 257
    }
}
