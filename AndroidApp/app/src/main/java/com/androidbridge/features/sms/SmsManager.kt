package com.androidbridge.features.sms

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager as SystemSmsManager
import android.util.Log
import com.androidbridge.proto.Messages
import com.androidbridge.proto.Messages.Envelope
import com.androidbridge.proto.Messages.SmsConversation
import com.androidbridge.proto.Messages.SmsDeliveryStatus
import com.androidbridge.proto.Messages.SmsMessage as ProtoSmsMessage
import com.google.protobuf.ByteString
import java.util.UUID

class SmsBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    private var observer: ContentObserver? = null
    private var lastSeenId: Long = -1L

    /**
     * Watches the SMS database for ANY new message — incoming, your own replies
     * sent from the phone, and bulk/marketing messages — and forwards each to the
     * Mac in real time with the contact name resolved. More reliable than the
     * SMS_RECEIVED broadcast (which misses outgoing and is flaky on some OEMs).
     */
    fun startObserving() {
        if (observer != null) return
        lastSeenId = queryMaxSmsId()
        val obs = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                forwardNewMessages()
            }
        }
        try {
            context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, obs)
            observer = obs
            Log.i(TAG, "SMS observer started (lastId=$lastSeenId)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register SMS observer", e)
        }
    }

    fun stopObserving() {
        observer?.let {
            try { context.contentResolver.unregisterContentObserver(it) } catch (_: Exception) {}
        }
        observer = null
    }

    private fun queryMaxSmsId(): Long {
        val c = context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID),
            null, null,
            "${Telephony.Sms._ID} DESC LIMIT 1"
        )
        c?.use { if (it.moveToFirst()) return it.getLong(0) }
        return -1L
    }

    private fun forwardNewMessages() {
        val cursor = context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ
            ),
            "${Telephony.Sms._ID} > ?",
            arrayOf(lastSeenId.toString()),
            "${Telephony.Sms._ID} ASC"
        ) ?: return

        cursor.use {
            while (it.moveToNext()) {
                val id = it.getLong(0)
                lastSeenId = maxOf(lastSeenId, id)
                val type = it.getInt(5)
                // Only forward real inbox / sent messages (skip drafts, outbox, failed).
                if (type != Telephony.Sms.MESSAGE_TYPE_INBOX && type != Telephony.Sms.MESSAGE_TYPE_SENT) continue

                val threadId = it.getString(1) ?: ""
                val address = it.getString(2) ?: ""
                val body = it.getString(3) ?: ""
                val date = it.getLong(4)
                val read = it.getInt(6)
                val isOutgoing = type == Telephony.Sms.MESSAGE_TYPE_SENT
                val contactName = lookupContactName(address) ?: address

                val msg = ProtoSmsMessage.newBuilder()
                    .setMessageId(id.toString())
                    .setThreadId(threadId)
                    .setSender(address)
                    .setBody(body)
                    .setTimestampMs(date)
                    .setIsOutgoing(isOutgoing)
                    .setIsRead(read == 1)
                    .setIsMms(false)
                    .setContactName(contactName)
                    .build()

                val envelope = Envelope.newBuilder()
                    .setTimestampMs(System.currentTimeMillis())
                    .setSmsMessage(msg)
                    .build()
                onSendEnvelope?.invoke(envelope)
                Log.d(TAG, "SMS forwarded id=$id outgoing=$isOutgoing from=$contactName")
            }
        }
    }

    fun loadRecentConversations(limit: Int = 50): List<SmsConversation> {
        val conversations = mutableListOf<SmsConversation>()
        val resolver = context.contentResolver

        val cursor = resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
                Telephony.Sms.READ,
                Telephony.Sms._ID
            ),
            null, null,
            "${Telephony.Sms.DATE} DESC"
        ) ?: return conversations

        val seenThreads = mutableSetOf<String>()

        cursor.use {
            while (it.moveToNext() && seenThreads.size < limit) {
                val threadId = it.getString(0) ?: continue
                if (threadId in seenThreads) continue
                seenThreads.add(threadId)

                val address = it.getString(1) ?: ""
                val body = it.getString(2) ?: ""
                val date = it.getLong(3)
                val type = it.getInt(4)
                val read = it.getInt(5)

                val contactName = lookupContactName(address)
                val unreadCount = countUnread(resolver, threadId)

                val conv = SmsConversation.newBuilder()
                    .setThreadId(threadId)
                    .setContactName(contactName ?: address)
                    .setContactNumber(address)
                    .setLastMessage(body)
                    .setLastTimestampMs(date)
                    .setUnreadCount(unreadCount)
                    // Include recent messages so the Mac can show the chat thread
                    // immediately (previously the thread view was blank).
                    .addAllMessages(loadThreadMessages(threadId, 50))
                    .build()

                conversations.add(conv)
            }
        }

        Log.i(TAG, "Loaded ${conversations.size} conversations")
        return conversations
    }

    fun loadThreadMessages(threadId: String, limit: Int = 100): List<ProtoSmsMessage> {
        val messages = mutableListOf<ProtoSmsMessage>()
        val resolver = context.contentResolver

        val cursor = resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms._ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
                Telephony.Sms.READ
            ),
            "${Telephony.Sms.THREAD_ID} = ?",
            arrayOf(threadId),
            "${Telephony.Sms.DATE} DESC LIMIT $limit"
        ) ?: return messages

        cursor.use {
            while (it.moveToNext()) {
                val id = it.getString(0) ?: ""
                val address = it.getString(1) ?: ""
                val body = it.getString(2) ?: ""
                val date = it.getLong(3)
                val type = it.getInt(4)
                val read = it.getInt(5)

                val msg = ProtoSmsMessage.newBuilder()
                    .setMessageId(id)
                    .setThreadId(threadId)
                    .setSender(address)
                    .setBody(body)
                    .setTimestampMs(date)
                    .setIsOutgoing(type == Telephony.Sms.MESSAGE_TYPE_SENT)
                    .setIsRead(read == 1)
                    .setIsMms(false)
                    .build()

                messages.add(msg)
            }
        }

        return messages.reversed()
    }

    fun sendSms(recipient: String, body: String, requestId: String) {
        try {
            val smsManager = context.getSystemService(SystemSmsManager::class.java)
            val parts = smsManager.divideMessage(body)

            if (parts.size == 1) {
                smsManager.sendTextMessage(recipient, null, body, null, null)
            } else {
                smsManager.sendMultipartTextMessage(recipient, null, parts, null, null)
            }

            Log.i(TAG, "SMS sent to $recipient")

            val status = SmsDeliveryStatus.newBuilder()
                .setRequestId(requestId)
                .setDelivered(true)
                .build()
            val envelope = Envelope.newBuilder()
                .setTimestampMs(System.currentTimeMillis())
                .setSmsDeliveryStatus(status)
                .build()
            onSendEnvelope?.invoke(envelope)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send SMS", e)

            val status = SmsDeliveryStatus.newBuilder()
                .setRequestId(requestId)
                .setDelivered(false)
                .setError(e.message ?: "Send failed")
                .build()
            val envelope = Envelope.newBuilder()
                .setTimestampMs(System.currentTimeMillis())
                .setSmsDeliveryStatus(status)
                .build()
            onSendEnvelope?.invoke(envelope)
        }
    }

    fun forwardIncomingSms(sender: String, body: String, timestamp: Long) {
        // Resolve the thread id so the Mac files this into the correct conversation.
        val threadId = try {
            Telephony.Threads.getOrCreateThreadId(context, sender).toString()
        } catch (e: Exception) {
            ""
        }

        val msg = ProtoSmsMessage.newBuilder()
            .setMessageId(UUID.randomUUID().toString())
            .setThreadId(threadId)
            .setSender(sender)
            .setBody(body)
            .setTimestampMs(timestamp)
            .setIsOutgoing(false)
            .setIsRead(false)
            .setIsMms(false)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setSmsMessage(msg)
            .build()
        onSendEnvelope?.invoke(envelope)
        Log.d(TAG, "Forwarded incoming SMS from $sender (thread $threadId)")
    }

    fun sendConversationsToMac() {
        val conversations = loadRecentConversations()
        for (conv in conversations) {
            val envelope = Envelope.newBuilder()
                .setTimestampMs(System.currentTimeMillis())
                .setSmsConversation(conv)
                .build()
            onSendEnvelope?.invoke(envelope)
        }
    }

    private fun lookupContactName(phoneNumber: String): String? {
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(phoneNumber)
        )
        val cursor = context.contentResolver.query(
            uri,
            arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
            null, null, null
        )

        cursor?.use {
            if (it.moveToFirst()) {
                return it.getString(0)
            }
        }
        return null
    }

    private fun countUnread(resolver: ContentResolver, threadId: String): Int {
        val cursor = resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf("COUNT(*)"),
            "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0 AND ${Telephony.Sms.TYPE} = ${Telephony.Sms.MESSAGE_TYPE_INBOX}",
            arrayOf(threadId),
            null
        )
        cursor?.use {
            if (it.moveToFirst()) return it.getInt(0)
        }
        return 0
    }

    companion object {
        private const val TAG = "SmsBridge"
        var instance: SmsBridge? = null
    }
}
