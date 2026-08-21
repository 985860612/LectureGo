package com.aiyu.screenmon.proto

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Fixed 24-byte big-endian header prefixed to every UDP media fragment.
 *
 * Layout:
 * ```
 *  0  magic (0xAB)
 *  1  version (1)
 *  2  flags    (FLAG_KEYFRAME | FLAG_CONFIG)
 *  3  reserved
 *  4  frameSeq  (int32)   monotonically increasing per access unit
 *  8  fragCount (uint16)  total fragments for this frame
 * 10  fragIndex (uint16)  0-based index of this fragment
 * 12  payloadLen(uint16)  bytes of media payload following the header
 * 14  ptsUs     (int64)   presentation timestamp, microseconds
 * 22  reserved  (uint16)
 * ```
 */
data class PacketHeader(
    val flags: Int,
    val frameSeq: Int,
    val fragCount: Int,
    val fragIndex: Int,
    val payloadLen: Int,
    val ptsUs: Long,
) {
    val isKeyframe: Boolean get() = flags and Protocol.FLAG_KEYFRAME != 0
    val isConfig: Boolean get() = flags and Protocol.FLAG_CONFIG != 0

    /** Write this header into [dst] at offset 0. [dst] must be >= HEADER_SIZE. */
    fun writeInto(dst: ByteArray) {
        val bb = ByteBuffer.wrap(dst).order(ByteOrder.BIG_ENDIAN)
        bb.put(Protocol.MAGIC)
        bb.put(Protocol.VERSION)
        bb.put(flags.toByte())
        bb.put(0)
        bb.putInt(frameSeq)
        bb.putShort(fragCount.toShort())
        bb.putShort(fragIndex.toShort())
        bb.putShort(payloadLen.toShort())
        bb.putLong(ptsUs)
        bb.putShort(0)
    }

    companion object {
        /** Parse a header from [src] starting at [off]; returns null if magic/version mismatch or too short. */
        fun parse(src: ByteArray, off: Int = 0, len: Int = src.size - off): PacketHeader? {
            if (len < Protocol.HEADER_SIZE) return null
            val bb = ByteBuffer.wrap(src, off, len).order(ByteOrder.BIG_ENDIAN)
            if (bb.get() != Protocol.MAGIC) return null
            if (bb.get() != Protocol.VERSION) return null
            val flags = bb.get().toInt() and 0xFF
            bb.get() // reserved
            val frameSeq = bb.getInt()
            val fragCount = bb.getShort().toInt() and 0xFFFF
            val fragIndex = bb.getShort().toInt() and 0xFFFF
            val payloadLen = bb.getShort().toInt() and 0xFFFF
            val ptsUs = bb.getLong()
            return PacketHeader(flags, frameSeq, fragCount, fragIndex, payloadLen, ptsUs)
        }
    }
}
