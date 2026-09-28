package com.androidbridge.features.mediacontrol

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.util.Log
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.ByteArrayOutputStream

class MediaControlBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    // Latest now-playing info, for the phone app's own media card.
    private val _nowPlaying = MutableStateFlow<MediaState?>(null)
    val nowPlaying: StateFlow<MediaState?> = _nowPlaying.asStateFlow()

    private var sessionManager: MediaSessionManager? = null
    private var activeController: MediaController? = null
    private var pollThread: Thread? = null
    @Volatile private var isRunning = false

    fun start() {
        if (isRunning) return
        sessionManager = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
        isRunning = true

        pollThread = Thread({
            while (isRunning) {
                try {
                    val active = checkActiveSessions()
                    // Poll quickly while something is playing (responsive controls),
                    // but slow right down when idle to save battery.
                    Thread.sleep(if (active) 1500 else 4000)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "MediaPoll").also { it.start() }

        Log.i(TAG, "Media control started")
    }

    fun stop() {
        isRunning = false
        pollThread?.interrupt()
        pollThread = null
    }

    /** Returns true if something is currently playing (used to pace polling). */
    private fun checkActiveSessions(): Boolean {
        val sessions = try {
            sessionManager?.getActiveSessions(
                ComponentName(context, "com.androidbridge.features.notifications.BridgeNotificationListener")
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "No notification listener permission for media sessions")
            return false
        }

        // Valid = has metadata and isn't stopped/none/error.
        val candidates = sessions?.filter { session ->
            val state = session.playbackState?.state ?: PlaybackState.STATE_NONE
            session.metadata != null &&
                state != PlaybackState.STATE_NONE &&
                state != PlaybackState.STATE_STOPPED &&
                state != PlaybackState.STATE_ERROR
        } ?: emptyList()

        // Prefer the session that is ACTUALLY playing (e.g. the YouTube video you're
        // watching) over a different app that's merely paused — otherwise controls
        // and the now-playing display hit a random app.
        val controller = candidates.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: candidates.firstOrNull()

        if (controller == null) {
            if (activeController != null) {
                activeController = null
                sendEmptyState()
            }
            return false
        }

        activeController = controller
        sendMediaState(controller)
        return controller.playbackState?.state == PlaybackState.STATE_PLAYING
    }

    private fun sendMediaState(controller: MediaController) {
        val metadata = controller.metadata
        val playbackState = controller.playbackState

        // Don't report if no metadata or playback is stopped/none/error
        val state = playbackState?.state ?: PlaybackState.STATE_NONE
        if (metadata == null || state == PlaybackState.STATE_NONE || state == PlaybackState.STATE_STOPPED || state == PlaybackState.STATE_ERROR) {
            if (activeController != null) {
                sendEmptyState()
            }
            return
        }

        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        if (title.isEmpty()) {
            sendEmptyState()
            return
        }

        val artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""
        val album = metadata.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
        val duration = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)
        val position = playbackState?.position ?: 0
        val isPlaying = playbackState?.state == PlaybackState.STATE_PLAYING

        val builder = MediaState.newBuilder()
            .setTitle(title)
            .setArtist(artist)
            .setAlbum(album)
            .setIsPlaying(isPlaying)
            .setPositionMs(position)
            .setDurationMs(duration)
            .setAppPackage(controller.packageName ?: "")

        val art = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
        if (art != null) {
            val scaled = Bitmap.createScaledBitmap(art, 64, 64, true)
            val stream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 70, stream)
            builder.albumArt = ByteString.copyFrom(stream.toByteArray())
            scaled.recycle()
        }

        val mediaState = builder.build()
        _nowPlaying.value = mediaState
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setMediaState(mediaState)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    private fun sendEmptyState() {
        _nowPlaying.value = null
        val state = MediaState.newBuilder()
            .setIsPlaying(false)
            .build()
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setMediaState(state)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    fun handleMediaControl(control: MediaControl) {
        val controller = activeController ?: run {
            Log.w(TAG, "No active media session")
            return
        }

        val transport = controller.transportControls
        when (control.action) {
            MediaControl.Action.PLAY -> transport.play()
            MediaControl.Action.PAUSE -> transport.pause()
            MediaControl.Action.NEXT -> transport.skipToNext()
            MediaControl.Action.PREVIOUS -> transport.skipToPrevious()
            MediaControl.Action.SEEK -> transport.seekTo(control.seekPositionMs)
            else -> Log.w(TAG, "Unknown media action: ${control.action}")
        }
        Log.d(TAG, "Media control: ${control.action}")
    }

    companion object {
        private const val TAG = "MediaControl"
        var instance: MediaControlBridge? = null
    }
}
