package com.wstt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelAuthSnapshotTest {
    @Test
    fun `default snapshot is a loading sentinel`() {
        assertFalse(TunnelAuthSnapshot().isLoaded)
    }

    @Test
    fun `profile snapshot is loaded even when password is genuinely empty`() {
        assertTrue(TunnelAuthSnapshot(profile = 0, connectionPassword = "").isLoaded)
    }

    @Test
    fun `snapshot keeps unreadable secret distinct from a missing value`() {
        val snapshot = TunnelAuthSnapshot(
            profile = 0,
            connectionPassword = "",
            connectionPasswordState = StoredSecretState.Unreadable,
        )

        assertTrue(snapshot.isLoaded)
        assertEquals(StoredSecretState.Unreadable, snapshot.connectionPasswordState)
    }

    @Test
    fun `participant snapshot keeps link and mode in one state`() {
        val snapshot = TunnelAuthSnapshot(
            profile = 0,
            wsttLink = "csqtt://connect?peer=example.test",
            wsttLinkMode = true,
        )

        assertTrue(snapshot.wsttLinkMode)
        assertEquals("csqtt://connect?peer=example.test", snapshot.wsttLink)
    }
}
