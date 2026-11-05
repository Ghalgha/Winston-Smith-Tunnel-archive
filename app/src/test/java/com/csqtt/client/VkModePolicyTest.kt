package com.wstt.client

import org.junit.Assert.assertEquals
import org.junit.Test

class VkModePolicyTest {
    @Test
    fun autoVkHashSelectsAutoVkWorkMode() {
        assertEquals(
            WsttConstants.VkAuth.MODE_AUTO_JS,
            vkAuthModeForHashMode(
                WsttConstants.VkAutoHash.MODE_AUTO_JS,
                WsttConstants.VkAuth.MODE_CALLS,
            ),
        )
    }

    @Test
    fun autoVkWorkModeSelectsAutoVkHashes() {
        assertEquals(
            WsttConstants.VkAutoHash.MODE_AUTO_JS,
            vkHashModeForAuthMode(
                WsttConstants.VkAuth.MODE_AUTO_JS,
                WsttConstants.VkAutoHash.MODE_AUTO_API,
                hasVkToken = true,
            ),
        )
    }

    @Test
    fun autoApiHashLeavesAutoVkWorkMode() {
        assertEquals(
            WsttConstants.VkAuth.MODE_CALLS,
            vkAuthModeForHashMode(
                WsttConstants.VkAutoHash.MODE_AUTO_API,
                WsttConstants.VkAuth.MODE_AUTO_JS,
            ),
        )
    }

    @Test
    fun autoWorkModeMovesAutoVkHashesToAvailableNonVkMode() {
        assertEquals(
            WsttConstants.VkAutoHash.MODE_AUTO_API,
            vkHashModeForAuthMode(
                WsttConstants.VkAuth.MODE_CALLS,
                WsttConstants.VkAutoHash.MODE_AUTO_JS,
                hasVkToken = true,
            ),
        )
        assertEquals(
            WsttConstants.VkAutoHash.MODE_MANUAL,
            vkHashModeForAuthMode(
                WsttConstants.VkAuth.MODE_CALLS,
                WsttConstants.VkAutoHash.MODE_AUTO_JS,
                hasVkToken = false,
            ),
        )
    }

    @Test
    fun manualHashLeavesAutoVkWorkMode() {
        assertEquals(
            WsttConstants.VkAuth.MODE_CALLS,
            vkAuthModeForHashMode(
                WsttConstants.VkAutoHash.MODE_MANUAL,
                WsttConstants.VkAuth.MODE_AUTO_JS,
            ),
        )
    }

    @Test
    fun unavailableManualHashStaysInCurrentProcessWhileAutoHashIsReplaced() {
        assertEquals(
            false,
            shouldReplaceUnavailableVkHash(WsttConstants.VkAutoHash.MODE_MANUAL),
        )
        assertEquals(
            true,
            shouldReplaceUnavailableVkHash(WsttConstants.VkAutoHash.MODE_AUTO_API),
        )
        assertEquals(
            true,
            shouldReplaceUnavailableVkHash(WsttConstants.VkAutoHash.MODE_AUTO_JS),
        )
    }

    @Test
    fun autoVkWarningAppearsOnlyWhenEnteringTheModeWithoutAcknowledgement() {
        assertEquals(
            true,
            shouldConfirmAutoJsMode(
                currentMode = WsttConstants.VkAuth.MODE_CALLS,
                requestedMode = WsttConstants.VkAuth.MODE_AUTO_JS,
                warningAcknowledged = false,
            ),
        )
        assertEquals(
            false,
            shouldConfirmAutoJsMode(
                currentMode = WsttConstants.VkAuth.MODE_AUTO_JS,
                requestedMode = WsttConstants.VkAuth.MODE_AUTO_JS,
                warningAcknowledged = false,
            ),
        )
        assertEquals(
            false,
            shouldConfirmAutoJsMode(
                currentMode = WsttConstants.VkAuth.MODE_CALLS,
                requestedMode = WsttConstants.VkAuth.MODE_AUTO_JS,
                warningAcknowledged = true,
            ),
        )
    }
}
