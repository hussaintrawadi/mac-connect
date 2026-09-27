package com.androidbridge.features.notifications

import android.util.Log
import com.androidbridge.proto.Messages.*

class NotificationBridge {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    fun onNotificationReceived(event: NotificationEvent) {
        val envelope = Envelope.newBuilder()
            .setSequence(0)
            .setTimestampMs(System.currentTimeMillis())
            .setNotificationEvent(event)
            .build()

        onSendEnvelope?.invoke(envelope) ?: Log.w(TAG, "No send handler — notification dropped")
    }

    fun handleNotificationAction(action: NotificationAction) {
        val listener = listenerService ?: run {
            Log.w(TAG, "NotificationListener not connected")
            return
        }

        listener.executeAction(
            action.notificationId,
            action.action,
            if (action.replyText.isNotEmpty()) action.replyText else null
        )
    }

    companion object {
        private const val TAG = "NotificationBridge"
        var instance: NotificationBridge? = null
        var listenerService: BridgeNotificationListener? = null
    }
}
