package com.androidbridge.features.screenmirror

import android.content.Context
import android.content.Intent
import android.util.Log
import com.androidbridge.proto.Messages.*

class ScreenMirrorBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    val screenCapture = ScreenCapture(context)

    init {
        screenCapture.onSendEnvelope = { envelope -> onSendEnvelope?.invoke(envelope) }
        ScreenCapture.instance = screenCapture
    }

    fun startMirroring(resultCode: Int, data: Intent) {
        screenCapture.startCapture(resultCode, data)
    }

    fun stopMirroring() {
        screenCapture.stopCapture()
    }

    fun handleTouchEvent(event: TouchEvent) {
        val service = TouchInjectionService.instance ?: run {
            Log.w(TAG, "TouchInjectionService not connected")
            return
        }
        service.handleTouchEvent(event)
    }

    fun handleKeyEvent(event: KeyEvent) {
        val service = TouchInjectionService.instance ?: run {
            Log.w(TAG, "TouchInjectionService not connected")
            return
        }
        service.handleKeyEvent(event)
    }

    fun handleScrollEvent(event: ScrollEvent) {
        val service = TouchInjectionService.instance ?: run {
            Log.w(TAG, "TouchInjectionService not connected")
            return
        }
        service.handleScrollEvent(event)
    }

    companion object {
        private const val TAG = "ScreenMirrorBridge"
        var instance: ScreenMirrorBridge? = null
    }
}
