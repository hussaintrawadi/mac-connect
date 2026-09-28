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

        // Find-My-Phone alarm: high importance so it can ring loudly + show a
        // full-screen "Stop" screen even when the phone is idle/locked.
        val findPhoneChannel = NotificationChannel(
            CHANNEL_FIND_PHONE,
            getString(R.string.channel_find_phone),
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = getString(R.string.channel_find_phone_desc)
            setShowBadge(true)
            setBypassDnd(true)   // it's a "find my device" alarm — should cut through
            enableVibration(true)
            enableLights(true)
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(connectionChannel)
        manager.createNotificationChannel(findPhoneChannel)
    }

    companion object {
        const val TAG = "AndroidBridge"
        const val CHANNEL_CONNECTION = "connection"
        const val CHANNEL_FIND_PHONE = "find_phone"
    }
}
