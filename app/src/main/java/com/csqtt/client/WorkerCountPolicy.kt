package com.wstt.client

internal object WorkerCountPolicy {
    fun normalize(
        requested: Int,
        maximum: Int = WsttConstants.Tunnel.MAX_WORKERS,
    ): Int {
        if (requested <= 5) {
            return 5
        }
        val group = WsttConstants.Tunnel.WORKERS_PER_GROUP
        val normalizedMaximum = (maximum.coerceAtLeast(group) / group) * group
        val clamped = requested.coerceIn(5, normalizedMaximum)
        val rounded = (clamped / group) * group
        return rounded.coerceAtLeast(5)
    }

    fun maximumForHashes(hashCount: Int): Int {
        val count = hashCount.coerceIn(1, WsttConstants.Tunnel.MAX_VK_HASHES)
        return (count * WsttConstants.Tunnel.WORKERS_PER_GROUP).coerceIn(5, WsttConstants.Tunnel.MAX_WORKERS)
    }

    fun maximumForSources(
        linkMode: Boolean,
        linkHashCount: Int,
        autoHashMode: Boolean,
        manualHashCount: Int,
    ): Int = WsttConstants.Tunnel.MAX_WORKERS

    fun defaultMaximum(extraWorkers: Boolean = false): Int = WsttConstants.Tunnel.MAX_WORKERS

    fun normalizeForHashes(requested: Int, hashCount: Int): Int =
        normalize(requested, maximumForHashes(hashCount))

    fun normalizeForHashValues(
        requested: Int,
        hashes: Iterable<String>,
        allowRedistribution: Boolean = false,
    ): Int {
        return normalize(requested, WsttConstants.Tunnel.MAX_WORKERS)
    }

}
