package com.wstt.client

internal data class VkModeSelection(
    val authMode: String,
    val hashMode: String,
)

internal fun normalizeVkModeSelection(
    requestedAuthMode: String?,
    requestedHashMode: String?,
    hasVkToken: Boolean,
): VkModeSelection {
    val authMode = when (requestedAuthMode) {
        WsttConstants.VkAuth.MODE_CAPTCHA -> WsttConstants.VkAuth.MODE_CAPTCHA
        WsttConstants.VkAuth.MODE_AUTO_JS -> WsttConstants.VkAuth.MODE_AUTO_JS
        else -> WsttConstants.VkAuth.MODE_CALLS
    }
    val hashMode = when (requestedHashMode) {
        "auto", WsttConstants.VkAutoHash.MODE_AUTO_API -> WsttConstants.VkAutoHash.MODE_AUTO_API
        WsttConstants.VkAutoHash.MODE_AUTO_JS -> WsttConstants.VkAutoHash.MODE_AUTO_JS
        else -> WsttConstants.VkAutoHash.MODE_MANUAL
    }
    return when {
        authMode == WsttConstants.VkAuth.MODE_AUTO_JS ||
            hashMode == WsttConstants.VkAutoHash.MODE_AUTO_JS ->
            VkModeSelection(
                authMode = WsttConstants.VkAuth.MODE_AUTO_JS,
                hashMode = WsttConstants.VkAutoHash.MODE_AUTO_JS,
            )
        else -> VkModeSelection(authMode = authMode, hashMode = hashMode)
    }
}

internal fun vkHashModeForAuthMode(
    requestedAuthMode: String,
    currentHashMode: String?,
    hasVkToken: Boolean,
): String = when (requestedAuthMode) {
    WsttConstants.VkAuth.MODE_AUTO_JS -> WsttConstants.VkAutoHash.MODE_AUTO_JS
    WsttConstants.VkAuth.MODE_CALLS -> if (currentHashMode == WsttConstants.VkAutoHash.MODE_AUTO_JS) {
        if (hasVkToken) WsttConstants.VkAutoHash.MODE_AUTO_API else WsttConstants.VkAutoHash.MODE_MANUAL
    } else {
        normalizeVkModeSelection(requestedAuthMode, currentHashMode, hasVkToken).hashMode
    }
    else -> normalizeVkModeSelection(requestedAuthMode, currentHashMode, hasVkToken).hashMode
}

internal fun vkAuthModeForHashMode(requestedHashMode: String, currentAuthMode: String?): String =
    when (requestedHashMode) {
        WsttConstants.VkAutoHash.MODE_AUTO_JS -> WsttConstants.VkAuth.MODE_AUTO_JS
        WsttConstants.VkAutoHash.MODE_AUTO_API -> WsttConstants.VkAuth.MODE_CALLS
        else -> if (currentAuthMode == WsttConstants.VkAuth.MODE_AUTO_JS) {
            WsttConstants.VkAuth.MODE_CALLS
        } else {
            normalizeVkModeSelection(currentAuthMode, requestedHashMode, false).authMode
        }
    }

internal fun shouldReplaceUnavailableVkHash(hashMode: String): Boolean =
    hashMode != WsttConstants.VkAutoHash.MODE_MANUAL

internal fun shouldConfirmAutoJsMode(
    currentMode: String,
    requestedMode: String,
    warningAcknowledged: Boolean,
): Boolean =
    !warningAcknowledged &&
        currentMode != WsttConstants.VkAuth.MODE_AUTO_JS &&
        requestedMode == WsttConstants.VkAuth.MODE_AUTO_JS
