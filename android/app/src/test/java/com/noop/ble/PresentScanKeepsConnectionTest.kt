package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #74 keep/teardown decision for the Add-a-WHOOP present-scan
 * ([WhoopBleClient.shouldKeepLiveConnectionForPresentScan], driven by prepareForPresentScan) - the
 * Android half of the v5.2.3 iOS fix. Opening the wizard (or tapping Rescan) with a LIVE same-model
 * strap must keep the connection: the old unconditional prepareForModelSwitch dropped it mid-session,
 * left it disconnected for good when the wizard was dismissed without picking (intentionalDisconnect +
 * lastDevice = null), and on a 5/MG risked the insufficient-auth re-bond refusal loop. A genuine family
 * switch (or no connection at all) still idles the engine so the scan starts clean. Android
 * [WhoopModel] has exactly two members (one per family), so enum equality IS the family check.
 */
class PresentScanKeepsConnectionTest {

    @Test
    fun connectedSameModel_keepsTheLiveConnection() {
        assertTrue(WhoopBleClient.shouldKeepLiveConnectionForPresentScan(
            connected = true, selected = WhoopModel.WHOOP5_MG, requested = WhoopModel.WHOOP5_MG))
        assertTrue(WhoopBleClient.shouldKeepLiveConnectionForPresentScan(
            connected = true, selected = WhoopModel.WHOOP4, requested = WhoopModel.WHOOP4))
    }

    @Test
    fun connectedOtherModel_idlesForTheFamilySwitch() {
        // A live 4.0 while the wizard scans for a 5/MG is a genuine switch - the engine must idle first.
        assertFalse(WhoopBleClient.shouldKeepLiveConnectionForPresentScan(
            connected = true, selected = WhoopModel.WHOOP4, requested = WhoopModel.WHOOP5_MG))
        assertFalse(WhoopBleClient.shouldKeepLiveConnectionForPresentScan(
            connected = true, selected = WhoopModel.WHOOP5_MG, requested = WhoopModel.WHOOP4))
    }

    @Test
    fun disconnectedSameModel_idles() {
        // Nothing to keep - the scan starts clean exactly as before the fix.
        assertFalse(WhoopBleClient.shouldKeepLiveConnectionForPresentScan(
            connected = false, selected = WhoopModel.WHOOP5_MG, requested = WhoopModel.WHOOP5_MG))
    }

    @Test
    fun disconnectedOtherModel_idles() {
        assertFalse(WhoopBleClient.shouldKeepLiveConnectionForPresentScan(
            connected = false, selected = WhoopModel.WHOOP4, requested = WhoopModel.WHOOP5_MG))
    }
}
