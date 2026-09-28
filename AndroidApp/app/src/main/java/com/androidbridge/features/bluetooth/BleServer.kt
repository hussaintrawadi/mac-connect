package com.androidbridge.features.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import com.androidbridge.proto.Messages.Envelope
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Bluetooth-LE fallback link. The phone is the BLE peripheral (GATT server) and the
 * Mac is the central. It carries the SAME length-prefixed protobuf Envelope stream
 * the Wi-Fi transport uses, so notifications / SMS / calls work over Bluetooth with
 * no feature-specific code. Big payloads (video, files, photos, audio, icons) are
 * filtered out — BLE can't carry them — so this is a genuine "no Wi-Fi" fallback for
 * the three core functions, not a full replacement.
 *
 * NOTE: needs BLUETOOTH_CONNECT / BLUETOOTH_ADVERTISE (Android 12+) and on-device
 * testing with a paired Mac.
 */
class BleServer(private val context: Context) {

    var onEnvelope: ((Envelope) -> Unit)? = null

    private val btManager get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var txChar: BluetoothGattCharacteristic? = null
    private var central: BluetoothDevice? = null

    @Volatile private var mtuPayload = 20            // default until MTU is negotiated
    private val rxBuffer = ByteArrayOutputStream()
    @Volatile private var expectedLen = -1

    // Notifications must be sent one at a time; queue chunks and drain on ack.
    private val sendQueue = ConcurrentLinkedQueue<ByteArray>()
    private val inFlight = AtomicBoolean(false)

    @Volatile private var running = false
    val isCentralConnected: Boolean get() = central != null

    @SuppressLint("MissingPermission")
    fun start() {
        if (running) return
        val manager = btManager ?: run { Log.w(TAG, "No BluetoothManager"); return }
        val adapter = manager.adapter ?: run { Log.w(TAG, "No BT adapter"); return }
        if (!adapter.isEnabled) { Log.i(TAG, "Bluetooth is off — BLE fallback idle"); return }

        try {
            val server = manager.openGattServer(context, gattCallback) ?: run {
                Log.w(TAG, "openGattServer returned null (permission?)"); return
            }
            gattServer = server

            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val rx = BluetoothGattCharacteristic(
                RX_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            val tx = BluetoothGattCharacteristic(
                TX_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            ).apply {
                addDescriptor(
                    BluetoothGattDescriptor(
                        CCC_UUID,
                        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                    )
                )
            }
            service.addCharacteristic(rx)
            service.addCharacteristic(tx)
            server.addService(service)
            txChar = tx

            startAdvertising(adapter.bluetoothLeAdvertiser)
            running = true
            Log.i(TAG, "BLE fallback server started")
        } catch (e: SecurityException) {
            Log.w(TAG, "BLE start blocked — missing runtime permission", e)
        } catch (e: Exception) {
            Log.e(TAG, "BLE start failed", e)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(adv: BluetoothLeAdvertiser?) {
        advertiser = adv ?: return
        // Balanced/medium keeps this battery-friendly — it's a background fallback,
        // and the Mac scans actively, so we don't need aggressive advertising.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        try {
            advertiser?.startAdvertising(settings, data, advCallback)
        } catch (e: SecurityException) {
            Log.w(TAG, "Advertise blocked — missing permission", e)
        }
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        running = false
        try { advertiser?.stopAdvertising(advCallback) } catch (_: Exception) {}
        try { gattServer?.close() } catch (_: Exception) {}
        advertiser = null
        gattServer = null
        txChar = null
        central = null
        sendQueue.clear()
        inFlight.set(false)
        synchronized(rxBuffer) { rxBuffer.reset(); expectedLen = -1 }
        Log.i(TAG, "BLE fallback server stopped")
    }

    /** Frame + chunk + notify an Envelope over BLE — but only the small, BLE-safe kinds. */
    fun send(envelope: Envelope) {
        if (central == null) return
        val lite = liteForBle(envelope) ?: return
        val body = lite.toByteArray()
        if (body.size > MAX_BLE_MESSAGE) {
            Log.d(TAG, "Skipping ${envelope.payloadCase} over BLE (${body.size} bytes > cap)")
            return
        }
        // 4-byte big-endian length prefix, then split into MTU-sized chunks.
        val framed = ByteArray(4 + body.size)
        framed[0] = (body.size ushr 24).toByte()
        framed[1] = (body.size ushr 16).toByte()
        framed[2] = (body.size ushr 8).toByte()
        framed[3] = body.size.toByte()
        System.arraycopy(body, 0, framed, 4, body.size)

        var off = 0
        while (off < framed.size) {
            val end = minOf(off + mtuPayload, framed.size)
            sendQueue.add(framed.copyOfRange(off, end))
            off = end
        }
        drainQueue()
    }

    @SuppressLint("MissingPermission")
    private fun drainQueue() {
        if (!inFlight.compareAndSet(false, true)) return
        val chunk = sendQueue.poll()
        val dev = central
        val tx = txChar
        val server = gattServer
        if (chunk == null || dev == null || tx == null || server == null) {
            inFlight.set(false)
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                server.notifyCharacteristicChanged(dev, tx, false, chunk)
            } else {
                @Suppress("DEPRECATION")
                tx.value = chunk
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(dev, tx, false)
            }
        } catch (e: Exception) {
            Log.w(TAG, "notify failed", e)
            inFlight.set(false)
        }
    }

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(TAG, "BLE advertising")
        }
        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "BLE advertise failed: $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                central = device
                Log.i(TAG, "BLE central connected")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (device == central) {
                    central = null
                    sendQueue.clear(); inFlight.set(false)
                    synchronized(rxBuffer) { rxBuffer.reset(); expectedLen = -1 }
                    Log.i(TAG, "BLE central disconnected")
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            mtuPayload = (mtu - 3).coerceAtLeast(20)
            Log.i(TAG, "BLE MTU=$mtu (payload=$mtuPayload)")
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (characteristic.uuid == RX_UUID) {
                onIncomingBytes(value)
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (_: Exception) {}
            }
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            // Central subscribed to notifications.
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (_: Exception) {}
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            inFlight.set(false)
            drainQueue()
        }
    }

    /** Reassemble length-prefixed frames from incoming write chunks. */
    private fun onIncomingBytes(bytes: ByteArray) {
        synchronized(rxBuffer) {
            rxBuffer.write(bytes)
            while (true) {
                val buf = rxBuffer.toByteArray()
                if (expectedLen < 0) {
                    if (buf.size < 4) return
                    expectedLen = ((buf[0].toInt() and 0xFF) shl 24) or
                        ((buf[1].toInt() and 0xFF) shl 16) or
                        ((buf[2].toInt() and 0xFF) shl 8) or
                        (buf[3].toInt() and 0xFF)
                    if (expectedLen <= 0 || expectedLen > MAX_BLE_MESSAGE) {
                        Log.w(TAG, "Bad BLE frame length $expectedLen — resetting")
                        rxBuffer.reset(); expectedLen = -1; return
                    }
                }
                if (buf.size < 4 + expectedLen) return
                val body = buf.copyOfRange(4, 4 + expectedLen)
                val rest = buf.copyOfRange(4 + expectedLen, buf.size)
                rxBuffer.reset(); rxBuffer.write(rest); expectedLen = -1
                try {
                    val env = Envelope.parseFrom(body)
                    onEnvelope?.invoke(env)
                } catch (e: Exception) {
                    Log.w(TAG, "Bad BLE envelope", e)
                }
            }
        }
    }

    /** Only forward small message kinds over BLE, stripping heavy binary fields. */
    private fun liteForBle(env: Envelope): Envelope? {
        return when (env.payloadCase) {
            Envelope.PayloadCase.HANDSHAKE_RESPONSE,
            Envelope.PayloadCase.HEARTBEAT,
            Envelope.PayloadCase.DEVICE_INFO,
            Envelope.PayloadCase.ACK,
            Envelope.PayloadCase.SMS_DELIVERY_STATUS,
            Envelope.PayloadCase.SMS_MESSAGE,
            Envelope.PayloadCase.CALL_LOG_LIST -> env

            Envelope.PayloadCase.NOTIFICATION_EVENT ->
                env.toBuilder().setNotificationEvent(
                    env.notificationEvent.toBuilder().clearIconPng().build()
                ).build()

            Envelope.PayloadCase.CALL_EVENT ->
                env.toBuilder().setCallEvent(
                    env.callEvent.toBuilder().clearContactPhoto().build()
                ).build()

            Envelope.PayloadCase.SMS_CONVERSATION ->
                env.toBuilder().setSmsConversation(
                    env.smsConversation.toBuilder().clearContactPhoto().build()
                ).build()

            else -> null   // video, files, gallery, clipboard images, audio: never over BLE
        }
    }

    companion object {
        private const val TAG = "BleServer"
        private const val MAX_BLE_MESSAGE = 24 * 1024   // hard cap for a single BLE envelope

        // Nordic UART Service UUIDs (battle-tested for BLE streaming). Mac uses the same.
        val SERVICE_UUID: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        val RX_UUID: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")  // central → phone
        val TX_UUID: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")  // phone → central
        val CCC_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        var instance: BleServer? = null
    }
}
