package com.wstt.client

internal fun resolveTunnelPasswordStorage(
    persistentValue: String?,
    legacyValue: String?,
    encryptedValue: String?,
    decrypt: (String?) -> String?,
): StoredSecret {
    val fallback = persistentValue?.takeIf { it.isNotBlank() } ?: legacyValue
    return resolveStoredSecret(encryptedValue, fallback, decrypt)
}

internal fun shouldResetUnreadableTunnelPassword(
    persistentValue: String?,
    legacyValue: String?,
    encryptedValue: String?,
    decrypt: (String?) -> String?,
): Boolean = resolveTunnelPasswordStorage(
    persistentValue,
    legacyValue,
    encryptedValue,
    decrypt,
).state == StoredSecretState.Unreadable
