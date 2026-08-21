package com.aiyu.screenmon.streamer

import com.aiyu.screenmon.proto.Protocol
import java.util.ArrayDeque

internal data class PendingMediaFrame(
    val data: ByteArray,
    val sequence: Int,
    val flags: Int,
    val ptsUs: Long,
) {
    val isAudio: Boolean get() = flags and Protocol.FLAG_AUDIO != 0
    val isKeyframe: Boolean get() = flags and Protocol.FLAG_KEYFRAME != 0
    val isConfig: Boolean get() = flags and Protocol.FLAG_CONFIG != 0
}

internal data class MediaOfferResult(
    val accepted: Boolean,
    val requestKeyframe: Boolean = false,
    val droppedVideoFrames: Int = 0,
    val droppedAudioFrames: Int = 0,
)

/**
 * Low-latency bounded queue. Audio is dequeued first. If video falls behind, the
 * prediction chain is discarded and non-keyframes are rejected until a new keyframe arrives.
 */
internal class MediaFrameQueue(
    private val maxVideoFrames: Int = 2,
    private val maxAudioFrames: Int = 24,
) {
    private val monitor = Object()
    private val video = ArrayDeque<PendingMediaFrame>()
    private val audio = ArrayDeque<PendingMediaFrame>()
    private var waitingForKeyframe = false
    private var closed = false

    fun offer(frame: PendingMediaFrame): MediaOfferResult = synchronized(monitor) {
        if (closed) return@synchronized MediaOfferResult(accepted = false)
        val result = if (frame.isAudio) offerAudio(frame) else offerVideo(frame)
        if (result.accepted) monitor.notifyAll()
        result
    }

    fun take(): PendingMediaFrame? = synchronized(monitor) {
        while (!closed && audio.isEmpty() && video.isEmpty()) {
            try {
                monitor.wait()
            } catch (_: InterruptedException) {
                if (closed) return@synchronized null
            }
        }
        if (closed) return@synchronized null
        if (audio.isNotEmpty()) audio.removeFirst() else video.removeFirst()
    }

    fun close() = synchronized(monitor) {
        closed = true
        audio.clear()
        video.clear()
        monitor.notifyAll()
    }

    private fun offerAudio(frame: PendingMediaFrame): MediaOfferResult {
        var dropped = 0
        if (audio.size >= maxAudioFrames) {
            audio.removeFirst()
            dropped = 1
        }
        audio.addLast(frame)
        return MediaOfferResult(accepted = true, droppedAudioFrames = dropped)
    }

    private fun offerVideo(frame: PendingMediaFrame): MediaOfferResult {
        if (waitingForKeyframe && !frame.isKeyframe && !frame.isConfig) {
            return MediaOfferResult(
                accepted = false,
                requestKeyframe = true,
                droppedVideoFrames = 1,
            )
        }

        if (video.size >= maxVideoFrames) {
            val dropped = video.size + if (frame.isKeyframe || frame.isConfig) 0 else 1
            video.clear()
            waitingForKeyframe = !frame.isKeyframe
            if (frame.isKeyframe || frame.isConfig) video.addLast(frame)
            return MediaOfferResult(
                accepted = frame.isKeyframe || frame.isConfig,
                requestKeyframe = !frame.isKeyframe,
                droppedVideoFrames = dropped,
            )
        }

        if (frame.isKeyframe) waitingForKeyframe = false
        video.addLast(frame)
        return MediaOfferResult(accepted = true)
    }
}
