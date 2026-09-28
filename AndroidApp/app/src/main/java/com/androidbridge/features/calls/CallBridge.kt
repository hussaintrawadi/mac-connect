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

        // NOTE: Call audio stays on the phone (earpiece / speaker / Bluetooth
        // such as AirPods). We deliberately do NOT bridge call audio to the Mac:
        // running the Mac mic->phone and phone->Mac paths alongside the real call
        // created an acoustic feedback loop (your own voice echoing back seconds
        // later). The Mac is call CONTROL only — answer, mute, hang up, keypad.
        // Routing live cellular call audio off a non-system app isn't reliable
        // on Android anyway. (Audio bridge intentionally disabled.)
        isInCall = (event.state == CallEvent.CallState.ACTIVE)
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
        // Audio bridge disabled (see handleCallStateChange) — drop Mac mic audio
        // so it can't be injected into the call and loop back as echo.
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
