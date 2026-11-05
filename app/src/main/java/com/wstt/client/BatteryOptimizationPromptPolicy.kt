package com.wstt.client

internal fun shouldRequestBatteryOptimizationExemption(
    promptHandled: Boolean,
    alreadyExempt: Boolean,
): Boolean = !promptHandled && !alreadyExempt
