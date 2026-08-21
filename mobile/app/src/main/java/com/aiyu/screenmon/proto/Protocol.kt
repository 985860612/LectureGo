package com.aiyu.screenmon.proto

/**
 * Wire constants shared by streamer (sender) and monitor (receiver).
 *
 * Media path is UDP with a fixed binary header per fragment. Control path is a
 * line-based TCP channel (see [com.aiyu.screenmon.control.ControlChannel]).
 */
object Protocol {
    const val MAGIC: Byte = 0xAB.toByte()
    const val VERSION: Byte = 1

    /** UDP header size in bytes. Keep payload + header under the LAN MTU. */
    const val HEADER_SIZE = 24

    /** Max media payload per UDP packet; header + payload stays < 1300 to dodge IP fragmentation. */
    const val MAX_PAYLOAD = 1200

    // ---- frame flags (1 byte bitfield in the header) ----
    const val FLAG_KEYFRAME = 0x01
    const val FLAG_CONFIG = 0x02 // codec config (SPS/PPS), feed to decoder with BUFFER_FLAG_CODEC_CONFIG
    const val FLAG_AUDIO = 0x04

    /** Default control TCP port the streamer listens on while capturing. */
    const val DEFAULT_CONTROL_PORT = 6060

    /** NSD service type used for LAN auto-discovery of streamers. */
    const val NSD_SERVICE_TYPE = "_screenmon._tcp."

    // video codec tokens carried in control messages (HELLO/OK/PUBLISH)
    const val CODEC_H264 = "h264"
    const val CODEC_H265 = "h265"
    const val AUDIO_CODEC_AAC = "aac"
    const val SOURCE_SCREEN = "screen"
    const val SOURCE_CAMERA = "camera"

}
