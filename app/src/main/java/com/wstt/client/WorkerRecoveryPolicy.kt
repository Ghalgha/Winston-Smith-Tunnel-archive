package com.wstt.client

internal class WorkerRecoveryPolicy(
    private val minimumPeak: Int = WsttConstants.Tunnel.WORKERS_PER_GROUP,
) {
    private var peak = 0
    private var armedTarget = 0

    @Synchronized
    fun observe(active: Int): Boolean {
        val bounded = active.coerceAtLeast(0)
        peak = maxOf(peak, bounded)
        if (armedTarget != 0 && bounded >= armedTarget) {
            armedTarget = 0
            return true
        }
        return false
    }

    @Synchronized
    fun armAtZero(): Int? {
        if (armedTarget != 0) return armedTarget
        if (peak < minimumPeak) return null
        armedTarget = peak
        return armedTarget
    }

    @Synchronized
    fun shouldRecover(active: Int, target: Int): Boolean =
        armedTarget == target && active.coerceAtLeast(0) < target

    @Synchronized
    fun reset() {
        peak = 0
        armedTarget = 0
    }
}
