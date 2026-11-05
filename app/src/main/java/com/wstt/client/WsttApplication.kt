package com.wstt.client

import android.app.Application
import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
class WsttApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DeployManager.init(this)

        CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            try {
                TunnelManager.running.collect {
                    VpnWidgetProvider.updateAllWidgets(this@WsttApplication)
                }
            } catch (e: Exception) {
                Log.e("WsttApp", "Не удалось обновить виджеты: ${e.message}")
            }
        }

        val settingsStore = SettingsStore(this)
        CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            try {
                settingsStore.loggingEnabled.collect { enabled ->
                    TunnelManager.isLoggingEnabled = enabled
                }
            } catch (e: Exception) {
                Log.e("WsttApp", "Не удалось отслеживать флаг логирования: ${e.message}")
            }
        }
    }
}
