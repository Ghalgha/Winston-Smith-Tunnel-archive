package com.wstt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import java.io.File
import org.junit.Test

class VpnConfigurationTest {
    @Test
    fun defaultMtuIs1500() {
        assertEquals(1500, WsttConstants.Vpn.DEFAULT_MTU)
    }

    @Test
    fun wsttUsesItsOwnTunSocketNamespace() {
        assertEquals("wstt_tun_uds", TunnelManager.TUN_UDS_NAME)
        assertTrue(
            File("src/main/java/com/wstt/client/TunnelManager.kt")
                .readText()
                .contains("\"-tun-uds\", TUN_UDS_NAME")
        )
        assertTrue(
            File("src/main/java/com/wstt/client/TunVpnService.kt")
                .readText()
                .contains("LocalSocketAddress(TunnelManager.TUN_UDS_NAME")
        )
    }

    @Test
    fun tunRecoveryRefusesForeignListenersBeforeSignalling() {
        val deployScript = File("src/main/assets/deploy.sh").readText()
        val recovery = deployScript
            .substringAfter("release_owned_peer_port() {")
            .substringBefore("\n}\n\nrelease_owned_peer_port || exit")

        assertTrue(recovery.contains("if ! wstt_process_is_owned"))
        assertTrue(deployScript.contains("readlink \"/proc/\$pid/exe\""))
        assertFalse(deployScript.contains("/proc/\$pid/cmdline"))
        assertTrue(recovery.indexOf("wstt_process_is_owned") < recovery.indexOf("kill -TERM"))
        assertFalse(recovery.contains("kill -KILL"))
    }
}
