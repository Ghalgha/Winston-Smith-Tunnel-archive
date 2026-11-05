package com.wstt.client.ui

import com.wstt.client.showRaisedToast
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.wstt.client.DeployManager
import com.wstt.client.LogEntry
import com.wstt.client.R
import com.wstt.client.SettingsStore
import com.wstt.client.TunnelManager
import com.wstt.client.ui.components.WsttEmptyState
import com.wstt.client.ui.components.WsttScreen
import com.wstt.client.ui.components.WsttSettingRow
import com.wstt.client.ui.design.WsttShapes
import com.wstt.client.ui.design.WsttSpacing
import com.wstt.client.ui.design.WsttTheme
import kotlinx.coroutines.launch

import androidx.compose.foundation.BorderStroke

@Composable
fun LogsTab(settingsStore: SettingsStore) {
    val loggingEnabled by settingsStore.loggingEnabled.collectAsStateWithLifecycle(initialValue = true)
    val scope = rememberCoroutineScope()

    WsttScreen {
        AppSectionCard(
            contentPadding = PaddingValues(horizontal = WsttSpacing.Md, vertical = WsttSpacing.Xs),
            verticalArrangement = Arrangement.spacedBy(WsttSpacing.None),
        ) {
            WsttSettingRow(
                title = stringResource(R.string.logs_enabled),
                checked = loggingEnabled,
                onCheckedChange = { enabled ->
                    TunnelManager.isLoggingEnabled = enabled
                    scope.launch {
                        settingsStore.saveLoggingEnabled(enabled)
                    }
                },
            )
        }

        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            shape = WsttShapes.Card,
            color = WsttTheme.extendedColors.terminalBackground,
            contentColor = WsttTheme.extendedColors.terminalText,
        ) {
            LogsTerminal()
        }
    }
}

@Composable
private fun LogsTerminal() {
    val context = LocalContext.current
    val currentLogs = TunnelManager.logs
    val listState = rememberLazyListState()
    val copiedMessage = stringResource(R.string.logs_copied)
    val isDeploying by DeployManager.isDeploying.collectAsStateWithLifecycle()

    LaunchedEffect(currentLogs.size, isDeploying) {
        if (isDeploying) {
            val latestDeployIndex = currentLogs.indexOfLast { it.key.startsWith("deploy_") }
            if (latestDeployIndex >= 0) listState.animateScrollToItem(latestDeployIndex)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (currentLogs.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                WsttEmptyState(
                    title = stringResource(R.string.logs_empty_title),
                    icon = Icons.Outlined.Terminal,
                    modifier = Modifier.padding(WsttSpacing.Md),
                    contentColor = WsttTheme.extendedColors.terminalText,
                    secondaryContentColor = WsttTheme.extendedColors.terminalMuted,
                )
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = WsttSpacing.Md, top = WsttSpacing.Md, end = WsttSpacing.Md, bottom = 64.dp),
                verticalArrangement = Arrangement.spacedBy(WsttSpacing.Xs),
            ) {
                items(
                    items = currentLogs,
                    key = { it.key },
                    contentType = { "log_line" },
                ) { entry ->
                    LogLine(entry)
                }
            }
        }

        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(
                onClick = {
                    val text = currentLogs.joinToString("\n") { "${it.message} (x${it.count})" }
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(ClipData.newPlainText("WSTT Logs", text))
                    context.showRaisedToast(copiedMessage, Toast.LENGTH_SHORT)
                },
                enabled = currentLogs.isNotEmpty(),
                modifier = Modifier.size(40.dp)
            ) {
                Icon(
                    imageVector = Icons.Outlined.ContentCopy,
                    contentDescription = stringResource(R.string.action_copy),
                    tint = if (currentLogs.isNotEmpty()) Color.White else Color.White.copy(alpha = 0.4f),
                    modifier = Modifier.size(22.dp)
                )
            }

            IconButton(
                onClick = TunnelManager::clearLogs,
                modifier = Modifier.size(40.dp)
            ) {
                Icon(
                    imageVector = Icons.Outlined.Delete,
                    contentDescription = stringResource(R.string.action_clear),
                    tint = Color.White,
                    modifier = Modifier.size(22.dp)
                )
            }
        }
    }
}

