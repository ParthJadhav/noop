package com.noop.oura

// Commands: byte-exact opcode builders (OURA_PROTOCOL.md s4 / s5). Kotlin twin of Commands.swift.
// Pure functions returning the wire bytes to write to ...0002. The live-HR enable path (s5.6) is the
// feature-0x02 (0x2F) path, NOT the 0x06 path. Dangerous opcodes (reboot, factory reset, key install,
// DFU) are quarantined in OuraDangerousCommands and never produced by the normal builders.
//
// Platform-pure value types. Facts cited per OURA_PROTOCOL.md s4 / s5.

/**
 * A built command plus a short label for the strap log (statuses/UUIDs/counts only, never an
 * address). The OuraDriver returns these from nextStep(after:).
 */
data class OuraCommand(val label: String, val bytes: IntArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraCommand) return false
        return label == other.label && bytes.contentEquals(other.bytes)
    }

    override fun hashCode(): Int = 31 * label.hashCode() + bytes.contentHashCode()
}

object OuraCommands {
    // The live daytime-HR feature id. Per OURA_PROTOCOL.md s5.6 / s7.1.
    const val featureDaytimeHR = 0x02

    // The SpO2 feature id. Per OURA_PROTOCOL.md s7.1.
    const val featureSpO2 = 0x04

    // MARK: - Pre-auth / identity (unauthenticated OK)

    /** GetFirmwareVersion: `08 03 00 00 00`. Pre-auth readable. Per OURA_PROTOCOL.md s4.1 / s3.6. */
    fun getFirmwareVersion(): OuraCommand =
        OuraCommand("get_firmware", intArrayOf(0x08, 0x03, 0x00, 0x00, 0x00))

    /**
     * GetProductInfo serial page: `18 03 08 00 10`. Pre-auth readable; used for generation detection.
     * Per OURA_PROTOCOL.md s4.1 / s7.3.
     */
    fun getProductSerial(): OuraCommand =
        OuraCommand("get_serial", intArrayOf(0x18, 0x03, 0x08, 0x00, 0x10))

    /**
     * GetProductInfo hardware page: `18 03 18 00 10`. Pre-auth readable; hardware id (e.g. BLB_03)
     * maps to the generation. Per OURA_PROTOCOL.md s4.1 / s7.3.
     */
    fun getProductHardware(): OuraCommand =
        OuraCommand("get_hardware", intArrayOf(0x18, 0x03, 0x18, 0x00, 0x10))

    // MARK: - Notifications / state

    /** SetNotification (enable all): `1c 01 3f`. `00`=none, `3f`/`bf`=all. Per OURA_PROTOCOL.md s4.1. */
    fun enableAllNotifications(): OuraCommand =
        OuraCommand("notify_all", intArrayOf(0x1C, 0x01, 0x3F))

    /** SetNotification (disable): `1c 01 00`. Per OURA_PROTOCOL.md s4.1. */
    fun disableNotifications(): OuraCommand =
        OuraCommand("notify_none", intArrayOf(0x1C, 0x01, 0x00))

    // MARK: - Time sync

    /**
     * SyncTime: `12 09 <token:1> <counter:3 LE> 00 00 00 00 f6` where counter = floor(unix_s / 256)
     * and the trailer 0xf6 is fixed. Per OURA_PROTOCOL.md s5.4. `token` defaults to 0.
     */
    fun syncTime(unixSeconds: Long, token: Int = 0x00): OuraCommand {
        val counter = unixSeconds / 256
        val c0 = (counter and 0xFFL).toInt()
        val c1 = ((counter shr 8) and 0xFFL).toInt()
        val c2 = ((counter shr 16) and 0xFFL).toInt()
        return OuraCommand(
            "sync_time",
            intArrayOf(0x12, 0x09, token and 0xFF, c0, c1, c2, 0x00, 0x00, 0x00, 0x00, 0xF6),
        )
    }

    // MARK: - Event fetch (cursor)

    /**
     * GetEvents request: `10 09 <ringTimestamp:4 LE> <max:1> <flags:4 LE>`. cursor 0 = full dump;
     * max 0 = ack-only (advance cursor without data); flags = 0xFFFFFFFF. Per OURA_PROTOCOL.md s5.1.
     * `cursor` is the unsigned-32 ring timestamp carried as a Long; `maxEvents` is 0..255.
     */
    fun getEvents(cursor: Long, maxEvents: Int): OuraCommand {
        val c0 = (cursor and 0xFFL).toInt()
        val c1 = ((cursor shr 8) and 0xFFL).toInt()
        val c2 = ((cursor shr 16) and 0xFFL).toInt()
        val c3 = ((cursor shr 24) and 0xFFL).toInt()
        return OuraCommand(
            "get_events",
            intArrayOf(0x10, 0x09, c0, c1, c2, c3, maxEvents and 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
        )
    }

    /** Flush flash-buffered events first: `28 01 00`. Per OURA_PROTOCOL.md s4.1 / s5.3. */
    fun flushBuffer(): OuraCommand =
        OuraCommand("flush_buffer", intArrayOf(0x28, 0x01, 0x00))

    /** GetBattery: `0c 00`. Auth-gated after key set. Per OURA_PROTOCOL.md s4.1. */
    fun getBattery(): OuraCommand =
        OuraCommand("get_battery", intArrayOf(0x0C, 0x00))

    // MARK: - Live-HR realtime (feature-0x02 path; s5.6)

    /**
     * Step 1 of the live-HR enable triplet: read the daytime-HR feature status, `2f 02 20 02`.
     * ACK: `2f 06 21 02 ...`. Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHRReadStatus(): OuraCommand =
        OuraCommand("dhr_read", intArrayOf(0x2F, 0x02, 0x20, featureDaytimeHR))

    /**
     * Step 2: enable (param write byte 0 = 3), `2f 03 22 02 03`. ACK: `2f 03 23 02 00`.
     * Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHREnable(): OuraCommand =
        OuraCommand("dhr_enable", intArrayOf(0x2F, 0x03, 0x22, featureDaytimeHR, 0x03))

    /**
     * Step 3: subscribe (param write byte 2 = 2), `2f 03 26 02 02`. ACK: `2f 03 27 02 00`. Live HR/IBI
     * then streams ~1 Hz as 0x2F sub-op 0x28 pushes. Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHRSubscribe(): OuraCommand =
        OuraCommand("dhr_subscribe", intArrayOf(0x2F, 0x03, 0x26, featureDaytimeHR, 0x02))

    /**
     * Disable live HR: `2f 03 22 02 01`. ACK: `2f 03 23 02 00`; stream stops on ACK.
     * Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHRDisable(): OuraCommand =
        OuraCommand("dhr_disable", intArrayOf(0x2F, 0x03, 0x22, featureDaytimeHR, 0x01))

    /**
     * The ordered live-HR enable triplet (read, enable, subscribe). The driver gates each on its ACK.
     * Per OURA_PROTOCOL.md s5.6.
     */
    fun liveHREnableSequence(): List<OuraCommand> =
        listOf(liveHRReadStatus(), liveHREnable(), liveHRSubscribe())
}

// MARK: - Dangerous commands (quarantined)

/**
 * Opcodes that reboot, wipe, reflash, or re-key the ring. These are isolated here and NEVER produced
 * by the normal builders or the OuraDriver flow, so they can only be sent through an explicit, named
 * call. Per the brief's FOOTGUN WATCH and OURA_PROTOCOL.md s4.1 (DANGEROUS markers).
 */
object OuraDangerousCommands {
    /** 0x0E StartFirmwareUpdate / soft_reset (reboots 22-35 s): `0e 01 ff`. Per OURA_PROTOCOL.md s4.1. */
    fun softReset(): OuraCommand =
        OuraCommand("DANGEROUS_soft_reset", intArrayOf(0x0E, 0x01, 0xFF))

    /** 0x1A FactoryReset (wipes the ring, forces re-onboard + key reinstall). Per OURA_PROTOCOL.md s4.1. */
    fun factoryReset(): OuraCommand =
        OuraCommand("DANGEROUS_factory_reset", intArrayOf(0x1A, 0x00))

    /**
     * 0x24 SetAuthKey (installs a new 16-byte app key; only legitimate post-factory-reset). Builds
     * via OuraAuth.installKeyCommand so the length guard is shared. Per OURA_PROTOCOL.md s3.2.
     */
    fun installKey(key: IntArray): OuraCommand =
        OuraCommand("DANGEROUS_install_key", OuraAuth.installKeyCommand(key))

    /** 0x2B DFU start (OTA firmware). Payload is the OTA control body. Per OURA_PROTOCOL.md s4.1. */
    fun dfuStart(body: IntArray): OuraCommand =
        OuraCommand("DANGEROUS_dfu_start", intArrayOf(0x2B, body.size and 0xFF) + body)

    /** 0x2C DFU bulk payload chunk (OTA firmware data). Per OURA_PROTOCOL.md s4.1. */
    fun dfuBulk(body: IntArray): OuraCommand =
        OuraCommand("DANGEROUS_dfu_bulk", intArrayOf(0x2C, body.size and 0xFF) + body)
}
