package com.androidbridge.features.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Manifest-registered PHONE_STATE receiver — the most reliable incoming-call
 * signal on OEM ROMs (MIUI aggressively throttles in-process telephony
 * callbacks). PHONE_STATE is on Android's implicit-broadcast exemption list,
 * so this fires even when the app process is idle.
 */
class CallStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
        @Suppress("DEPRECATION")
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
        Log.i(TAG, "PHONE_STATE broadcast: $state")

        val bridge = CallBridge.instance
        if (bridge != null) {
            bridge.callStateMonitor.handleExternalState(state, number)
        } else {
            Log.w(TAG, "CallBridge not running — call event dropped (service not started)")
        }
    }

    companion object {
        private const val TAG = "CallStateReceiver"
    }
}
