package com.aiyu.screenmon.proto

/**
 * Splits one encoded access unit (frame) into MTU-sized UDP datagrams, each
 * prefixed with a [PacketHeader]. Pure/allocating-light: reuses a single output
 * buffer per packet via [emit].
 */
object Fragmenter {

    /**
     * Fragment [frame] (length [frameLen]) into packets and hand each one to [emit]
     * as (buffer, length). The buffer passed to [emit] is reused across calls, so
     * the callback must send/copy it before returning.
     */
    inline fun fragment(
        frame: ByteArray,
        frameLen: Int,
        frameSeq: Int,
        flags: Int,
        ptsUs: Long,
        scratch: ByteArray,
        emit: (buf: ByteArray, len: Int) -> Unit,
    ) {
        val maxPayload = Protocol.MAX_PAYLOAD
        val fragCount = ((frameLen + maxPayload - 1) / maxPayload).coerceAtLeast(1)
        var off = 0
        var idx = 0
        while (idx < fragCount) {
            val payload = minOf(maxPayload, frameLen - off)
            val header = PacketHeader(flags, frameSeq, fragCount, idx, payload, ptsUs)
            header.writeInto(scratch)
            System.arraycopy(frame, off, scratch, Protocol.HEADER_SIZE, payload)
            emit(scratch, Protocol.HEADER_SIZE + payload)
            off += payload
            idx++
        }
    }
}
