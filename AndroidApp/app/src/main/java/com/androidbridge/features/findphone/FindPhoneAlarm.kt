package com.androidbridge.features.findphone

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.androidbridge.AndroidBridgeApp
import com.androidbridge.R
import com.androidbridge.service.ConnectionService

/**
 * "Find My Phone" — when the Mac fires this, the phone rings loudly through the
 * ALARM stream (which sounds even when the ringer is on silent/vibrate), buzzes,
 * and pops a full-screen "Stop" screen. It restores the previous alarm volume on
 * stop and auto-stops after a minute so it can never ring forever.
 */
object FindPhoneAlarm {

    private const val TAG = "FindPhoneAlarm"
    private const val NOTIFICATION_ID = 42
    private const val AUTO_STOP_MS = 60_000L

    @Volatile private var ringing = false
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var appContext: Context? = null
    private var previousAlarmVolume: Int = -1
    private val mainHandler = Handler(Looper.getMainLooper())
    private val autoStop = Runnable { stop() }

    val isRinging: Boolean get() = ringing

    @Synchronized
    fun start(context: Context) {
        if (ringing) { Log.i(TAG, "Already ringing"); return }
        val ctx = context.applicationContext
        appContext = ctx
        ringing = true
        Log.i(TAG, "Starting find-my-phone alarm")

        val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Force the alarm stream up to max, remembering what it was.
        try {
            previousAlarmVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            audio.setStreamVolume(AudioManager.STREAM_ALARM, max, 0)
        } catch (e: Exception) {
            Log.w(TAG, "Could not raise alarm volume", e)
        }

        // Loop a loud alarm tone on the ALARM usage (plays through silent mode).
        try {
            val uri: Uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            player = MediaPlayer().apply {
                setDataSource(ctx, uri)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Alarm sound failed", e)
        }

        // Buzz continuously.
        try {
            vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            val pattern = longArrayOf(0, 600, 400)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Vibrate failed", e)
        }

        postAlarmNotification(ctx)

        mainHandler.removeCallbacks(autoStop)
        mainHandler.postDelayed(autoStop, AUTO_STOP_MS)
    }

    @Synchronized
    fun stop() {
        if (!ringing && player == null) return
        Log.i(TAG, "Stopping find-my-phone alarm")
        ringing = false
        mainHandler.removeCallbacks(autoStop)

        try { player?.stop() } catch (_: Exception) {}
        try { player?.release() } catch (_: Exception) {}
        player = null

        try { vibrator?.cancel() } catch (_: Exception) {}
        vibrator = null

        val ctx = appContext
        if (ctx != null) {
            // Restore the alarm volume we clobbered.
            if (previousAlarmVolume >= 0) {
                try {
                    val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    audio.setStreamVolume(AudioManager.STREAM_ALARM, previousAlarmVolume, 0)
                } catch (_: Exception) {}
            }
            try {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(NOTIFICATION_ID)
            } catch (_: Exception) {}
        }
        previousAlarmVolume = -1
    }

    private fun postAlarmNotification(ctx: Context) {
        // Full-screen intent brings up the big Stop screen even from the lock screen.
        val fullScreen = Intent(ctx, FindPhoneActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        val fsFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val fullScreenPi = PendingIntent.getActivity(ctx, 0, fullScreen, fsFlags)

        // "Stop" action routes through the already-running service (no extra UI).
        val stopIntent = Intent(ctx, ConnectionService::class.java).apply {
            action = ConnectionService.ACTION_STOP_FIND_ALARM
        }
        val stopPi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(ctx, 1, stopIntent, fsFlags)
        } else {
            PendingIntent.getService(ctx, 1, stopIntent, fsFlags)
        }

        val notification = NotificationCompat.Builder(ctx, AndroidBridgeApp.CHANNEL_FIND_PHONE)
            .setContentTitle(ctx.getString(R.string.find_phone_title))
            .setContentText(ctx.getString(R.string.find_phone_body))
            .setSmallIcon(R.mipmap.ic_launcher_foreground)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreenPi, true)
            .addAction(0, ctx.getString(R.string.find_phone_stop), stopPi)
            .setContentIntent(fullScreenPi)
            .build()

        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "Could not post alarm notification", e)
        }
    }
}
