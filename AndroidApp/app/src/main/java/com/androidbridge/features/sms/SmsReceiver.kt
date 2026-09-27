package com.androidbridge.features.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        val grouped = messages.groupBy { it.originatingAddress ?: "unknown" }

        // Note: forwarding to the Mac is handled by SmsBridge's ContentObserver,
        // which catches incoming + outgoing + bulk messages once they're written to
        // the SMS database. This receiver just nudges that to run promptly.
        for ((sender, parts) in grouped) {
            val body = parts.joinToString("") { it.messageBody ?: "" }
            Log.d(TAG, "SMS_RECEIVED from $sender: ${body.take(50)}")
        }
    }

    companion object {
        private const val TAG = "SmsReceiver"
    }
}
