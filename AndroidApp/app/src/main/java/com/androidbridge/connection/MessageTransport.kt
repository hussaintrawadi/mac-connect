package com.androidbridge.connection

import android.util.Log
import com.androidbridge.proto.Messages.*
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicLong

interface MessageHandler {
    fun handleEnvelope(envelope: Envelope)
}

class MessageTransport(private val socket: Socket) {

    var handler: MessageHandler? = null

    private val output: OutputStream = socket.getOutputStream()
    private val input: InputStream = socket.getInputStream()
    private val sequenceCounter = AtomicLong(0)
    private val writeLock = Any()

    // All socket writes happen on this single background thread. Writing on the
    // caller's thread caused NetworkOnMainThreadException (e.g. notifications,
    // UI events) which silently dropped messages. Serializing here also keeps
    // frames ordered for video streaming.
    private val sendExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "MsgTransport-Send").apply { isDaemon = true }
    }

    fun send(envelope: Envelope) {
        try {
            sendExecutor.execute {
                try {
                    sendFramed(envelope.toByteArray())
                } catch (e: Exception) {
                    Log.e(TAG, "Send failed", e)
                }
            }
        } catch (e: RejectedExecutionException) {
            // Executor shut down — connection is closing; drop silently.
        }
    }

    fun sendHeartbeat() {
        val heartbeat = Heartbeat.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .build()
        val envelope = Envelope.newBuilder()
            .setSequence(nextSequence())
            .setTimestampMs(System.currentTimeMillis())
            .setHeartbeat(heartbeat)
            .build()
        send(envelope)
    }

    fun sendHandshakeResponse(accepted: Boolean, deviceId: String, deviceName: String, rejectReason: String = "") {
        val response = HandshakeResponse.newBuilder()
            .setAccepted(accepted)
            .setDeviceId(deviceId)
            .setDeviceName(deviceName)
            .setRejectReason(rejectReason)
            .build()
        val envelope = Envelope.newBuilder()
            .setSequence(nextSequence())
            .setTimestampMs(System.currentTimeMillis())
            .setHandshakeResponse(response)
            .build()
        send(envelope)
    }

    fun sendDeviceInfo(
        deviceName: String,
        osVersion: String,
        batteryLevel: Int,
        batteryCharging: Boolean,
        screenWidth: Int,
        screenHeight: Int,
        screenDensity: Float
    ) {
        val info = DeviceInfo.newBuilder()
            .setDeviceName(deviceName)
            .setOsVersion(osVersion)
            .setBatteryLevel(batteryLevel)
            .setBatteryCharging(batteryCharging)
            .setScreenWidth(screenWidth)
            .setScreenHeight(screenHeight)
            .setScreenDensity(screenDensity)
            .build()
        val envelope = Envelope.newBuilder()
            .setSequence(nextSequence())
            .setTimestampMs(System.currentTimeMillis())
            .setDeviceInfo(info)
            .build()
        send(envelope)
    }

    fun sendAck(forSequence: Long, success: Boolean, error: String = "") {
        val ack = Ack.newBuilder()
            .setSequence(forSequence)
            .setSuccess(success)
            .setError(error)
            .build()
        val envelope = Envelope.newBuilder()
            .setSequence(nextSequence())
            .setTimestampMs(System.currentTimeMillis())
            .setAck(ack)
            .build()
        send(envelope)
    }

    fun receiveLoop() {
        val headerBuf = ByteArray(4)

        while (!socket.isClosed) {
            // Read + parse a frame. A failure HERE means the socket/framing is broken,
            // so we break and let the connection be re-established.
            val envelope: Envelope = try {
                val headerRead = readFully(headerBuf, 4)
                if (!headerRead) break

                val length = ((headerBuf[0].toInt() and 0xFF) shl 24) or
                    ((headerBuf[1].toInt() and 0xFF) shl 16) or
                    ((headerBuf[2].toInt() and 0xFF) shl 8) or
                    (headerBuf[3].toInt() and 0xFF)

                if (length <= 0 || length > MAX_MESSAGE_SIZE) {
                    Log.w(TAG, "Invalid message length: $length")
                    break
                }

                val payload = ByteArray(length)
                val bodyRead = readFully(payload, length)
                if (!bodyRead) break

                Envelope.parseFrom(payload)
            } catch (e: Exception) {
                Log.e(TAG, "Receive/parse error — closing connection", e)
                break
            }

            // Dispatch to the handler. A failure HERE is a feature bug, NOT a transport
            // failure — it must never tear down the connection (that caused the reconnect loop).
            try {
                Log.d(TAG, "Received message seq=${envelope.sequence}")
                handler?.handleEnvelope(envelope)
            } catch (e: Exception) {
                Log.e(TAG, "Handler error for ${envelope.payloadCase} — continuing", e)
            }
        }
    }

    private fun sendFramed(data: ByteArray) {
        synchronized(writeLock) {
            try {
                val header = ByteArray(4)
                header[0] = (data.size shr 24 and 0xFF).toByte()
                header[1] = (data.size shr 16 and 0xFF).toByte()
                header[2] = (data.size shr 8 and 0xFF).toByte()
                header[3] = (data.size and 0xFF).toByte()
                output.write(header)
                output.write(data)
                output.flush()
            } catch (e: Exception) {
                Log.e(TAG, "Send error", e)
            }
        }
    }

    private fun readFully(buf: ByteArray, length: Int): Boolean {
        var offset = 0
        while (offset < length) {
            val read = input.read(buf, offset, length - offset)
            if (read == -1) return false
            offset += read
        }
        return true
    }

    private fun nextSequence(): Long {
        return sequenceCounter.incrementAndGet()
    }

    fun close() {
        try { sendExecutor.shutdownNow() } catch (_: Exception) {}
        try { socket.close() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "MessageTransport"
        private const val MAX_MESSAGE_SIZE = 10 * 1024 * 1024
    }
}
