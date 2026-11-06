package com.wstt.client

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppContractInstrumentationTest {
    @Test
    fun applicationIdentityAndApplicationClassAreInstalled() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext

        assertEquals("com.wstunnel.client", context.packageName)
        assertTrue(context.applicationContext is WsttApplication)
    }

    @Test
    fun currentConnectionSchemeResolvesToTheApp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val uri = "wstt://connect"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
            .setPackage(context.packageName)
        val resolved = context.packageManager.resolveActivity(
            intent,
            PackageManager.MATCH_DEFAULT_ONLY,
        )

        assertNotNull("No activity resolves $uri", resolved)
        assertEquals(context.packageName, resolved?.activityInfo?.packageName)
    }

    @Test
    fun settingsStoreInitializesEveryUiCacheFromDataStore() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = SettingsStore(context)

        val expected = listOf(
            store.vkHashMode.first(),
            store.vkAccessToken.first(),
            store.obfsMode.first(),
            store.turnTransport.first(),
            store.srtpMode.first(),
            store.wsttLinkMode.first(),
            store.workersPerHash.first(),
            store.manualPortsEnabled.first(),
            store.serverPeerPort.first(),
            store.excludedApps.first(),
            store.whitelistApps.first(),
            store.isWhitelist.first(),
        )

        withTimeout(10_000) {
            while (
                SettingsStore.cachedVkHashMode == null ||
                SettingsStore.cachedVkAccessToken == null ||
                SettingsStore.cachedObfsMode == null ||
                SettingsStore.cachedTurnTransport == null ||
                SettingsStore.cachedSrtpMode == null ||
                SettingsStore.cachedWsttLinkMode == null ||
                SettingsStore.cachedWorkersPerHash == null ||
                SettingsStore.cachedManualPortsEnabled == null ||
                SettingsStore.cachedServerPeerPort == null ||
                SettingsStore.cachedExcludedApps == null ||
                SettingsStore.cachedWhitelistApps == null ||
                SettingsStore.cachedIsWhitelist == null
            ) {
                delay(20)
            }
        }

        assertEquals(expected[0], SettingsStore.cachedVkHashMode)
        assertEquals(expected[1], SettingsStore.cachedVkAccessToken)
        assertEquals(expected[2], SettingsStore.cachedObfsMode)
        assertEquals(expected[3], SettingsStore.cachedTurnTransport)
        assertEquals(expected[4], SettingsStore.cachedSrtpMode)
        assertEquals(expected[5], SettingsStore.cachedWsttLinkMode)
        assertEquals(expected[6], SettingsStore.cachedWorkersPerHash)
        assertEquals(expected[7], SettingsStore.cachedManualPortsEnabled)
        assertEquals(expected[8], SettingsStore.cachedServerPeerPort)
        assertEquals(expected[9], SettingsStore.cachedExcludedApps)
        assertEquals(expected[10], SettingsStore.cachedWhitelistApps)
        assertEquals(expected[11], SettingsStore.cachedIsWhitelist)
    }
}
