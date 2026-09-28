package com.androidbridge.features.filesystem

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast

/**
 * Makes "Mac Connect" appear in the Android share sheet. When the user shares one
 * or more files to it, we stream them to the Mac (AirDrop-style) and finish — no UI.
 */
class ShareReceiverActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val uris: List<Uri> = when (intent?.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) listOf(uri) else emptyList()
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            }
            else -> emptyList()
        }

        if (uris.isEmpty()) {
            toast("Nothing to send")
            finish()
            return
        }

        val bridge = FileSystemBridge.instance
        if (bridge == null) {
            toast("Mac Connect isn’t connected to your Mac")
            finish()
            return
        }

        var sent = 0
        for (uri in uris) {
            try {
                if (bridge.pushUriToMac(uri)) sent++
            } catch (e: Exception) {
                Log.e(TAG, "Failed to push $uri", e)
            }
        }

        toast(
            when {
                sent == 0 -> "Couldn’t send — not connected to your Mac"
                sent == 1 -> "Sending to your Mac…"
                else -> "Sending $sent files to your Mac…"
            }
        )
        finish()
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val TAG = "ShareReceiver"
    }
}
