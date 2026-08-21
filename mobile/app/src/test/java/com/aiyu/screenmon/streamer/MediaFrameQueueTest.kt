package com.aiyu.screenmon.streamer

import com.aiyu.screenmon.proto.Protocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaFrameQueueTest {
    private fun frame(sequence: Int, flags: Int = 0) = PendingMediaFrame(
        data = byteArrayOf(sequence.toByte()),
        sequence = sequence,
        flags = flags,
        ptsUs = sequence * 1_000L,
    )

    @Test fun audioHasPriorityOverQueuedVideo() {
        val queue = MediaFrameQueue()
        queue.offer(frame(1))
        queue.offer(frame(2, Protocol.FLAG_AUDIO))

        assertEquals(2, queue.take()?.sequence)
        assertEquals(1, queue.take()?.sequence)
        queue.close()
    }

    @Test fun overflowDiscardsPredictionChainAndRequestsKeyframe() {
        val queue = MediaFrameQueue(maxVideoFrames = 2)
        assertTrue(queue.offer(frame(1)).accepted)
        assertTrue(queue.offer(frame(2)).accepted)

        val overflow = queue.offer(frame(3))
        assertFalse(overflow.accepted)
        assertTrue(overflow.requestKeyframe)
        assertEquals(3, overflow.droppedVideoFrames)

        val rejected = queue.offer(frame(4))
        assertFalse(rejected.accepted)
        assertTrue(rejected.requestKeyframe)

        val keyframe = queue.offer(frame(5, Protocol.FLAG_KEYFRAME))
        assertTrue(keyframe.accepted)
        assertEquals(5, queue.take()?.sequence)
        queue.close()
    }

    @Test fun closeDropsPendingFramesAndUnblocksConsumer() {
        val queue = MediaFrameQueue()
        queue.offer(frame(1))
        queue.close()
        assertNull(queue.take())
    }
}
