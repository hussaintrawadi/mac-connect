package com.androidbridge.features.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString

class ClipboardBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private var lastSentText: String? = null
    private var ignoreNextChange = false
    private var isMonitoring = false

    fun startMonitoring() {
        if (isMonitoring) return
        clipboardManager.addPrimaryClipChangedListener {
            if (ignoreNextChange) {
                ignoreNextChange = false
                return@addPrimaryClipChangedListener
            }
            onClipboardChanged()
        }
        isMonitoring = true
        Log.i(TAG, "Clipboard monitoring started")
    }

    /**
     * Read + forward the clipboard NOW. Called periodically by the
     * AccessibilityService (TouchInjectionService), which is exempt from the
     * Android 10+ background clipboard restriction — so copying on the phone
     * reaches the Mac even when this app isn't in the foreground.
     */
    fun pollClipboard() {
        onClipboardChanged()
    }

    private fun onClipboardChanged() {
        try {
            val clip = clipboardManager.primaryClip ?: return
            if (clip.itemCount == 0) return

            val item = clip.getItemAt(0)

            val text = item.text?.toString()
            if (text != null && text != lastSentText) {
                lastSentText = text
                sendClipboard(text)
                return
            }

            val uri = item.uri
            if (uri != null) {
                if (uri.toString().startsWith("http")) {
                    sendClipboardUrl(uri.toString())
                } else {
                    // A copied image (screenshot "copy", Gallery, etc.) arrives as a
                    // content:// URI — read it and ship it to the Mac as PNG.
                    sendClipboardImage(uri)
                }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot read clipboard (background restriction)", e)
        }
    }

    private fun sendClipboardImage(uri: android.net.Uri) {
        Thread {
            try {
                val input = context.contentResolver.openInputStream(uri) ?: return@Thread
                val bmp = android.graphics.BitmapFactory.decodeStream(input)
                input.close()
                if (bmp == null) return@Thread

                // Cap the long edge at 2000px so the transfer stays quick.
                val maxDim = maxOf(bmp.width, bmp.height)
                val scaled = if (maxDim > 2000) {
                    val s = 2000f / maxDim
                    android.graphics.Bitmap.createScaledBitmap(
                        bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true
                    )
                } else bmp

                val out = java.io.ByteArrayOutputStream()
                scaled.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                if (scaled != bmp) scaled.recycle()
                bmp.recycle()

                val sync = ClipboardSync.newBuilder()
                    .setType(ClipboardSync.ContentType.IMAGE)
                    .setImageData(ByteString.copyFrom(out.toByteArray()))
                    .setMimeType("image/png")
                    .build()
                val envelope = Envelope.newBuilder()
                    .setTimestampMs(System.currentTimeMillis())
                    .setClipboardSync(sync)
                    .build()
                onSendEnvelope?.invoke(envelope)
                Log.i(TAG, "Clipboard image sent (${out.size()} bytes)")
            } catch (e: Exception) {
                Log.w(TAG, "Clipboard image send failed", e)
            }
        }.start()
    }

    /**
     * Call from MainActivity.onResume() to read clipboard when app is foregrounded.
     * On Android 10+, clipboard can only be read when the app has focus.
     */
    fun checkClipboardOnResume() {
        try {
            onClipboardChanged()
        } catch (e: Exception) {
            Log.w(TAG, "Clipboard check on resume failed", e)
        }
    }

    private fun sendClipboard(text: String) {
        val isUrl = text.startsWith("http://") || text.startsWith("https://")

        val sync = ClipboardSync.newBuilder()
            .setType(if (isUrl) ClipboardSync.ContentType.URL else ClipboardSync.ContentType.TEXT)
            .setText(text)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setClipboardSync(sync)
            .build()

        onSendEnvelope?.invoke(envelope)
        Log.d(TAG, "Clipboard sent: ${text.take(50)}")
    }

    private fun sendClipboardUrl(url: String) {
        val sync = ClipboardSync.newBuilder()
            .setType(ClipboardSync.ContentType.URL)
            .setText(url)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setClipboardSync(sync)
            .build()

        onSendEnvelope?.invoke(envelope)
        Log.d(TAG, "Clipboard URL sent: $url")
    }

    fun applyFromMac(sync: ClipboardSync) {
        ignoreNextChange = true

        when (sync.type) {
            ClipboardSync.ContentType.TEXT, ClipboardSync.ContentType.URL -> {
                val clip = ClipData.newPlainText("AndroidBridge", sync.text)
                clipboardManager.setPrimaryClip(clip)
                lastSentText = sync.text
                Log.d(TAG, "Clipboard applied from Mac: ${sync.text.take(50)}")
            }

            ClipboardSync.ContentType.IMAGE -> {
                try {
                    // Write to cache and put a FileProvider URI on the clipboard —
                    // the system grants paste targets read access automatically.
                    val file = java.io.File(context.cacheDir, "mac_clipboard.png")
                    file.writeBytes(sync.imageData.toByteArray())
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        context, "${context.packageName}.fileprovider", file
                    )
                    val clip = ClipData.newUri(context.contentResolver, "Mac image", uri)
                    clipboardManager.setPrimaryClip(clip)
                    Log.i(TAG, "Clipboard image applied from Mac (${sync.imageData.size()} bytes)")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to apply Mac clipboard image", e)
                }
            }

            else -> {}
        }
    }

    companion object {
        private const val TAG = "ClipboardBridge"
        var instance: ClipboardBridge? = null
    }
}
