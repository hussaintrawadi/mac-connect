package com.androidbridge.features.calls

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Log
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class CallAudioBridge {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    private var captureThread: Thread? = null
    private var playbackTrack: AudioTrack? = null
    private val isCapturing = AtomicBoolean(false)
    private val sequenceCounter = AtomicLong(0)

    // Audio config
    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val frameSizeMs = 20 // 20ms frames — standard for voice
    private val frameSamples = sampleRate * frameSizeMs / 1000 // 320 samples
    private val frameBytes = frameSamples * 2 // 16-bit = 2 bytes per sample

    // MARK: - Capture (Android call audio → Mac)

    fun startCapture() {
        if (isCapturing.get()) return

        val bufferSize = maxOf(
            AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat),
            frameBytes * 4
        )

        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "No RECORD_AUDIO permission", e)
            return
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize")
            recorder.release()
            return
        }

        isCapturing.set(true)
        recorder.startRecording()

        captureThread = Thread({
            val buffer = ByteArray(frameBytes)
            Log.i(TAG, "Audio capture started: ${sampleRate}Hz, ${frameSizeMs}ms frames")

            while (isCapturing.get()) {
                val read = recorder.read(buffer, 0, frameBytes)
                if (read > 0) {
                    sendAudioChunk(buffer, read)
                }
            }

            recorder.stop()
            recorder.release()
            Log.i(TAG, "Audio capture stopped")
        }, "CallAudioCapture").also { it.start() }
    }

    fun stopCapture() {
        isCapturing.set(false)
        captureThread?.join(1000)
        captureThread = null
    }

    private fun sendAudioChunk(data: ByteArray, size: Int) {
        // Send raw PCM for now — Opus encoding can be added as optimization
        // The frame is small enough (640 bytes per 20ms) that PCM is fine on LAN
        val chunk = CallAudioChunk.newBuilder()
            .setOpusData(ByteString.copyFrom(data, 0, size))
            .setTimestampUs(System.nanoTime() / 1000)
            .setSequence(sequenceCounter.incrementAndGet().toInt())
            .build()

        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setCallAudioChunk(chunk)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    // MARK: - Playback (Mac mic audio → Android call)

    fun startPlayback() {
        val bufferSize = maxOf(
            AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, audioFormat),
            frameBytes * 4
        )

        playbackTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(audioFormat)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        playbackTrack?.play()
        Log.i(TAG, "Audio playback started")
    }

    fun stopPlayback() {
        playbackTrack?.stop()
        playbackTrack?.release()
        playbackTrack = null
        Log.i(TAG, "Audio playback stopped")
    }

    fun handleAudioFromMac(chunk: CallAudioChunk) {
        val data = chunk.opusData.toByteArray()
        if (data.isEmpty()) return

        playbackTrack?.write(data, 0, data.size)
    }

    // MARK: - Mute

    fun muteMicrophone(mute: Boolean) {
        // Handled by stopping/starting capture
        if (mute) {
            stopCapture()
        } else {
            startCapture()
        }
    }

    companion object {
        private const val TAG = "CallAudioBridge"
    }
}
