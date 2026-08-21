package com.aiyu.screenmon.streamer

import android.util.Log
import com.aiyu.screenmon.net.LanIface
import com.aiyu.screenmon.proto.Fragmenter
import com.aiyu.screenmon.proto.Protocol
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicLong

/** Identifies one monitor's media sink. */
data class Target(val addr: InetAddress, val port: Int)

/**
 * Sends UDP media fragments to every registered monitor target. One shared
 * socket; targets are added/removed as monitors join/leave via the control
 * channel. Encoder callbacks only enqueue frames; one worker owns fragmentation and socket I/O.
 */
class UdpSender(private val onVideoBackpressure: () -> Unit) {
    private val socket = DatagramSocket(null)   // unbound; bound to the right local NIC on first target
    @Volatile private var bound = false
    private val targets = CopyOnWriteArraySet<Target>()
    private val packet = DatagramPacket(ByteArray(0), 0)
    private val mediaQueue = MediaFrameQueue()
    private val sentBytes = AtomicLong()
    private val droppedVideo = AtomicLong()
    private val droppedAudio = AtomicLong()
    private val lastKeyframeRequestAt = AtomicLong()
    private val worker = Thread(::sendLoop, "media-udp-send").also {
        it.isDaemon = true
        it.start()
    }

    fun addTarget(t: Target) {
        ensureBound(t.addr)
        targets.add(t); Log.i(TAG, "target+ $t (${targets.size})")
    }

    /**
     * Bind the source NIC once, based on the first target. For a LAN monitor
     * (private IP) bind to the matching local interface (USB/WiFi, never cellular).
     * CourseRec is LAN-only. Public targets remain unbound and follow Android's
     * default route, but no relay protocol or public discovery is implemented.
     */
    private fun ensureBound(addr: InetAddress) {
        if (bound) return
        bound = true
        val ip = addr.hostAddress ?: ""
        if (!LanIface.isPrivate(ip)) { Log.i(TAG, "sender unbound (public $ip)"); return }
        try {
            val local = LanIface.localAddressForTarget(ip)
            socket.bind(InetSocketAddress(local, 0))
            Log.i(TAG, "sender bound to ${local?.hostAddress ?: "*"}")
        } catch (e: Exception) {
            Log.w(TAG, "sender bind failed: $e")
        }
    }

    fun removeTarget(t: Target) { targets.remove(t); Log.i(TAG, "target- $t (${targets.size})") }
    fun hasTargets() = targets.isNotEmpty()

    /** Encoder callbacks enqueue whole access units and return without touching the socket. */
    fun enqueue(data: ByteArray, sequence: Int, flags: Int, ptsUs: Long) {
        if (targets.isEmpty()) return
        val result = mediaQueue.offer(PendingMediaFrame(data, sequence, flags, ptsUs))
        if (result.droppedVideoFrames > 0) droppedVideo.addAndGet(result.droppedVideoFrames.toLong())
        if (result.droppedAudioFrames > 0) droppedAudio.addAndGet(result.droppedAudioFrames.toLong())
        if (result.requestKeyframe) {
            val now = System.currentTimeMillis()
            val previous = lastKeyframeRequestAt.get()
            if (now - previous >= KEYFRAME_REQUEST_INTERVAL_MS &&
                lastKeyframeRequestAt.compareAndSet(previous, now)
            ) {
                onVideoBackpressure()
            }
        }
    }

    private fun sendLoop() {
        val scratch = ByteArray(Protocol.HEADER_SIZE + Protocol.MAX_PAYLOAD)
        var lastReportAt = System.currentTimeMillis()
        while (true) {
            val frame = mediaQueue.take() ?: break
            Fragmenter.fragment(
                frame.data,
                frame.data.size,
                frame.sequence,
                frame.flags,
                frame.ptsUs,
                scratch,
            ) { buf, len -> sendDatagram(buf, len) }

            val now = System.currentTimeMillis()
            if (now - lastReportAt >= 5_000) {
                Log.i(
                    TAG,
                    "media sent=${sentBytes.getAndSet(0) / 1024}KiB/5s " +
                        "dropVideo=${droppedVideo.get()} dropAudio=${droppedAudio.get()}",
                )
                lastReportAt = now
            }
        }
    }

    /** Send one fragment (bytes 0 until [len] of [buf]) to all current targets. */
    private fun sendDatagram(buf: ByteArray, len: Int) {
        for (t in targets) {
            try {
                packet.setData(buf, 0, len)
                packet.address = t.addr
                packet.port = t.port
                socket.send(packet)
                sentBytes.addAndGet(len.toLong())
            } catch (e: Exception) {
                Log.w(TAG, "send to $t failed: $e")
            }
        }
    }

    fun close() {
        mediaQueue.close()
        worker.interrupt()
        try { worker.join(500) } catch (_: InterruptedException) {}
        try { socket.close() } catch (_: Exception) {}
        targets.clear()
    }

    companion object {
        private const val TAG = "UdpSender"
        private const val KEYFRAME_REQUEST_INTERVAL_MS = 350L
    }
}
