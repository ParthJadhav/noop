package com.noop.oura

// OuraGatt: the GATT layout facts for the Oura ring, as plain UUID strings + MTU values.
// Kotlin twin of the Swift OuraProtocol package (Packages/OuraProtocol). Platform-pure: this package
// NEVER imports android.bluetooth or CoreBluetooth, so the app layer is responsible for turning these
// strings into ParcelUuid / CBUUID. Keeping that out of here lets the protocol code run headless on
// the JVM (plain JUnit tests) unchanged.
//
// All facts cited tersely per docs/OURA_PROTOCOL.md s1 (GATT Layout). The RE repos were read for
// protocol facts ONLY; no RE source was copied.

object OuraGatt {
    // Base service shared by all generations (gen3/4/5). Per OURA_PROTOCOL.md s1.1.
    const val serviceUUID = "98ED0001-A541-11E4-B6A0-0002A5D5C51B"

    // Write characteristic (phone to ring), Write Without Response. Per OURA_PROTOCOL.md s1.1.
    const val writeCharacteristicUUID = "98ED0002-A541-11E4-B6A0-0002A5D5C51B"

    // Notify characteristic (ring to phone), Handle-Value-Notification. Per OURA_PROTOCOL.md s1.1.
    const val notifyCharacteristicUUID = "98ED0003-A541-11E4-B6A0-0002A5D5C51B"

    // Gen-5 extra characteristics. Roles UNCONFIRMED in the RE corpus, leave UNUSED in v1.
    // Per OURA_PROTOCOL.md s1.2: do not write to these. Listed for discovery completeness only.
    const val extraCharacteristic4UUID = "98ED0004-A541-11E4-B6A0-0002A5D5C51B"
    const val extraCharacteristic5UUID = "98ED0005-A541-11E4-B6A0-0002A5D5C51B"
    const val extraCharacteristic6UUID = "98ED0006-A541-11E4-B6A0-0002A5D5C51B"

    // MTU values per generation. Gen3 = 203, Gen4/5 = 247 (max payload = MTU - 3 ATT bytes).
    // Per OURA_PROTOCOL.md s1.2 / s1.3.
    const val mtuGen3 = 203
    const val mtuGen45 = 247

    // The ATT overhead subtracted from MTU to get the max writable payload. Per OURA_PROTOCOL.md s1.3.
    const val attOverhead = 3

    /**
     * The set of characteristic UUID strings the app must discover for a given generation.
     * Gen3/4 expose only ...0002/...0003 beyond the service; Gen5 additionally advertises
     * ...0004/5/6 (which v1 discovers but never writes to). Per OURA_PROTOCOL.md s1.2.
     */
    fun characteristicUUIDs(gen: OuraRingGen): List<String> = when (gen) {
        OuraRingGen.GEN3, OuraRingGen.GEN4 ->
            listOf(writeCharacteristicUUID, notifyCharacteristicUUID)
        OuraRingGen.GEN5 ->
            listOf(
                writeCharacteristicUUID, notifyCharacteristicUUID,
                extraCharacteristic4UUID, extraCharacteristic5UUID, extraCharacteristic6UUID,
            )
    }
}
