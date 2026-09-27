package com.androidbridge.features.urlhandoff

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.androidbridge.proto.Messages.*

class UrlHandoffBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    fun openUrlFromMac(handoff: UrlHandoff) {
        val url = handoff.url
        if (url.isBlank()) return

        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            Log.i(TAG, "Opened URL from Mac: $url")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open URL: $url", e)
        }
    }

    fun sendUrlToMac(url: String, title: String = "") {
        val handoff = UrlHandoff.newBuilder()
            .setUrl(url)
            .setTitle(title)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setUrlHandoff(handoff)
            .build()

        onSendEnvelope?.invoke(envelope)
        Log.i(TAG, "URL sent to Mac: $url")
    }

    companion object {
        private const val TAG = "UrlHandoff"
        var instance: UrlHandoffBridge? = null
    }
}
