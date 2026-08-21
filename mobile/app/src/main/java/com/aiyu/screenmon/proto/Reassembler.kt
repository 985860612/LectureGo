package com.aiyu.screenmon.proto

/** A fully reassembled access unit ready to feed a decoder. */
class Frame(
    val seq: Int,
    val flags: Int,
    val ptsUs: Long,
    val data: ByteArray,
) {
    val isKeyframe: Boolean get() = flags and Protocol.FLAG_KEYFRAME != 0
    val isConfig: Boolean get() = flags and Protocol.FLAG_CONFIG != 0
}

/**
 * Reassembles UDP fragments back into [Frame]s for a single stream/source.
 *
 * Low-latency policy: emit a frame the instant its last fragment arrives, never
 * re-order across frames, and drop frames that fall behind the newest by more
 * than [window] (their missing fragments are lost — the monitor then asks the
 * streamer for a keyframe). Not thread-safe; call from one receive thread.
 */
class Reassembler(private val window: Int = 8) {

    private class Pending(val fragCount: Int, val flags: Int, val ptsUs: Long) {
        val parts = arrayOfNulls<ByteArray>(fragCount)
        var received = 0
        var totalLen = 0
    }

    private val pending = HashMap<Int, Pending>()
    private var lastEmitted = -1

    var droppedFrames = 0
        private set

    /**
     * Feed one fragment. [payload] holds the raw datagram; the media bytes start
     * at [payloadOff] and run for [PacketHeader.payloadLen]. Returns a [Frame]
     * when this fragment completes one, else null.
     */
    fun onFragment(h: PacketHeader, payload: ByteArray, payloadOff: Int): Frame? {
        if (h.frameSeq <= lastEmitted) return null            // already emitted / stale
        if (h.fragCount <= 0 || h.fragIndex >= h.fragCount) return null

        var p = pending[h.frameSeq]
        if (p == null) {
            p = Pending(h.fragCount, h.flags, h.ptsUs)
            pending[h.frameSeq] = p
            evictStale(h.frameSeq)
        }
        if (h.fragCount != p.parts.size) return null          // inconsistent fragmentation

        if (p.parts[h.fragIndex] == null) {
            val b = ByteArray(h.payloadLen)
            System.arraycopy(payload, payloadOff, b, 0, h.payloadLen)
            p.parts[h.fragIndex] = b
            p.received++
            p.totalLen += h.payloadLen
        }

        if (p.received == p.fragCount) {
            pending.remove(h.frameSeq)
            lastEmitted = h.frameSeq
            // any still-pending frame older than the one we just emitted is now unusable
            val it = pending.keys.iterator()
            while (it.hasNext()) {
                if (it.next() <= lastEmitted) {
                    it.remove()
                    droppedFrames++
                }
            }
            val out = ByteArray(p.totalLen)
            var o = 0
            for (part in p.parts) {
                System.arraycopy(part!!, 0, out, o, part.size)
                o += part.size
            }
            return Frame(h.frameSeq, p.flags, p.ptsUs, out)
        }
        return null
    }

    /** Drop incomplete frames that have fallen too far behind the newest seq. */
    private fun evictStale(newestSeq: Int) {
        if (pending.size <= window) return
        val threshold = newestSeq - window
        val it = pending.entries.iterator()
        while (it.hasNext()) {
            if (it.next().key < threshold) {
                it.remove()
                droppedFrames++
            }
        }
    }
}
