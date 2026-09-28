package com.androidbridge.connection

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import com.androidbridge.features.clipboard.ClipboardBridge
import com.androidbridge.features.calls.CallBridge
import com.androidbridge.features.filesystem.FileSystemBridge
import com.androidbridge.features.gallery.GalleryBridge
import com.androidbridge.features.macsystem.MacBridge
import com.androidbridge.features.mediacontrol.MediaControlBridge
import com.androidbridge.features.notifications.NotificationBridge
import com.androidbridge.features.screenmirror.ScreenMirrorBridge
import com.androidbridge.features.sms.SmsBridge
import com.androidbridge.features.urlhandoff.UrlHandoffBridge
import com.androidbridge.proto.Messages.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.ServerSocket

class ConnectionManager(private val context: Context) : MessageHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private var serverSocket: ServerSocket? = null
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    private val pairingStore = PairingStore(context)
    private val rateLimiter = RateLimiter()

    private var activeTransport: MessageTransport? = null
    private var heartbeatJob: kotlinx.coroutines.Job? = null
    private var missedHeartbeats = 0
    @Volatile private var serverRunning = false

    // Invoked when the Mac asks the phone to disconnect (to save battery).
    var onDisconnectRequested: (() -> Unit)? = null

    // Feature bridges
    val notificationBridge = NotificationBridge()
    val smsBridge = SmsBridge(context)
    val clipboardBridge = ClipboardBridge(context)
    val urlHandoffBridge = UrlHandoffBridge(context)
    val fileSystemBridge = FileSystemBridge(context)
    val galleryBridge = GalleryBridge(context)
    val screenMirrorBridge = ScreenMirrorBridge(context)
    val callBridge = CallBridge(context)
    val mediaControlBridge = MediaControlBridge(context)

    // Bluetooth-LE fallback link (works when there's no Wi-Fi). Carries the same
    // Envelope stream, filtered to the small kinds (notifications / SMS / calls).
    val bleServer = com.androidbridge.features.bluetooth.BleServer(context)

    init {
        val sendFn: (Envelope) -> Unit = { envelope -> sendEnvelope(envelope) }
        notificationBridge.onSendEnvelope = sendFn
        smsBridge.onSendEnvelope = sendFn
        clipboardBridge.onSendEnvelope = sendFn
        urlHandoffBridge.onSendEnvelope = sendFn
        fileSystemBridge.onSendEnvelope = sendFn
        galleryBridge.onSendEnvelope = sendFn
        screenMirrorBridge.onSendEnvelope = sendFn
        callBridge.onSendEnvelope = sendFn
        mediaControlBridge.onSendEnvelope = sendFn

        // Let the UI send Mac control commands (lock / find) through the active link.
        MacBridge.onSendControl = { action ->
            val env = Envelope.newBuilder()
                .setTimestampMs(System.currentTimeMillis())
                .setMacControl(MacControl.newBuilder().setAction(action).build())
                .build()
            sendEnvelope(env)
        }
        MacBridge.onSendControlValue = { action, value ->
            val env = Envelope.newBuilder()
                .setTimestampMs(System.currentTimeMillis())
                .setMacControl(MacControl.newBuilder().setAction(action).setValue(value).build())
                .build()
            sendEnvelope(env)
        }
        MacBridge.onSendMediaControl = { action ->
            val env = Envelope.newBuilder()
                .setTimestampMs(System.currentTimeMillis())
                .setMacMediaControl(MacMediaControl.newBuilder().setAction(action).build())
                .build()
            sendEnvelope(env)
        }

        NotificationBridge.instance = notificationBridge
        SmsBridge.instance = smsBridge
        ClipboardBridge.instance = clipboardBridge
        UrlHandoffBridge.instance = urlHandoffBridge
        FileSystemBridge.instance = fileSystemBridge
        GalleryBridge.instance = galleryBridge
        ScreenMirrorBridge.instance = screenMirrorBridge
        CallBridge.instance = callBridge
        MediaControlBridge.instance = mediaControlBridge

        // BLE-received envelopes go through the exact same handler as Wi-Fi ones.
        bleServer.onEnvelope = { env -> handleEnvelope(env) }
        com.androidbridge.features.bluetooth.BleServer.instance = bleServer
    }

    // MARK: - Lifecycle

    fun start() {
        Log.i(TAG, "ConnectionManager starting")

        if (!pairingStore.hasPairedDevice()) {
            Log.i(TAG, "No paired device — waiting for pairing")
            _state.value = ConnectionState.Disconnected
            return
        }

        if (serverRunning) {
            Log.i(TAG, "Server already running — ignoring duplicate start")
            return
        }
        serverRunning = true
        watchNetworkChanges()

        // Bring up the Bluetooth fallback alongside Wi-Fi (unless the user turned it off).
        if (context.getSharedPreferences("androidbridge", Context.MODE_PRIVATE)
                .getBoolean("bluetooth_enabled", true)) {
            try { bleServer.start() } catch (e: Exception) { Log.w(TAG, "BLE start failed", e) }
        }

        scope.launch {
            startServer()
        }
    }

    // Re-advertise over mDNS whenever Wi-Fi comes (back) — so phone and Mac
    // re-link automatically when they land on the same network, like Bluetooth.
    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null

    private fun watchNetworkChanges() {
        if (networkCallback != null) return
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            val request = android.net.NetworkRequest.Builder()
                .addTransportType(android.net.NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            val callback = object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    Log.i(TAG, "Wi-Fi available — re-registering mDNS advertisement")
                    scope.launch {
                        kotlinx.coroutines.delay(1500)  // let the IP settle
                        val port = serverSocket?.localPort ?: return@launch
                        unregisterNsd()
                        registerNsd(port)
                    }
                }
            }
            cm.registerNetworkCallback(request, callback)
            networkCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "Network watch failed", e)
        }
    }

    fun stop() {
        Log.i(TAG, "ConnectionManager stopping")
        serverRunning = false
        unregisterNsd()
        serverSocket?.close()
        serverSocket = null
        heartbeatJob?.cancel()
        activeTransport?.close()
        activeTransport = null
        try { bleServer.stop() } catch (_: Exception) {}
        scope.cancel()
        _state.value = ConnectionState.Disconnected
    }

    // Expose the screen-mirror bridge for the service to start/stop projection
    fun startMirroring(resultCode: Int, data: android.content.Intent) {
        screenMirrorBridge.startMirroring(resultCode, data)
    }

    fun stopMirroring() {
        screenMirrorBridge.stopMirroring()
    }

    // MARK: - Server

    private suspend fun startServer() {
        try {
            val port = derivePort(pairingStore.getPairedDeviceId() ?: "default")
            serverSocket = ServerSocket(port)
            Log.i(TAG, "Server listening on port $port")

            _state.value = ConnectionState.Searching
            registerNsd(port)
            acceptConnections()
        } catch (e: IOException) {
            Log.e(TAG, "Failed to start server", e)
            delay(5000)
            startServer()
        }
    }

    private suspend fun acceptConnections() {
        while (true) {
            try {
                val clientSocket = serverSocket?.accept() ?: break
                val clientAddr = clientSocket.inetAddress.hostAddress ?: "unknown"
                Log.i(TAG, "Incoming connection from $clientAddr")

                if (rateLimiter.isBlocked(clientAddr)) {
                    Log.w(TAG, "Rate-limited: $clientAddr")
                    clientSocket.close()
                    continue
                }

                scope.launch {
                    handleConnection(clientSocket)
                }
            } catch (e: IOException) {
                if (serverSocket?.isClosed == true) break
                Log.e(TAG, "Accept error", e)
            }
        }
    }

    private suspend fun handleConnection(socket: java.net.Socket) {
        val addr = socket.inetAddress.hostAddress ?: "unknown"

        // Close any pre-existing connection so we never have two live transports
        activeTransport?.let { old ->
            Log.i(TAG, "Replacing existing transport with new connection from $addr")
            try { old.close() } catch (_: Exception) {}
        }

        try {
            val transport = MessageTransport(socket)
            transport.handler = this
            activeTransport = transport

            _state.value = ConnectionState.Connected(deviceName = "Mac")
            Log.i(TAG, "Connection established with $addr")
            rateLimiter.recordSuccess(addr)

            // On Wi-Fi now — stop BLE advertising to save battery/radio. It resumes
            // automatically when this Wi-Fi connection drops (the fallback).
            try { bleServer.stop() } catch (_: Exception) {}

            startHeartbeat(transport)

            // IMPORTANT: clipboard / call / media listeners must be registered on the
            // main thread (they create Handlers / need a Looper). Registering them on
            // this IO coroutine thread throws and used to kill the connection, causing
            // the endless reconnect loop. Run on Main and guard each one individually.
            startFeatureMonitors()

            // Send initial data to Mac
            scope.launch {
                try { smsBridge.sendConversationsToMac() } catch (e: Exception) { Log.w(TAG, "SMS send failed", e) }
            }
            scope.launch {
                try { sendContacts() } catch (e: Exception) { Log.w(TAG, "Contacts send failed", e) }
            }

            // Blocking — runs until connection drops
            transport.receiveLoop()

            // Connection ended
            if (activeTransport === transport) {
                activeTransport = null
                _state.value = ConnectionState.Searching
                MacBridge.clear()   // status dot reflects the drop in real time
                resumeBleFallback() // Wi-Fi gone — bring Bluetooth back up
            }
            Log.i(TAG, "Connection closed — waiting for reconnect")
        } catch (e: Exception) {
            Log.e(TAG, "Connection error with $addr", e)
            rateLimiter.recordFailure(addr)
            try { socket.close() } catch (_: Exception) {}
            activeTransport = null
            _state.value = ConnectionState.Searching
            MacBridge.clear()
            resumeBleFallback()
        }
    }

    /// Start BLE advertising again (the Bluetooth fallback) when Wi-Fi isn't carrying
    /// the connection, so the Mac can still reach us for notifications/calls/SMS.
    private fun resumeBleFallback() {
        if (context.getSharedPreferences("androidbridge", Context.MODE_PRIVATE)
                .getBoolean("bluetooth_enabled", true)) {
            try { bleServer.start() } catch (e: Exception) { Log.w(TAG, "BLE resume failed", e) }
        }
    }

    private suspend fun startFeatureMonitors() {
        withContext(Dispatchers.Main) {
            try { clipboardBridge.startMonitoring() } catch (e: Exception) { Log.w(TAG, "Clipboard monitor failed", e) }
            try { callBridge.start() } catch (e: Exception) { Log.w(TAG, "Call bridge start failed", e) }
            try { mediaControlBridge.start() } catch (e: Exception) { Log.w(TAG, "Media bridge start failed", e) }
            try { smsBridge.startObserving() } catch (e: Exception) { Log.w(TAG, "SMS observer failed", e) }
        }
    }

    // MARK: - MessageHandler

    override fun handleEnvelope(envelope: Envelope) {
        when (envelope.payloadCase) {
            Envelope.PayloadCase.HEARTBEAT -> {
                missedHeartbeats = 0
                Log.d(TAG, "Heartbeat received")
                activeTransport?.sendHeartbeat()
                if (bleServer.isCentralConnected) {
                    bleServer.send(
                        Envelope.newBuilder()
                            .setTimestampMs(System.currentTimeMillis())
                            .setHeartbeat(Heartbeat.newBuilder().setTimestampMs(System.currentTimeMillis()).build())
                            .build()
                    )
                }
            }

            Envelope.PayloadCase.HANDSHAKE -> {
                val handshake = envelope.handshake
                Log.i(TAG, "Handshake from ${handshake.deviceName} (${handshake.deviceId.take(8)})")

                // TODO: Verify against paired device certificate

                activeTransport?.sendHandshakeResponse(
                    accepted = true,
                    deviceId = pairingStore.getDeviceId(),
                    deviceName = "${Build.MANUFACTURER} ${Build.MODEL}"
                )
                if (bleServer.isCentralConnected) {
                    bleServer.send(
                        Envelope.newBuilder()
                            .setTimestampMs(System.currentTimeMillis())
                            .setHandshakeResponse(
                                HandshakeResponse.newBuilder()
                                    .setAccepted(true)
                                    .setDeviceId(pairingStore.getDeviceId())
                                    .setDeviceName("${Build.MANUFACTURER} ${Build.MODEL}")
                                    .build()
                            ).build()
                    )
                }

                sendDeviceInfo()
            }

            Envelope.PayloadCase.NOTIFICATION_ACTION -> {
                val action = envelope.notificationAction
                Log.i(TAG, "Notification action: ${action.action} for ${action.notificationId}")
                notificationBridge.handleNotificationAction(action)
            }

            Envelope.PayloadCase.SMS_SEND -> {
                val sms = envelope.smsSend
                Log.i(TAG, "SMS send request to ${sms.recipient}")
                scope.launch {
                    smsBridge.sendSms(sms.recipient, sms.body, sms.requestId)
                }
            }

            Envelope.PayloadCase.CLIPBOARD_SYNC -> {
                val clip = envelope.clipboardSync
                Log.i(TAG, "Clipboard sync from Mac")
                clipboardBridge.applyFromMac(clip)
            }

            Envelope.PayloadCase.URL_HANDOFF -> {
                val handoff = envelope.urlHandoff
                Log.i(TAG, "URL handoff: ${handoff.url}")
                urlHandoffBridge.openUrlFromMac(handoff)
            }

            Envelope.PayloadCase.FILE_LIST_REQUEST -> {
                val req = envelope.fileListRequest
                Log.i(TAG, "File list request: ${req.path}")
                fileSystemBridge.handleListRequest(req)
            }

            Envelope.PayloadCase.FILE_DOWNLOAD_REQUEST -> {
                val req = envelope.fileDownloadRequest
                Log.i(TAG, "File download request: ${req.path}")
                fileSystemBridge.handleDownloadRequest(req)
            }

            Envelope.PayloadCase.FILE_UPLOAD_REQUEST -> {
                val req = envelope.fileUploadRequest
                Log.i(TAG, "File upload request: ${req.fileName}")
                fileSystemBridge.handleUploadRequest(req)
            }

            Envelope.PayloadCase.FILE_CHUNK -> {
                fileSystemBridge.handleFileChunk(envelope.fileChunk)
            }

            Envelope.PayloadCase.GALLERY_REQUEST -> {
                Log.i(TAG, "Gallery request: offset=${envelope.galleryRequest.offset}")
                galleryBridge.handleRequest(envelope.galleryRequest)
            }

            Envelope.PayloadCase.GALLERY_ALBUMS_REQUEST -> {
                Log.i(TAG, "Gallery albums request")
                galleryBridge.handleAlbumsRequest()
            }

            Envelope.PayloadCase.CONNECTION_CONTROL -> {
                when (envelope.connectionControl.action) {
                    ConnectionControl.Action.START_MIRROR -> {
                        Log.i(TAG, "Mac requested mirror start")
                        if (com.androidbridge.features.screenmirror.ScreenCapture.instance?.isCapturing == true) {
                            Log.i(TAG, "Mirror already running — ignoring")
                        } else {
                            // Open the app on the consent flow; one tap on the
                            // phone and frames start (Android requires the tap).
                            val intent = android.content.Intent(
                                context, com.androidbridge.ui.MainActivity::class.java
                            ).apply {
                                action = "com.androidbridge.REQUEST_MIRROR"
                                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                                         android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            }
                            try { context.startActivity(intent) } catch (e: Exception) {
                                Log.w(TAG, "Could not open mirror consent", e)
                            }
                        }
                    }
                    ConnectionControl.Action.STOP_MIRROR -> {
                        Log.i(TAG, "Mac closed the mirror — stopping capture so the phone can sleep")
                        val intent = android.content.Intent(context, com.androidbridge.service.ConnectionService::class.java).apply {
                            action = com.androidbridge.service.ConnectionService.ACTION_STOP_MIRROR
                        }
                        try { androidx.core.content.ContextCompat.startForegroundService(context, intent) } catch (_: Exception) {
                            stopMirroring()
                        }
                    }
                    else -> {
                        Log.i(TAG, "Mac requested disconnect — stopping service")
                        onDisconnectRequested?.invoke()
                    }
                }
            }

            Envelope.PayloadCase.FIND_DEVICE -> {
                if (envelope.findDevice.start) {
                    Log.i(TAG, "Find My Phone — ringing")
                    com.androidbridge.features.findphone.FindPhoneAlarm.start(context)
                } else {
                    Log.i(TAG, "Find My Phone — stop")
                    com.androidbridge.features.findphone.FindPhoneAlarm.stop()
                }
            }

            Envelope.PayloadCase.MAC_STATUS -> {
                val s = envelope.macStatus
                MacBridge.batteryLevel = s.batteryLevel
                MacBridge.isCharging = s.isCharging
                MacBridge.deviceName = s.deviceName
                MacBridge.volume = s.volume
                MacBridge.muted = s.muted
                MacBridge.wifiOn = s.wifiOn
                MacBridge.brightness = s.brightness
                MacBridge.bluetoothOn = s.bluetoothOn
                MacBridge.hasData = true
            }

            Envelope.PayloadCase.MAC_MEDIA_STATE -> {
                val m = envelope.macMediaState
                MacBridge.mediaHasMedia = m.hasMedia
                MacBridge.mediaTitle = m.title
                MacBridge.mediaArtist = m.artist
                MacBridge.mediaIsPlaying = m.isPlaying
            }

            Envelope.PayloadCase.FILE_TRANSFER_CANCEL -> {
                fileSystemBridge.handleTransferCancel(envelope.fileTransferCancel)
            }

            Envelope.PayloadCase.FILE_OPERATION -> {
                fileSystemBridge.handleFileOperation(envelope.fileOperation)
            }

            Envelope.PayloadCase.TOUCH_EVENT -> {
                val touch = envelope.touchEvent
                Log.d(TAG, "Touch: ${touch.action} at (${touch.x}, ${touch.y})")
                screenMirrorBridge.handleTouchEvent(touch)
            }

            Envelope.PayloadCase.KEY_EVENT -> {
                val key = envelope.keyEvent
                Log.d(TAG, "Key event: ${key.text}")
                screenMirrorBridge.handleKeyEvent(key)
            }

            Envelope.PayloadCase.SCROLL_EVENT -> {
                val scroll = envelope.scrollEvent
                screenMirrorBridge.handleScrollEvent(scroll)
            }

            Envelope.PayloadCase.CALL_CONTROL -> {
                val call = envelope.callControl
                Log.i(TAG, "Call control: ${call.action}")
                callBridge.handleCallControl(call)
            }

            Envelope.PayloadCase.CALL_AUDIO_CHUNK -> {
                callBridge.handleAudioFromMac(envelope.callAudioChunk)
            }

            Envelope.PayloadCase.MEDIA_CONTROL -> {
                val media = envelope.mediaControl
                Log.i(TAG, "Media control: ${media.action}")
                mediaControlBridge.handleMediaControl(media)
            }

            Envelope.PayloadCase.CONTACT_REQUEST -> {
                Log.i(TAG, "Contact request from Mac")
                scope.launch {
                    sendContacts()
                    sendCallLog()
                }
            }

            Envelope.PayloadCase.CALL_LOG_REQUEST -> {
                Log.i(TAG, "Call-log request from Mac")
                scope.launch { sendCallLog() }
            }

            Envelope.PayloadCase.ACK -> {
                val ack = envelope.ack
                Log.d(TAG, "ACK for seq ${ack.sequence}: success=${ack.success}")
            }

            else -> {
                Log.d(TAG, "Unhandled message type: ${envelope.payloadCase}")
            }
        }
    }

    // MARK: - Send Convenience

    fun sendEnvelope(envelope: Envelope) {
        activeTransport?.send(envelope)
        // Also mirror over the Bluetooth fallback when a Mac is linked via BLE.
        if (bleServer.isCentralConnected) bleServer.send(envelope)
    }

    private fun sendDeviceInfo() {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)

        val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val batteryLevel = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val isCharging = batteryManager.isCharging

        activeTransport?.sendDeviceInfo(
            deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
            osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            batteryLevel = batteryLevel,
            batteryCharging = isCharging,
            screenWidth = metrics.widthPixels,
            screenHeight = metrics.heightPixels,
            screenDensity = metrics.density
        )
        if (bleServer.isCentralConnected) {
            bleServer.send(
                Envelope.newBuilder()
                    .setTimestampMs(System.currentTimeMillis())
                    .setDeviceInfo(
                        DeviceInfo.newBuilder()
                            .setDeviceName("${Build.MANUFACTURER} ${Build.MODEL}")
                            .setOsVersion("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
                            .setBatteryLevel(batteryLevel)
                            .setBatteryCharging(isCharging)
                            .setScreenWidth(metrics.widthPixels)
                            .setScreenHeight(metrics.heightPixels)
                            .setScreenDensity(metrics.density)
                            .build()
                    ).build()
            )
        }
    }

    private fun sendContacts() {
        val resolver = context.contentResolver
        val contacts = mutableListOf<Contact>()

        val cursor = resolver.query(
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
            ),
            null, null,
            "${android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
        )

        cursor?.use {
            val seenNumbers = mutableSetOf<String>()
            while (it.moveToNext()) {
                val name = it.getString(0) ?: continue
                val number = it.getString(1)?.replace("[\\s\\-()]".toRegex(), "") ?: continue
                if (number in seenNumbers) continue
                seenNumbers.add(number)

                contacts.add(
                    Contact.newBuilder()
                        .setName(name)
                        .addPhoneNumbers(number)
                        .build()
                )
            }
        }

        val contactList = ContactList.newBuilder()
            .addAllContacts(contacts)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setContactList(contactList)
            .build()

        sendEnvelope(envelope)
        Log.i(TAG, "Sent ${contacts.size} contacts to Mac")
    }

    private fun sendCallLog() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.READ_CALL_LOG
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "READ_CALL_LOG not granted — skipping call log")
            return
        }

        val resolver = context.contentResolver
        val entries = mutableListOf<CallLogEntry>()
        val projection = arrayOf(
            android.provider.CallLog.Calls.NUMBER,
            android.provider.CallLog.Calls.CACHED_NAME,
            android.provider.CallLog.Calls.TYPE,
            android.provider.CallLog.Calls.DATE,
            android.provider.CallLog.Calls.DURATION
        )
        val cursor = resolver.query(
            android.provider.CallLog.Calls.CONTENT_URI,
            projection, null, null,
            "${android.provider.CallLog.Calls.DATE} DESC LIMIT 100"
        )

        cursor?.use {
            val numCol = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.NUMBER)
            val nameCol = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.CACHED_NAME)
            val typeCol = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.TYPE)
            val dateCol = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.DATE)
            val durCol = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.DURATION)
            while (it.moveToNext()) {
                val type = when (it.getInt(typeCol)) {
                    android.provider.CallLog.Calls.INCOMING_TYPE -> 1
                    android.provider.CallLog.Calls.OUTGOING_TYPE -> 2
                    android.provider.CallLog.Calls.MISSED_TYPE -> 3
                    else -> 0
                }
                entries.add(
                    CallLogEntry.newBuilder()
                        .setNumber(it.getString(numCol) ?: "")
                        .setName(it.getString(nameCol) ?: "")
                        .setType(type)
                        .setDateMs(it.getLong(dateCol))
                        .setDurationS(it.getInt(durCol))
                        .build()
                )
            }
        }

        val list = CallLogList.newBuilder().addAllEntries(entries).build()
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setCallLogList(list)
            .build()
        sendEnvelope(envelope)
        Log.i(TAG, "Sent ${entries.size} call-log entries to Mac")
    }

    // MARK: - Heartbeat

    private fun startHeartbeat(transport: MessageTransport) {
        heartbeatJob?.cancel()
        missedHeartbeats = 0

        heartbeatJob = scope.launch {
            var beats = 0
            while (true) {
                delay(5000)

                if (missedHeartbeats >= 3) {
                    Log.w(TAG, "Missed 3 heartbeats — dropping connection")
                    break
                }

                missedHeartbeats++
                transport.sendHeartbeat()

                // Refresh device info (battery %) on the Mac every 30s.
                beats++
                if (beats % 6 == 0) sendDeviceInfo()
            }
        }
    }

    // MARK: - mDNS / NSD

    private fun registerNsd(port: Int) {
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "ab-${pairingStore.getDeviceId().take(8)}"
            serviceType = "_androidbridge._tcp"
            setPort(port)
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD service registered: ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD registration failed: $errorCode")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD service unregistered")
            }
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD unregistration failed: $errorCode")
            }
        }

        nsdManager = (context.getSystemService(Context.NSD_SERVICE) as NsdManager).also {
            it.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        }
        registrationListener = listener
    }

    private fun unregisterNsd() {
        registrationListener?.let { listener ->
            try {
                nsdManager?.unregisterService(listener)
            } catch (e: Exception) {
                Log.w(TAG, "NSD unregister error", e)
            }
        }
        registrationListener = null
        nsdManager = null
    }

    // MARK: - Helpers

    private fun derivePort(deviceId: String): Int {
        val hash = deviceId.hashCode() and 0x7FFFFFFF
        return 10000 + (hash % 50000)
    }

    companion object {
        private const val TAG = "ConnectionManager"
    }
}
