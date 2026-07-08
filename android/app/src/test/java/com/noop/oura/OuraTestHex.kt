package com.noop.oura

/**
 * Shared hex helper for the Oura protocol JVM tests. Parses a hex string into an unsigned-byte
 * IntArray (0..255), the storage type the Kotlin twin uses (see Framing.kt note). Every fixture hex
 * string in these tests is byte-for-byte identical to the corresponding Swift fixture in
 * Packages/OuraProtocol/Tests/OuraProtocolTests, so identical raw record bytes must decode to
 * identical values across the two ports (that is the parity guarantee these tests pin).
 */
internal object OuraTestHex {
    fun bytes(s: String): IntArray {
        require(s.length % 2 == 0) { "odd-length hex" }
        return IntArray(s.length / 2) { i ->
            s.substring(i * 2, i * 2 + 2).toInt(16)
        }
    }

    fun hex(b: IntArray): String = b.joinToString("") { "%02x".format(it and 0xFF) }
}
