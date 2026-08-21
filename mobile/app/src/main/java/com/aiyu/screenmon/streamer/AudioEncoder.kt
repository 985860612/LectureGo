package com.aiyu.screenmon.streamer

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import com.aiyu.screenmon.proto.Protocol
import kotlin.concurrent.thread

/** Captures phone playback audio for screen mode or the phone mic for camera mode. */
class AudioEncoder(
    private val mode: CaptureMode,
    private val projection: MediaProjection?,
    val sampleRate: Int = 48_000,
    private val onFrame: (data: ByteArray, ptsUs: Long, flags: Int) -> Unit,
    private val onError: (String) -> Unit,
) {
    val channels: Int = if (mode == CaptureMode.SCREEN) 2 else 1
    private val channelMask = if (channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
    private val monotonicToWallUs = System.currentTimeMillis() * 1000 - System.nanoTime() / 1000
    private var record: AudioRecord? = null
    private var codec: MediaCodec? = null
    @Volatile private var running = false

    @SuppressLint("MissingPermission")
    fun start() {
        val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
            .coerceAtLeast(16_384)
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        val builder = AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(minBuffer * 2)
        if (mode == CaptureMode.SCREEN) {
            val activeProjection = projection ?: throw IllegalStateException("屏幕声音需要 MediaProjection")
            builder.setAudioPlaybackCaptureConfig(
                AudioPlaybackCaptureConfiguration.Builder(activeProjection)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                    .build()
            )
        } else {
            builder.setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
        }
        val audioRecord = builder.build()
        check(audioRecord.state == AudioRecord.STATE_INITIALIZED) { "音频采集器初始化失败" }

        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val mediaFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, if (channels == 2) 192_000 else 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, minBuffer * 2)
        }
        encoder.configure(mediaFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()
        audioRecord.startRecording()
        record = audioRecord
        codec = encoder
        running = true
        thread(name = "audio-capture") { encodeLoop(audioRecord, encoder) }
    }

    private fun encodeLoop(audioRecord: AudioRecord, encoder: MediaCodec) {
        try {
            while (running) {
                val inputIndex = encoder.dequeueInputBuffer(10_000)
                if (inputIndex >= 0) {
                    val input = encoder.getInputBuffer(inputIndex) ?: continue
                    input.clear()
                    val count = audioRecord.read(input, input.capacity(), AudioRecord.READ_BLOCKING)
                    if (count > 0) {
                        encoder.queueInputBuffer(inputIndex, 0, count, System.nanoTime() / 1000, 0)
                    } else {
                        encoder.queueInputBuffer(inputIndex, 0, 0, System.nanoTime() / 1000, 0)
                    }
                }
                drain(encoder)
            }
            drain(encoder)
        } catch (e: Exception) {
            if (running) onError("音频采集失败：${e.message}")
        } finally {
            Log.i(TAG, "audio encoder stopped")
        }
    }

    private fun drain(encoder: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, 0)
            if (index < 0) return
            try {
                val output = encoder.getOutputBuffer(index)
                if (output != null && info.size > 0) {
                    output.position(info.offset)
                    output.limit(info.offset + info.size)
                    val data = ByteArray(info.size)
                    output.get(data)
                    var flags = Protocol.FLAG_AUDIO
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        flags = flags or Protocol.FLAG_CONFIG
                    }
                    val pts = if (info.presentationTimeUs > 0) {
                        info.presentationTimeUs + monotonicToWallUs
                    } else {
                        System.currentTimeMillis() * 1000
                    }
                    onFrame(data, pts, flags)
                }
            } finally {
                encoder.releaseOutputBuffer(index, false)
            }
        }
    }

    fun stop() {
        running = false
        try { record?.stop() } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        record = null
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
    }

    companion object { private const val TAG = "AudioEncoder" }
}
