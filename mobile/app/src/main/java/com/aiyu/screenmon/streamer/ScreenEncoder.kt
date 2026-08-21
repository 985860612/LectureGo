package com.aiyu.screenmon.streamer

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.aiyu.screenmon.proto.Protocol
import java.nio.ByteBuffer

/**
 * Hardware H.264/H.265 encoder fed by a screen or Camera2 [Surface]. Configured for low
 * latency: CBR, no B-frames, short keyframe interval, real-time mode where the
 * device supports it. Emits each access unit to [onFrame] tagged with proto flags.
 */
class ScreenEncoder(
    val width: Int,
    val height: Int,
    private val bitRate: Int,
    private val frameRate: Int,
    preferHevc: Boolean = false,
    private val onFrame: (buf: ByteBuffer, size: Int, ptsUs: Long, protoFlags: Int) -> Unit,
) {
    /** Actual codec in use ("h265" or "h264"); reported to monitors. */
    val codec: String = if (preferHevc && hasEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC)) Protocol.CODEC_H265 else Protocol.CODEC_H264
    private val mime = if (codec == Protocol.CODEC_H265) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private var codecObj: MediaCodec? = null
    private var callbackThread: HandlerThread? = null
    @Volatile private var started = false
    private var framesOut = 0
    private val monotonicToWallUs = System.currentTimeMillis() * 1000 - System.nanoTime() / 1000

    /** Build the encoder and return its input [Surface] for the VirtualDisplay. */
    fun createInputSurface(): Surface {
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)           // recover from LAN packet loss within 1s
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            // carry SPS/PPS inside every keyframe so a freshly-joined decoder can
            // start without a separate codec-config buffer (some encoders only
            // report csd via the output format change, never as a buffer)
            setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
            // keep the stream alive on a static screen (repeat last frame after 1s of no change)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try { setInteger(MediaFormat.KEY_LATENCY, 1) } catch (_: Exception) {}
            }
        }
        val c = MediaCodec.createEncoderByType(mime)
        // run encoder callbacks (which fragment + send UDP) off the main thread,
        // otherwise socket sends throw NetworkOnMainThreadException
        val ht = HandlerThread("enc-cb").also { it.start() }
        callbackThread = ht
        c.setCallback(callback, Handler(ht.looper))
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codecObj = c
        Log.i(TAG, "encoder=$mime ${width}x$height")
        return c.createInputSurface()
    }

    fun start() {
        codecObj?.start()
        started = true
    }

    /** Ask the encoder to emit a sync (key) frame ASAP — used when a monitor reports loss. */
    fun requestKeyframe() {
        if (!started) return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codecObj?.setParameters(params)
        } catch (e: Exception) {
            Log.w(TAG, "requestKeyframe failed: $e")
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, index: Int) { /* surface input */ }

        override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            try {
                val buf = c.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    var flags = 0
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) flags = flags or Protocol.FLAG_CONFIG
                    if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) flags = flags or Protocol.FLAG_KEYFRAME
                    onFrame(buf, info.size, info.presentationTimeUs + monotonicToWallUs, flags)
                    framesOut++
                    if (flags and Protocol.FLAG_CONFIG != 0 || flags and Protocol.FLAG_KEYFRAME != 0 || framesOut % 60 == 0) {
                        Log.i(TAG, "out#$framesOut size=${info.size} config=${flags and Protocol.FLAG_CONFIG != 0} key=${flags and Protocol.FLAG_KEYFRAME != 0}")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "output buffer: $e")
            } finally {
                try { c.releaseOutputBuffer(index, false) } catch (_: Exception) {}
            }
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            Log.e(TAG, "codec error: $e")
        }

        override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "output format: $format")
        }
    }

    fun release() {
        started = false
        try { codecObj?.stop() } catch (_: Exception) {}
        try { codecObj?.release() } catch (_: Exception) {}
        codecObj = null
        try { callbackThread?.quitSafely() } catch (_: Exception) {}
        callbackThread = null
    }

    companion object {
        private const val TAG = "ScreenEncoder"

        /** True if the device has a hardware/software encoder for [mime] (e.g. video/hevc). */
        fun hasEncoder(mime: String): Boolean = try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }
        } catch (e: Exception) {
            false
        }

        /** 4K is exposed only when a codec reports it; callers must not downgrade silently. */
        fun supportsSize(mime: String, width: Int, height: Int, fps: Int): Boolean = try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                if (!info.isEncoder || info.supportedTypes.none { it.equals(mime, true) }) return@any false
                val video = info.getCapabilitiesForType(mime).videoCapabilities ?: return@any false
                video.areSizeAndRateSupported(width, height, fps.toDouble()) ||
                    video.areSizeAndRateSupported(height, width, fps.toDouble())
            }
        } catch (_: Exception) {
            false
        }
    }
}
