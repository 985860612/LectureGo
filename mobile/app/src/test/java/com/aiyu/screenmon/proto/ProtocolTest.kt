package com.aiyu.screenmon.proto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {

    private fun makeFrame(seed: Int, len: Int) = ByteArray(len) { ((it + seed) and 0xFF).toByte() }

    /** Carry one frame through Fragmenter -> packets -> Reassembler, in given packet order. */
    private fun roundTrip(frame: ByteArray, seq: Int, flags: Int, r: Reassembler, order: (List<ByteArray>) -> List<ByteArray>): Frame? {
        val packets = ArrayList<ByteArray>()
        val scratch = ByteArray(Protocol.HEADER_SIZE + Protocol.MAX_PAYLOAD)
        Fragmenter.fragment(frame, frame.size, seq, flags, seq * 1000L, scratch) { buf, len ->
            packets.add(buf.copyOf(len))
        }
        var emitted: Frame? = null
        for (pkt in order(packets)) {
            val h = PacketHeader.parse(pkt)!!
            val f = r.onFragment(h, pkt, Protocol.HEADER_SIZE)
            if (f != null) emitted = f
        }
        return emitted
    }

    @Test fun headerRoundTrips() {
        val buf = ByteArray(Protocol.HEADER_SIZE)
        val h = PacketHeader(Protocol.FLAG_KEYFRAME, 42, 7, 3, 1100, 123_456L)
        h.writeInto(buf)
        val p = PacketHeader.parse(buf)!!
        assertEquals(42, p.frameSeq)
        assertEquals(7, p.fragCount)
        assertEquals(3, p.fragIndex)
        assertEquals(1100, p.payloadLen)
        assertEquals(123_456L, p.ptsUs)
        assertTrue(p.isKeyframe)
    }

    @Test fun parseRejectsGarbage() {
        assertNull(PacketHeader.parse(ByteArray(5)))
        assertNull(PacketHeader.parse(ByteArray(Protocol.HEADER_SIZE)))  // magic 0
    }

    @Test fun singleFragmentFrame() {
        val r = Reassembler()
        val frame = makeFrame(1, 300)
        val out = roundTrip(frame, 0, Protocol.FLAG_KEYFRAME, r) { it }
        assertNotNull(out)
        assertArrayEquals(frame, out!!.data)
        assertTrue(out.isKeyframe)
    }

    @Test fun audioFlagsSurviveFragmentation() {
        val r = Reassembler()
        val out = roundTrip(
            makeFrame(9, 64),
            2,
            Protocol.FLAG_AUDIO or Protocol.FLAG_CONFIG,
            r,
        ) { it }
        assertNotNull(out)
        assertEquals(Protocol.FLAG_AUDIO or Protocol.FLAG_CONFIG, out!!.flags)
    }

    @Test fun multiFragmentInOrder() {
        val r = Reassembler()
        val frame = makeFrame(2, Protocol.MAX_PAYLOAD * 3 + 17)
        val out = roundTrip(frame, 5, 0, r) { it }
        assertNotNull(out)
        assertArrayEquals(frame, out!!.data)
    }

    @Test fun multiFragmentReordered() {
        val r = Reassembler()
        val frame = makeFrame(3, Protocol.MAX_PAYLOAD * 4)
        val out = roundTrip(frame, 9, 0, r) { it.reversed() }
        assertNotNull(out)
        assertArrayEquals(frame, out!!.data)
    }

    @Test fun lostFragmentYieldsNoFrame() {
        val r = Reassembler()
        val frame = makeFrame(4, Protocol.MAX_PAYLOAD * 3)
        val out = roundTrip(frame, 11, 0, r) { it.drop(1) }  // drop second fragment
        assertNull(out)
    }

    @Test fun staleFrameDroppedAfterNewerEmitted() {
        val r = Reassembler(window = 8)
        // frame 100 loses a fragment; frames 101..110 arrive whole -> 100 must be evicted, never emitted
        roundTrip(makeFrame(7, Protocol.MAX_PAYLOAD * 2), 100, 0, r) { it.drop(1) }
        for (seq in 101..110) {
            val out = roundTrip(makeFrame(seq, 200), seq, 0, r) { it }
            assertNotNull(out)
            assertEquals(seq, out!!.seq)
        }
        assertTrue("expected stale frame 100 to be dropped", r.droppedFrames >= 1)
    }
}
