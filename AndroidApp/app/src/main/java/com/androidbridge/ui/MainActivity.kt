package com.androidbridge.ui

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.ImageView
import android.widget.SeekBar
import android.widget.Toast
import com.androidbridge.R
import com.androidbridge.connection.PairingStore
import com.androidbridge.proto.Messages.MacControl
import com.androidbridge.proto.Messages.MacMediaControl
import com.androidbridge.databinding.ActivityMainBinding
import com.androidbridge.features.clipboard.ClipboardBridge
import com.androidbridge.features.macsystem.MacBridge
import com.androidbridge.features.mediacontrol.MediaControlBridge
import com.androidbridge.features.screenmirror.ScreenCapture
import com.androidbridge.features.screenmirror.ScreenMirrorBridge
import com.androidbridge.proto.Messages.MediaControl
import com.androidbridge.service.ConnectionService
import com.androidbridge.ui.onboarding.OnboardingActivity
import com.androidbridge.ui.pairing.PairingActivity

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var pairingStore: PairingStore
    private lateinit var mediaProjectionManager: MediaProjectionManager

    private val mirrorLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            // Route through the foreground service so it can set the mediaProjection
            // FGS type before starting capture (required on Android 14+).
            val intent = Intent(this, ConnectionService::class.java).apply {
                action = ConnectionService.ACTION_START_MIRROR
                putExtra(ConnectionService.EXTRA_RESULT_CODE, result.resultCode)
                putExtra(ConnectionService.EXTRA_RESULT_DATA, result.data)
            }
            ContextCompat.startForegroundService(this, intent)
            binding.mirrorButton.text = "Stop Mirroring"
        } else {
            Log.w(TAG, "Screen capture permission denied")
        }
    }

    private val pairingLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (pairingStore.hasPairedDevice()) {
            setServiceEnabled(true)
            showConnectedState()
            startConnectionService()
        } else {
            showPairingFlow()
        }
    }

    // "Send File to Mac" — pick one or more files and stream them to the Mac
    // (AirDrop-style, phone → Mac). Mirrors the Mac's "Send file to phone".
    private val sendFileLauncher = registerForActivityResult(
        ActivityResultContracts.GetMultipleContents()
    ) { uris ->
        if (uris.isNullOrEmpty()) return@registerForActivityResult
        val bridge = com.androidbridge.features.filesystem.FileSystemBridge.instance
        var sent = 0
        if (bridge != null) {
            for (uri in uris) {
                try { if (bridge.pushUriToMac(uri)) sent++ } catch (_: Exception) {}
            }
        }
        val msg = when {
            sent == 0 -> "Not connected to your Mac"
            sent == 1 -> "Sending to your Mac…"
            else -> "Sending $sent files to your Mac…"
        }
        android.widget.Toast.makeText(this, msg, android.widget.Toast.LENGTH_SHORT).show()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        pairingStore = PairingStore(this)
        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        val prefs = getSharedPreferences("androidbridge", MODE_PRIVATE)
        if (!prefs.getBoolean("onboarding_complete", false)) {
            startActivity(Intent(this, OnboardingActivity::class.java))
            finish()
            return
        }

        if (!pairingStore.hasPairedDevice()) {
            showPairingFlow()
        } else {
            showConnectedState()
            if (isServiceEnabled()) startConnectionService()
        }

        // Existing users who finished onboarding before media perms existed: ask now,
        // otherwise the gallery (MediaStore) comes back empty.
        ensureMediaPermissions()
        ensureBackgroundSurvival()

        maybeHandleMirrorRequest(intent)
    }

    /** Ask to exempt the app from battery optimization so the OS (Xiaomi/MIUI in
     *  particular) doesn't kill it after a while — which silently kills the
     *  Accessibility service and leaves the Mac able to view but not control. */
    private fun ensureBackgroundSurvival() {
        val prefs = getSharedPreferences("androidbridge", MODE_PRIVATE)
        if (prefs.getBoolean("battery_exemption_asked", false)) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                prefs.edit().putBoolean("battery_exemption_asked", true).apply()
                @android.annotation.SuppressLint("BatteryLife")
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"))
                startActivity(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Battery exemption request failed", e)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        maybeHandleMirrorRequest(intent)
    }

    /** Mac clicked "Mirror Screen": jump straight to the capture-consent dialog. */
    private fun maybeHandleMirrorRequest(intent: Intent?) {
        if (intent?.action != "com.androidbridge.REQUEST_MIRROR") return
        if (ScreenCapture.instance?.isCapturing == true) return
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "Enable “Display over other apps” first, then try again from the Mac.", Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
            return
        }
        mirrorLauncher.launch(mediaProjectionManager.createScreenCaptureIntent())
    }

    /** Request READ_MEDIA_* (Android 13+) / READ_EXTERNAL_STORAGE so the gallery can load. */
    private fun ensureMediaPermissions() {
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO
            )
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        val missing = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, missing.toTypedArray(), 9123)
        }
    }

    private var macRinging = false
    private val mediaHandler = Handler(Looper.getMainLooper())
    private val mediaRefresh = object : Runnable {
        override fun run() {
            updateMediaCard()
            updateMacCard()
            updateStatusIndicator()
            mediaHandler.postDelayed(this, 1500)
        }
    }

    /** Live status pill: green = Mac connected, amber = paired but waiting, grey = not paired. */
    private fun updateStatusIndicator() {
        val paired = pairingStore.hasPairedDevice()
        val connected = MacBridge.hasData
        val (color, text) = when {
            connected -> 0xFF30D158.toInt() to "Connected"
            paired && isServiceEnabled() -> 0xFFFF9F0A.toInt() to "Waiting for Mac"
            paired -> 0xFF8E8E93.toInt() to "Disconnected"
            else -> 0xFF8E8E93.toInt() to "Not connected"
        }
        try {
            binding.statusDot.backgroundTintList = android.content.res.ColorStateList.valueOf(color)
            binding.statusText.text = text
        } catch (_: Exception) {}
    }

    /** Control-Center-style bottom sheet with a slider (used by Volume and Brightness). */
    private fun showControlSlider(
        title: String,
        iconRes: Int,
        initial: Int,
        onChange: (Int) -> Unit
    ) {
        val sheet = com.google.android.material.bottomsheet.BottomSheetDialog(this)
        val view = layoutInflater.inflate(R.layout.dialog_slider, null)
        sheet.setContentView(view)

        view.findViewById<android.widget.TextView>(R.id.sliderTitle).text = title
        view.findViewById<ImageView>(R.id.sliderIcon).setImageResource(iconRes)
        val seek = view.findViewById<SeekBar>(R.id.sliderSeek)
        val valueLabel = view.findViewById<android.widget.TextView>(R.id.sliderValue)
        seek.progress = initial.coerceIn(0, 100)
        valueLabel.text = "${seek.progress}%"

        seek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar, progress: Int, fromUser: Boolean) {
                valueLabel.text = "$progress%"
            }
            override fun onStartTrackingTouch(sb: SeekBar) {}
            override fun onStopTrackingTouch(sb: SeekBar) {
                onChange(sb.progress)
            }
        })
        sheet.show()
    }

    /** Tint a control tile to show ON (accent) vs OFF (default surface). */
    private fun applyTileState(button: com.google.android.material.button.MaterialButton, on: Boolean) {
        val bg = if (on) 0xFF0A84FF.toInt() else ContextCompat.getColor(this, R.color.surface_elevated)
        val fg = if (on) 0xFFFFFFFF.toInt() else ContextCompat.getColor(this, R.color.on_surface)
        button.backgroundTintList = android.content.res.ColorStateList.valueOf(bg)
        button.setTextColor(fg)
        button.iconTint = android.content.res.ColorStateList.valueOf(fg)
    }

    private fun updateMacCard() {
        if (!MacBridge.hasData) {
            binding.macCard.visibility = View.GONE
            binding.macMediaCard.visibility = View.GONE
            return
        }
        binding.macCard.visibility = View.VISIBLE
        binding.macTitle.text = if (MacBridge.deviceName.isNotEmpty()) MacBridge.deviceName else "Mac"
        val lvl = MacBridge.batteryLevel
        binding.macBattery.text = when {
            lvl < 0 -> "Battery —"
            MacBridge.isCharging -> "Battery $lvl% · Charging"
            else -> "Battery $lvl%"
        }

        // Highlight the Wi-Fi / Bluetooth tiles when they're ON (like Control Center).
        applyTileState(binding.macWifiButton, MacBridge.wifiOn)
        applyTileState(binding.macBluetoothButton, MacBridge.bluetoothOn)

        // Mac now-playing — keep the controls available even without track info so
        // the buttons still drive browser/video playback via Mac media keys.
        binding.macMediaCard.visibility = View.VISIBLE
        if (MacBridge.mediaHasMedia && MacBridge.mediaTitle.isNotEmpty()) {
            binding.macMediaTitle.text = MacBridge.mediaTitle
            binding.macMediaArtist.text = MacBridge.mediaArtist
            binding.macMediaPlayPause.setImageResource(
                if (MacBridge.mediaIsPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play
            )
        } else {
            binding.macMediaTitle.text = "Mac Media"
            binding.macMediaArtist.text = "Controls whatever is playing on your Mac"
            binding.macMediaPlayPause.setImageResource(android.R.drawable.ic_media_play)
        }
    }

    override fun onResume() {
        super.onResume()
        if (pairingStore.hasPairedDevice()) {
            showConnectedState()
        }
        // Android 10+ only allows clipboard reads while the app has focus.
        // Read + push the current clipboard whenever the app is foregrounded.
        ClipboardBridge.instance?.checkClipboardOnResume()
        mediaHandler.post(mediaRefresh)
        recoverNotificationListener()
        maybePromptPermissions()
    }

    private var permsPrompted = false

    /** Notifications + phone→Mac clipboard depend on two special-access services
     *  that Android silently REVOKES on every app update/reinstall:
     *  Notification access (NotificationListenerService) and the Accessibility
     *  service. Detect either being off and guide the user to re-enable. */
    private fun maybePromptPermissions() {
        if (!pairingStore.hasPairedDevice()) return
        val notifOff = !isNotificationAccessEnabled()
        val a11yOff = !isTouchServiceEnabled()
        if (!notifOff && !a11yOff) { permsPrompted = false; return }
        if (permsPrompted) return
        permsPrompted = true

        val missing = buildString {
            if (notifOff) append("• Notification access (to mirror SMS and notifications)\n")
            if (a11yOff) append("• Accessibility (to control the phone and sync the clipboard)\n")
        }
        val b = androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Re-enable Mac Connect access")
            .setMessage(
                "Updating the app turns these off. Turn them back on so notifications " +
                "and clipboard work again:\n\n$missing"
            )
            .setNegativeButton("Later", null)
        if (notifOff) b.setPositiveButton("Notification access") { _, _ ->
            try { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) } catch (_: Exception) {}
        }
        if (a11yOff) b.setNeutralButton("Accessibility") { _, _ ->
            try { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) } catch (_: Exception) {}
        }
        b.show()
    }

    /** If notification access is still granted but the listener got unbound after
     *  a process restart/update, wake it back up — no user action needed. */
    private fun recoverNotificationListener() {
        if (!isNotificationAccessEnabled()) return
        try {
            android.service.notification.NotificationListenerService.requestRebind(
                ComponentName(this, com.androidbridge.features.notifications.BridgeNotificationListener::class.java)
            )
        } catch (_: Exception) {}
    }

    private fun isNotificationAccessEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val cn = ComponentName(this, com.androidbridge.features.notifications.BridgeNotificationListener::class.java).flattenToString()
        return flat.split(":").any { it.equals(cn, true) || it.endsWith("BridgeNotificationListener") }
    }

    private fun isTouchServiceEnabled(): Boolean {
        val expected = ComponentName(this, com.androidbridge.features.screenmirror.TouchInjectionService::class.java)
            .flattenToString()
        val enabled = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.split(":").any {
            it.equals(expected, ignoreCase = true) || it.endsWith("TouchInjectionService")
        }
    }

    override fun onPause() {
        super.onPause()
        mediaHandler.removeCallbacks(mediaRefresh)
    }

    private fun updateMediaCard() {
        val state = MediaControlBridge.instance?.nowPlaying?.value
        if (state == null || state.title.isNullOrEmpty()) {
            binding.mediaCard.visibility = View.GONE
            return
        }
        binding.mediaCard.visibility = View.VISIBLE
        binding.mediaTrack.text = state.title
        binding.mediaArtist.text = state.artist
        binding.mediaPlayPause.setImageResource(
            if (state.isPlaying) android.R.drawable.ic_media_pause
            else android.R.drawable.ic_media_play
        )
    }

    private fun sendMedia(action: MediaControl.Action) {
        MediaControlBridge.instance?.handleMediaControl(
            MediaControl.newBuilder().setAction(action).build()
        )
        mediaHandler.postDelayed({ updateMediaCard() }, 350)
    }

    private fun isServiceEnabled(): Boolean =
        getSharedPreferences("androidbridge", MODE_PRIVATE).getBoolean("service_enabled", true)

    private fun setServiceEnabled(enabled: Boolean) {
        getSharedPreferences("androidbridge", MODE_PRIVATE)
            .edit().putBoolean("service_enabled", enabled).apply()
    }

    private fun updateConnectionToggle() {
        val enabled = isServiceEnabled()
        binding.connectionToggleButton.visibility = View.VISIBLE
        binding.connectionHint.visibility = View.VISIBLE
        binding.connectionToggleButton.text = if (enabled) "Disconnect" else "Connect"
        binding.connectionHint.text = if (enabled)
            "Disconnecting keeps the pairing — tap the same button to reconnect later. No QR scan needed."
        else
            "Tap Connect to link with your Mac again — pairing is remembered."
        binding.cardStatus.text = if (enabled)
            "Connected — running in background"
        else
            "Disconnected — tap Connect to enable"
    }

    /** Once paired, Unpair is a quiet secondary action — Connect/Disconnect is primary. */
    private fun styleUnpairAsSecondary() {
        binding.pairButton.backgroundTintList =
            android.content.res.ColorStateList.valueOf(0x00000000)
        binding.pairButton.setTextColor(ContextCompat.getColor(this, R.color.text_secondary))
        binding.pairButton.icon = null
        binding.pairButton.textSize = 14f
    }

    private fun stylePairAsPrimary() {
        binding.pairButton.backgroundTintList =
            android.content.res.ColorStateList.valueOf(ContextCompat.getColor(this, R.color.primary))
        binding.pairButton.setTextColor(ContextCompat.getColor(this, R.color.on_primary))
        binding.pairButton.setIconResource(R.drawable.ic_qr_illustration)
        binding.pairButton.textSize = 16f
    }

    private fun showPairingFlow() {
        binding.statusText.text = "Not connected"
        binding.cardStatus.text = "No device paired"
        binding.mirrorButton.visibility = View.GONE
        binding.connectionToggleButton.visibility = View.GONE
        binding.mediaCard.visibility = View.GONE
        binding.macCard.visibility = View.GONE
        binding.macMediaCard.visibility = View.GONE
        binding.pairButton.text = "Pair with Mac"
        stylePairAsPrimary()
        binding.connectionHint.visibility = View.GONE
        binding.pairButton.setOnClickListener {
            Log.i(TAG, "Starting pairing flow")
            pairingLauncher.launch(Intent(this, PairingActivity::class.java))
        }
    }

    private fun showConnectedState() {
        binding.statusText.text = "Paired"
        binding.cardStatus.text = "Service running — waiting for Mac to connect"
        binding.mirrorButton.visibility = View.VISIBLE

        // Media controls
        binding.mediaPrev.setOnClickListener { sendMedia(MediaControl.Action.PREVIOUS) }
        binding.mediaNext.setOnClickListener { sendMedia(MediaControl.Action.NEXT) }
        binding.mediaPlayPause.setOnClickListener {
            val playing = MediaControlBridge.instance?.nowPlaying?.value?.isPlaying == true
            sendMedia(if (playing) MediaControl.Action.PAUSE else MediaControl.Action.PLAY)
        }
        updateMediaCard()

        // Mac controls (lock / find from the phone)
        binding.lockMacButton.setOnClickListener { MacBridge.send(MacControl.Action.LOCK) }
        binding.findMacButton.setOnClickListener {
            if (macRinging) {
                MacBridge.send(MacControl.Action.STOP_RING)
                macRinging = false
            } else {
                MacBridge.send(MacControl.Action.RING)
                macRinging = true
            }
            binding.findMacButton.text = if (macRinging) "Stop Sound" else "Find Mac"
        }
        binding.sendFileToMacButton.setOnClickListener {
            try {
                sendFileLauncher.launch("*/*")
            } catch (e: Exception) {
                android.widget.Toast.makeText(this, "Couldn't open the file picker", android.widget.Toast.LENGTH_SHORT).show()
            }
        }
        // Mac now-playing controls
        binding.macMediaPrev.setOnClickListener { MacBridge.sendMedia(MacMediaControl.Action.PREVIOUS) }
        binding.macMediaNext.setOnClickListener { MacBridge.sendMedia(MacMediaControl.Action.NEXT) }
        binding.macMediaPlayPause.setOnClickListener { MacBridge.sendMedia(MacMediaControl.Action.PLAY_PAUSE) }

        // Mac control panel — Volume / Brightness open a slider; Wi-Fi / Bluetooth toggle.
        binding.macVolumeButton.setOnClickListener {
            showControlSlider(
                "Volume", R.drawable.ic_ctl_volume,
                MacBridge.volume.coerceIn(0, 100),
            ) { MacBridge.sendValue(MacControl.Action.SET_VOLUME, it); MacBridge.volume = it }
        }
        binding.macBrightnessButton.setOnClickListener {
            showControlSlider(
                "Brightness", R.drawable.ic_ctl_brightness,
                MacBridge.brightness.coerceIn(0, 100),
            ) { MacBridge.sendValue(MacControl.Action.SET_BRIGHTNESS, it); MacBridge.brightness = it }
        }
        binding.macWifiButton.setOnClickListener {
            val turnOn = !MacBridge.wifiOn
            MacBridge.send(if (turnOn) MacControl.Action.WIFI_ON else MacControl.Action.WIFI_OFF)
            MacBridge.wifiOn = turnOn
            updateMacCard()
        }
        binding.macBluetoothButton.setOnClickListener {
            val turnOn = !MacBridge.bluetoothOn
            MacBridge.send(if (turnOn) MacControl.Action.BT_ON else MacControl.Action.BT_OFF)
            MacBridge.bluetoothOn = turnOn
            updateMacCard()
        }
        updateMacCard()

        // Connect / Disconnect toggle — stops the background service to save battery.
        updateConnectionToggle()
        binding.connectionToggleButton.setOnClickListener {
            if (isServiceEnabled()) {
                setServiceEnabled(false)
                stopConnectionService()
                // Clear Mac state immediately so the status dot flips in real time.
                MacBridge.clear()
                Log.i(TAG, "User disconnected — service stopped")
            } else {
                setServiceEnabled(true)
                startConnectionService()
                Log.i(TAG, "User reconnected — service started")
            }
            updateConnectionToggle()
            updateStatusIndicator()
            updateMacCard()
        }
        binding.mirrorButton.setOnClickListener {
            if (ScreenCapture.instance?.isCapturing == true) {
                val intent = Intent(this, ConnectionService::class.java).apply {
                    action = ConnectionService.ACTION_STOP_MIRROR
                }
                ContextCompat.startForegroundService(this, intent)
                binding.mirrorButton.text = "Start Mirroring"
            } else {
                // Need "Display over other apps" so the screen stays awake while mirroring.
                if (!Settings.canDrawOverlays(this)) {
                    Toast.makeText(
                        this,
                        "Enable “Display over other apps” so the screen stays awake during mirroring, then tap Start again.",
                        Toast.LENGTH_LONG
                    ).show()
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    return@setOnClickListener
                }
                mirrorLauncher.launch(mediaProjectionManager.createScreenCaptureIntent())
            }
        }
        binding.pairButton.text = "Unpair"
        styleUnpairAsSecondary()
        binding.pairButton.setOnClickListener {
            // Quiet confirmation — unpairing is the destructive path, not the main one.
            androidx.appcompat.app.AlertDialog.Builder(this)
                .setTitle("Unpair from Mac?")
                .setMessage("This forgets the pairing. You'll need to scan the QR code again to reconnect.")
                .setPositiveButton("Unpair") { _, _ ->
                    pairingStore.clearPairing()
                    stopConnectionService()
                    MacBridge.clear()
                    showPairingFlow()
                }
                .setNegativeButton("Cancel", null)
                .show()
        }
    }

    private fun startConnectionService() {
        val intent = Intent(this, ConnectionService::class.java)
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopConnectionService() {
        val intent = Intent(this, ConnectionService::class.java)
        stopService(intent)
    }

    companion object {
        private const val TAG = "MainActivity"
    }
}
