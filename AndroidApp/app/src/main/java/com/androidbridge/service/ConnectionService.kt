package com.androidbridge.service

import android.app.Activity
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.androidbridge.AndroidBridgeApp
import com.androidbridge.R
import com.androidbridge.connection.ConnectionManager
import com.androidbridge.connection.ConnectionState
import com.androidbridge.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class ConnectionService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var connectionManager: ConnectionManager
    private var lastState: ConnectionState = ConnectionState.Disconnected
    private var mirroringActive = false

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "ConnectionService created")

        connectionManager = ConnectionManager(this)

        // When the Mac asks to disconnect (to save phone battery), stop the service
        // and remember the disconnected state so MainActivity shows "Connect".
        connectionManager.onDisconnectRequested = {
            getSharedPreferences("androidbridge", MODE_PRIVATE)
                .edit().putBoolean("service_enabled", false).apply()
            Log.i(TAG, "Stopping service per Mac request")
            stopSelf()
        }

        startForegroundWithType(ConnectionState.Disconnected, includeMediaProjection = false)

        scope.launch {
            connectionManager.state.collect { state ->
                lastState = state
                updateNotification(state)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_MIRROR -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                if (resultCode == Activity.RESULT_OK && data != null) {
                    Log.i(TAG, "Starting screen mirror")
                    // Android 14+: FGS must include mediaProjection type BEFORE using projection
                    startForegroundWithType(lastState, includeMediaProjection = true)
                    mirroringActive = true
                    connectionManager.startMirroring(resultCode, data)
                } else {
                    Log.w(TAG, "Mirror start with invalid result")
                }
            }
            ACTION_STOP_MIRROR -> {
                Log.i(TAG, "Stopping screen mirror")
                connectionManager.stopMirroring()
                mirroringActive = false
                startForegroundWithType(lastState, includeMediaProjection = false)
            }
            else -> {
                Log.i(TAG, "ConnectionService started")
                connectionManager.start()
            }
        }
        return START_STICKY
    }

    private fun startForegroundWithType(state: ConnectionState, includeMediaProjection: Boolean) {
        val notification = buildNotification(state)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (includeMediaProjection && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                }
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            try { startForeground(NOTIFICATION_ID, notification) } catch (_: Exception) {}
        }
    }

    override fun onDestroy() {
        Log.i(TAG, "ConnectionService destroyed")
        connectionManager.stop()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(state: ConnectionState): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val text = when (state) {
            is ConnectionState.Connected -> getString(R.string.notification_connected, state.deviceName)
            is ConnectionState.Searching -> getString(R.string.notification_searching)
            else -> getString(R.string.notification_disconnected)
        }

        return NotificationCompat.Builder(this, AndroidBridgeApp.CHANNEL_CONNECTION)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher_foreground)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun updateNotification(state: ConnectionState) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(state))
    }

    companion object {
        private const val TAG = "ConnectionService"
        private const val NOTIFICATION_ID = 1
        const val ACTION_START_MIRROR = "com.androidbridge.START_MIRROR"
        const val ACTION_STOP_MIRROR = "com.androidbridge.STOP_MIRROR"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
    }
}
