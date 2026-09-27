package com.androidbridge.features.macsystem

import com.androidbridge.proto.Messages.MacControl
import com.androidbridge.proto.Messages.MacMediaControl

/**
 * Shared holder for the connected Mac's status (battery/name/now-playing) and
 * hooks to send control commands. Updated by ConnectionManager; read by the UI.
 */
object MacBridge {
    @Volatile var batteryLevel: Int = -1
    @Volatile var isCharging: Boolean = false
    @Volatile var deviceName: String = ""
    @Volatile var hasData: Boolean = false

    // Mac system state
    @Volatile var volume: Int = -1
    @Volatile var muted: Boolean = false
    @Volatile var wifiOn: Boolean = false
    @Volatile var brightness: Int = -1
    @Volatile var bluetoothOn: Boolean = false

    // Mac now-playing (Music / Spotify)
    @Volatile var mediaHasMedia: Boolean = false
    @Volatile var mediaTitle: String = ""
    @Volatile var mediaArtist: String = ""
    @Volatile var mediaIsPlaying: Boolean = false

    /** Set by ConnectionManager to forward control to the connected Mac. */
    var onSendControl: ((MacControl.Action) -> Unit)? = null
    var onSendControlValue: ((MacControl.Action, Int) -> Unit)? = null
    var onSendMediaControl: ((MacMediaControl.Action) -> Unit)? = null

    fun send(action: MacControl.Action) { onSendControl?.invoke(action) }
    fun sendValue(action: MacControl.Action, value: Int) { onSendControlValue?.invoke(action, value) }
    fun sendMedia(action: MacMediaControl.Action) { onSendMediaControl?.invoke(action) }

    fun clear() {
        batteryLevel = -1
        isCharging = false
        deviceName = ""
        hasData = false
        volume = -1
        muted = false
        wifiOn = false
        brightness = -1
        bluetoothOn = false
        mediaHasMedia = false
    }
}
