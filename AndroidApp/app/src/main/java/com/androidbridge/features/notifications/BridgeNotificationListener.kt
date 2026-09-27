package com.androidbridge.features.notifications

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString
import java.io.ByteArrayOutputStream

class BridgeNotificationListener : NotificationListenerService() {

    private val excludedPackages = mutableSetOf(
        "com.androidbridge",
        "android",
        "com.android.systemui"
    )

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName in excludedPackages) return
        if (sbn.isOngoing) return

        val event = buildNotificationEvent(sbn) ?: return

        Log.d(TAG, "Notification from ${sbn.packageName}: ${event.title}")
        NotificationBridge.instance?.onNotificationReceived(event)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        Log.d(TAG, "Notification removed: ${sbn.packageName}")
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "NotificationListener connected")
        NotificationBridge.listenerService = this
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.i(TAG, "NotificationListener disconnected")
        NotificationBridge.listenerService = null
    }

    private fun buildNotificationEvent(sbn: StatusBarNotification): NotificationEvent? {
        val notification = sbn.notification
        val extras = notification.extras

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val body = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

        if (title.isEmpty() && body.isEmpty()) return null

        val appName = getAppName(sbn.packageName)
        val hasReply = findReplyAction(notification) != null
        val category = notification.category ?: ""

        val builder = NotificationEvent.newBuilder()
            .setNotificationId(sbn.key)
            .setAppPackage(sbn.packageName)
            .setAppName(appName)
            .setTitle(title)
            .setBody(body)
            .setTimestampMs(sbn.postTime)
            .setHasReplyAction(hasReply)
            .setIsDismissable(sbn.isClearable)
            .setCategory(category)

        val iconBytes = extractIconBytes(notification, sbn.packageName)
        if (iconBytes != null) {
            builder.iconPng = ByteString.copyFrom(iconBytes)
        }

        return builder.build()
    }

    private fun getAppName(packageName: String): String {
        return try {
            val pm = packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            packageName
        }
    }

    private fun extractIconBytes(notification: Notification, packageName: String): ByteArray? {
        return try {
            val icon = notification.smallIcon ?: return null
            val drawable = icon.loadDrawable(this) ?: return null

            val bitmap = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bitmap)
            drawable.setBounds(0, 0, 48, 48)
            drawable.draw(canvas)

            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 80, stream)
            bitmap.recycle()
            stream.toByteArray()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to extract icon for $packageName", e)
            null
        }
    }

    fun executeAction(notificationId: String, action: NotificationAction.Action, replyText: String?) {
        when (action) {
            NotificationAction.Action.DISMISS -> {
                cancelNotification(notificationId)
                Log.d(TAG, "Dismissed notification: $notificationId")
            }

            NotificationAction.Action.REPLY -> {
                if (replyText != null) {
                    sendReply(notificationId, replyText)
                }
            }

            NotificationAction.Action.MARK_READ -> {
                cancelNotification(notificationId)
            }

            else -> Log.w(TAG, "Unknown action: $action")
        }
    }

    private fun sendReply(notificationKey: String, text: String) {
        val activeNotifications = getActiveNotifications() ?: return
        val sbn = activeNotifications.find { it.key == notificationKey } ?: return

        val replyAction = findReplyAction(sbn.notification) ?: run {
            Log.w(TAG, "No reply action found for $notificationKey")
            return
        }

        val remoteInputs = replyAction.remoteInputs ?: return
        val intent = Intent()
        val bundle = Bundle()

        for (remoteInput in remoteInputs) {
            bundle.putCharSequence(remoteInput.resultKey, text)
        }

        RemoteInput.addResultsToIntent(remoteInputs, intent, bundle)

        try {
            replyAction.actionIntent.send(this, 0, intent)
            Log.i(TAG, "Reply sent to $notificationKey: $text")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send reply", e)
        }
    }

    private fun findReplyAction(notification: Notification): Notification.Action? {
        return notification.actions?.find { action ->
            action.remoteInputs?.isNotEmpty() == true
        }
    }

    fun addExcludedPackage(packageName: String) {
        excludedPackages.add(packageName)
    }

    fun removeExcludedPackage(packageName: String) {
        excludedPackages.remove(packageName)
    }

    companion object {
        private const val TAG = "NotificationListener"
    }
}
