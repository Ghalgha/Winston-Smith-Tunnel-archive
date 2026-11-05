package com.wstt.client

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
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
    fun currentAndLegacyConnectionSchemesResolveToTheApp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val schemes = listOf("wstt://connect", "csqtt://connect")

        schemes.forEach { uri ->
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
                .setPackage(context.packageName)
            val resolved = context.packageManager.resolveActivity(
                intent,
                PackageManager.MATCH_DEFAULT_ONLY,
            )

            assertNotNull("No activity resolves $uri", resolved)
            assertEquals(context.packageName, resolved?.activityInfo?.packageName)
        }
    }
}
