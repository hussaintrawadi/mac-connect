package com.androidbridge.features.calls

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import com.androidbridge.proto.Messages.*
import java.util.concurrent.Executor

class CallStateMonitor(private val context: Context) {

    var onCallEvent: ((CallEvent) -> Unit)? = null

    private var telephonyManager: TelephonyManager? = null
    private var currentState = CallEvent.CallState.ENDED
    private var currentNumber: String? = null
    private var callStartTime: Long = 0

    // Strong reference — TelephonyManager may not keep the callback alive itself,
    // and a GC'd callback means incoming calls silently stop reaching the Mac.
    private var telephonyCallback: Any? = null

    fun start() {
        telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        handleCallState(state)
                    }
                }
                telephonyCallback = callback
                telephonyManager?.registerTelephonyCallback(context.mainExecutor, callback)
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        if (!phoneNumber.isNullOrEmpty()) currentNumber = phoneNumber
                        handleCallState(state)
                    }
                }
                telephonyCallback = listener
                @Suppress("DEPRECATION")
                telephonyManager?.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            }
            Log.i(TAG, "Call state monitor started")
        } catch (e: Exception) {
            // Missing READ_PHONE_STATE or OEM restriction — the PHONE_STATE
            // broadcast receiver still covers us.
            Log.e(TAG, "Telephony callback registration failed", e)
        }
    }

    /** Entry point for the manifest PHONE_STATE broadcast receiver — the most
     *  reliable signal on OEM ROMs (MIUI etc.). Deduped against the telephony
     *  callback by the same-state guard in handleCallState. */
    fun handleExternalState(stateExtra: String?, number: String?) {
        val hadNumber = !currentNumber.isNullOrEmpty()
        if (!number.isNullOrEmpty()) currentNumber = number
        val state = when (stateExtra) {
            TelephonyManager.EXTRA_STATE_RINGING -> TelephonyManager.CALL_STATE_RINGING
            TelephonyManager.EXTRA_STATE_OFFHOOK -> TelephonyManager.CALL_STATE_OFFHOOK
            TelephonyManager.EXTRA_STATE_IDLE -> TelephonyManager.CALL_STATE_IDLE
            else -> return
        }
        // PHONE_STATE fires twice (with and without the number). If the first
        // RINGING had no caller ID and this one does, re-send so the Mac HUD
        // can show the contact name.
        if (state == TelephonyManager.CALL_STATE_RINGING &&
            currentState == CallEvent.CallState.RINGING &&
            !hadNumber && !number.isNullOrEmpty()
        ) {
            sendCallEvent(CallEvent.CallState.RINGING, isOutgoing = false)
            return
        }
        handleCallState(state)
    }

    private fun handleCallState(state: Int) {
        val newState = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> CallEvent.CallState.RINGING
            TelephonyManager.CALL_STATE_OFFHOOK -> CallEvent.CallState.ACTIVE
            TelephonyManager.CALL_STATE_IDLE -> CallEvent.CallState.ENDED
            else -> return
        }

        if (newState == currentState) return
        val previousState = currentState
        currentState = newState

        when (newState) {
            CallEvent.CallState.RINGING -> {
                callStartTime = System.currentTimeMillis()
                sendCallEvent(newState, isOutgoing = false)
            }
            CallEvent.CallState.ACTIVE -> {
                if (previousState != CallEvent.CallState.RINGING) {
                    // Outgoing call
                    callStartTime = System.currentTimeMillis()
                    sendCallEvent(newState, isOutgoing = true)
                } else {
                    // Incoming call answered
                    sendCallEvent(newState, isOutgoing = false)
                }
            }
            CallEvent.CallState.ENDED -> {
                sendCallEvent(newState, isOutgoing = false)
                currentNumber = null
                callStartTime = 0
            }
            else -> {}
        }
    }

    private fun sendCallEvent(state: CallEvent.CallState, isOutgoing: Boolean) {
        val number = currentNumber ?: ""
        val contactName = lookupContact(number)

        val event = CallEvent.newBuilder()
            .setState(state)
            .setPhoneNumber(number)
            .setContactName(contactName ?: number)
            .setIsOutgoing(isOutgoing)
            .setStartTimeMs(callStartTime)
            .build()

        Log.i(TAG, "Call event: $state, number=$number, name=$contactName")
        onCallEvent?.invoke(event)
    }

    private fun lookupContact(phoneNumber: String): String? {
        if (phoneNumber.isEmpty()) return null
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(phoneNumber)
        )
        val cursor: Cursor? = context.contentResolver.query(
            uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null
        )
        cursor?.use {
            if (it.moveToFirst()) return it.getString(0)
        }
        return null
    }

    fun answerCall() {
        try {
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                telecomManager.acceptRingingCall()
            }
            Log.i(TAG, "Call answered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to answer call", e)
        }
    }

    fun declineCall() {
        try {
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                telecomManager.endCall()
            }
            Log.i(TAG, "Call declined")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decline call", e)
        }
    }

    fun endCall() {
        declineCall()
    }

    companion object {
        private const val TAG = "CallStateMonitor"
    }
}
