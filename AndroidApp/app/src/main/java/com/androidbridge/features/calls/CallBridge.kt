package com.androidbridge.features.calls

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.androidbridge.proto.Messages.*

class CallBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    val callStateMonitor = CallStateMonitor(context)
    val callAudioBridge = CallAudioBridge()

    private var isInCall = false
    private var isStarted = false

    init {
        callStateMonitor.onCallEvent = { event -> handleCallStateChange(event) }
        callAudioBridge.onSendEnvelope = { envelope -> onSendEnvelope?.invoke(envelope) }
    }

    fun start() {
        if (isStarted) return
        isStarted = true
        callStateMonitor.start()
        Log.i(TAG, "CallBridge started")
    }

    // MARK: - Call State Changes (Android → Mac)

    private fun handleCallStateChange(event: CallEvent) {
        // Send event to Mac
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setCallEvent(event)
            .build()
        onSendEnvelope?.invoke(envelope)

        // Manage audio based on state
        when (event.state) {
            CallEvent.CallState.ACTIVE -> {
                if (!isInCall) {
                    isInCall = true
                    callAudioBridge.startCapture()
                    callAudioBridge.startPlayback()
                    Log.i(TAG, "Call active — audio bridge started")
                }
            }
            CallEvent.CallState.ENDED -> {
                if (isInCall) {
                    isInCall = false
                    callAudioBridge.stopCapture()
                    callAudioBridge.stopPlayback()
                    Log.i(TAG, "Call ended — audio bridge stopped")
                }
            }
            else -> {}
        }
    }

    // MARK: - Call Controls (Mac → Android)

    fun handleCallControl(control: CallControl) {
        when (control.action) {
            CallControl.Action.ANSWER -> {
                callStateMonitor.answerCall()
            }
            CallControl.Action.DECLINE -> {
                callStateMonitor.declineCall()
            }
            CallControl.Action.HANG_UP -> {
                callStateMonitor.endCall()
            }
            CallControl.Action.MUTE -> {
                setCallMuted(true)
                Log.i(TAG, "Muted")
            }
            CallControl.Action.UNMUTE -> {
                setCallMuted(false)
                Log.i(TAG, "Unmuted")
            }
            CallControl.Action.DIAL -> {
                dialNumber(control.phoneNumber)
            }
            CallControl.Action.HOLD, CallControl.Action.RESUME -> {
                Log.i(TAG, "Hold/Resume — requires InCallService (future)")
            }
            CallControl.Action.DTMF -> {
                Log.i(TAG, "DTMF: ${control.dtmfDigit}")
                // TODO: Send DTMF tone via InCallService
            }
            else -> Log.w(TAG, "Unknown call control: ${control.action}")
        }
    }

    fun handleAudioFromMac(chunk: CallAudioChunk) {
        callAudioBridge.handleAudioFromMac(chunk)
    }

    private fun setCallMuted(muted: Boolean) {
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            am.isMicrophoneMute = muted
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set mic mute", e)
        }
    }

    private fun dialNumber(number: String) {
        if (number.isEmpty()) return
        val hasCallPermission = ContextCompat.checkSelfPermission(
            context, Manifest.permission.CALL_PHONE
        ) == PackageManager.PERMISSION_GRANTED

        // TelecomManager.placeCall works from the background — launching an
        // ACTION_CALL activity from a service is silently blocked on Android 10+
        // (and aggressively on MIUI), which made Mac-initiated calls do nothing.
        if (hasCallPermission) {
            try {
                val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                telecom.placeCall(Uri.parse("tel:$number"), null)
                Log.i(TAG, "Placing call via TelecomManager: $number")
                return
            } catch (e: Exception) {
                Log.w(TAG, "placeCall failed, falling back to intent", e)
            }
        }

        try {
            val intent = if (hasCallPermission) {
                Intent(Intent.ACTION_CALL, Uri.parse("tel:$number")).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            } else {
                Log.w(TAG, "CALL_PHONE permission not granted, falling back to ACTION_DIAL")
                Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number")).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            context.startActivity(intent)
            Log.i(TAG, "Dialing via intent: $number (direct=${hasCallPermission})")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to dial $number", e)
        }
    }

    companion object {
        private const val TAG = "CallBridge"
        var instance: CallBridge? = null
    }
}
