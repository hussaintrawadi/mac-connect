package com.androidbridge.features.screenmirror

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.Surface
import android.view.View
import android.view.WindowManager
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString
import java.nio.ByteBuffer

class ScreenCapture(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null

    private var encoderThread: HandlerThread? = null
    private var encoderHandler: Handler? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var keepOnView: View? = null

    var isCapturing = false
        private set
    private var captureWidth = 0
    private var captureHeight = 0
    private var frameCounter = 0

    // MARK: - Configuration

    var targetFps = 30
    var targetBitrate = 4_000_000 // 4 Mbps
    var scaleFactor = 0.5f // Capture at half resolution for performance

    // MARK: - Start / Stop

    fun startCapture(resultCode: Int, data: Intent) {
        if (isCapturing) return

        try {
            val projectionManager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjection = projectionManager.getMediaProjection(resultCode, data)

            if (mediaProjection == null) {
                Log.e(TAG, "Failed to get MediaProjection")
                return
            }

            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val metrics: DisplayMetrics
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                val windowMetrics = wm.maximumWindowMetrics
                metrics = DisplayMetrics().apply {
                    widthPixels = windowMetrics.bounds.width()
                    heightPixels = windowMetrics.bounds.height()
                    densityDpi = context.resources.displayMetrics.densityDpi
                }
            } else {
                metrics = DisplayMetrics()
                @Suppress("DEPRECATION")
                wm.defaultDisplay.getRealMetrics(metrics)
            }

            captureWidth = (metrics.widthPixels * scaleFactor).toInt().roundToEven()
            captureHeight = (metrics.heightPixels * scaleFactor).toInt().roundToEven()
            val density = metrics.densityDpi

            Log.i(TAG, "Screen: ${metrics.widthPixels}x${metrics.heightPixels} → capture: ${captureWidth}x${captureHeight}")

            // Set up the encoder first so we have a handler for the projection callback
            setupEncoder()

            // Android 14+ (API 34) REQUIRES a registered callback before createVirtualDisplay,
            // otherwise it throws IllegalStateException. This is why mirroring never worked.
            val callback = object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "MediaProjection stopped by system/user")
                    stopCapture()
                }
            }
            projectionCallback = callback
            mediaProjection!!.registerCallback(callback, encoderHandler ?: Handler(Looper.getMainLooper()))

            sendVideoConfig()

            // Set capturing BEFORE the virtual display starts feeding frames, so the
            // first encoder output (SPS/PPS codec config) isn't dropped — the Mac needs
            // it to build the H.264 decoder.
            isCapturing = true
            setupVirtualDisplay(density)
            acquireWakeLock()
            addKeepScreenOnOverlay()

            Log.i(TAG, "Screen capture started")
        } catch (e: Exception) {
            Log.e(TAG, "startCapture failed", e)
            isCapturing = false
            try { stopCapture() } catch (_: Exception) {}
        }
    }

    fun stopCapture() {
        if (!isCapturing) return
        isCapturing = false
        frameCounter = 0

        releaseWakeLock()
        removeKeepScreenOnOverlay()

        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null

        try { encoder?.stop() } catch (_: Exception) {}
        try { encoder?.release() } catch (_: Exception) {}
        encoder = null

        try { inputSurface?.release() } catch (_: Exception) {}
        inputSurface = null

        try {
            projectionCallback?.let { mediaProjection?.unregisterCallback(it) }
        } catch (_: Exception) {}
        projectionCallback = null

        try { mediaProjection?.stop() } catch (_: Exception) {}
        mediaProjection = null

        try { encoderThread?.quitSafely() } catch (_: Exception) {}
        encoderThread = null
        encoderHandler = null

        Log.i(TAG, "Screen capture stopped")
    }

    // MARK: - Encoder Setup

    private fun setupEncoder() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, captureWidth, captureHeight).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, targetBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, targetFps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // Keyframe every 1 second (faster startup)
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            // NOTE: Do NOT force KEY_PROFILE / KEY_LEVEL — many device encoders silently
            // produce zero output when a profile/level they dislike is requested. Letting
            // the encoder pick its default (Baseline-compatible) is far more reliable.
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            }
        }

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder!!.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = encoder!!.createInputSurface()

        encoderThread = HandlerThread("ScreenEncoder").also { it.start() }
        encoderHandler = Handler(encoderThread!!.looper)

        encoder!!.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                // Input comes from Surface — nothing to do
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (!isCapturing) return

                try {
                    val buffer = codec.getOutputBuffer(index) ?: return
                    if (info.size > 0) {
                        val data = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        buffer.get(data)

                        val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        val isKeyframe = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        frameCounter++
                        if (isConfig || frameCounter <= 3 || frameCounter % 60 == 0) {
                            Log.i(TAG, "Encoder out #$frameCounter: ${info.size}B config=$isConfig key=$isKeyframe")
                        }
                        sendVideoFrame(data, info.presentationTimeUs, isKeyframe || isConfig)
                    }
                    codec.releaseOutputBuffer(index, false)
                } catch (e: Exception) {
                    Log.e(TAG, "Encoder output error", e)
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Encoder error", e)
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "Encoder format changed: $format")
            }
        }, encoderHandler)

        encoder!!.start()
        Log.i(TAG, "H.264 encoder started: ${captureWidth}x${captureHeight} @ ${targetFps}fps, ${targetBitrate / 1_000_000}Mbps")
    }

    private fun setupVirtualDisplay(density: Int) {
        virtualDisplay = mediaProjection!!.createVirtualDisplay(
            "AndroidBridge",
            captureWidth,
            captureHeight,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            encoderHandler
        )
    }

    // MARK: - Send

    private fun sendVideoConfig() {
        val config = VideoConfig.newBuilder()
            .setWidth(captureWidth)
            .setHeight(captureHeight)
            .setFps(targetFps)
            .setBitrate(targetBitrate)
            .setOrientation(VideoConfig.Orientation.PORTRAIT)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setVideoConfig(config)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    private fun sendVideoFrame(data: ByteArray, timestampUs: Long, isKeyframe: Boolean) {
        val frame = VideoFrame.newBuilder()
            .setData(ByteString.copyFrom(data))
            .setTimestampUs(timestampUs)
            .setIsKeyframe(isKeyframe)
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setVideoFrame(frame)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    // MARK: - Adaptive Bitrate

    fun adjustBitrate(newBitrate: Int) {
        if (!isCapturing) return
        targetBitrate = newBitrate
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrate)
            encoder?.setParameters(params)
            Log.i(TAG, "Bitrate adjusted to ${newBitrate / 1_000_000}Mbps")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to adjust bitrate", e)
        }
    }

    fun requestKeyframe() {
        if (!isCapturing) return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            encoder?.setParameters(params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to request keyframe", e)
        }
    }

    /**
     * Keeps the screen on (dimmed) while mirroring. A regular app can't capture a
     * fully-OFF display (MediaProjection mirrors the live display, which goes black
     * when the screen sleeps), so we hold the display awake — dimmed to save power —
     * so the mirror keeps working and the phone stays usable from the Mac.
     */
    @Suppress("DEPRECATION")
    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(
                PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ON_AFTER_RELEASE,
                "MacConnect:Mirror"
            )
            lock.setReferenceCounted(false)
            lock.acquire(60 * 60 * 1000L) // 1h safety cap
            wakeLock = lock
            Log.i(TAG, "Mirror wake lock acquired (screen kept on, dimmed)")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire wake lock", e)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
    }

    /**
     * The reliable way to keep the screen on (so the phone doesn't sleep/lock and the
     * mirror keeps streaming): a 1x1 invisible overlay window with FLAG_KEEP_SCREEN_ON.
     * Requires the "Display over other apps" permission.
     */
    private fun addKeepScreenOnOverlay() {
        try {
            if (!Settings.canDrawOverlays(context)) {
                Log.w(TAG, "Overlay permission not granted — screen may sleep during mirroring")
                return
            }
            if (keepOnView != null) return
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val view = View(context)
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
            val params = WindowManager.LayoutParams(
                1, 1, type,
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSPARENT
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                // Keep the screen ON (so mirroring keeps streaming) but drive the
                // physical backlight to near-minimum — you're watching on the Mac,
                // so there's no reason to burn the AMOLED at full brightness.
                screenBrightness = 0.02f
            }
            wm.addView(view, params)
            keepOnView = view
            Log.i(TAG, "Keep-screen-on overlay added (dimmed) — stays awake at min brightness while mirroring")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to add keep-screen-on overlay", e)
        }
    }

    private fun removeKeepScreenOnOverlay() {
        try {
            keepOnView?.let {
                val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                wm.removeView(it)
            }
        } catch (_: Exception) {}
        keepOnView = null
    }

    private fun Int.roundToEven(): Int = if (this % 2 == 0) this else this + 1

    companion object {
        private const val TAG = "ScreenCapture"
        const val REQUEST_CODE = 1001
        var instance: ScreenCapture? = null
    }
}
