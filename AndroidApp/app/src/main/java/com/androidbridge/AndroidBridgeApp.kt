package com.androidbridge

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.util.Log

class AndroidBridgeApp : Application() {

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "AndroidBridge starting up")
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        val connectionChannel = NotificationChannel(
            CHANNEL_CONNECTION,
            getString(R.string.channel_connection),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.channel_connection_desc)
            setShowBadge(false)
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(connectionChannel)
    }

    companion object {
        const val TAG = "AndroidBridge"
        const val CHANNEL_CONNECTION = "connection"
    }
}
