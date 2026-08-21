package com.aiyu.screenmon.control

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Streamer-side TCP control endpoint. Each monitor opens one connection and:
 *   - sends `HELLO <mediaPort>`  -> server replies `OK <w> <h>` and registers the
 *     monitor's (ip, mediaPort) as a UDP media target
 *   - sends `KEYFRAME`           -> server asks the encoder for a sync frame
 *   - closes / sends `BYE`       -> target removed
 */
class ControlServer(
    private val port: Int,
    private val listener: Listener,
) {
    interface Listener {
        /** Current encode dimensions to advertise to a joining monitor. */
        fun videoSize(): Pair<Int, Int>
        /** Codec token ("h264"/"h265") so the monitor configures the right decoder. */
        fun videoCodec(): String
        fun sourceKind(): String
        fun audioSampleRate(): Int
        fun audioChannels(): Int
        fun onTargetAdded(addr: InetAddress, mediaPort: Int)
        fun onTargetRemoved(addr: InetAddress, mediaPort: Int)
        fun onKeyframeRequested()
    }

    @Volatile private var running = false
    private var server: ServerSocket? = null

    fun start() {
        if (running) return
        running = true
        thread(name = "ctrl-accept") {
            try {
                val s = ServerSocket()
                s.reuseAddress = true                // survive a lingering prior socket
                s.bind(InetSocketAddress(port))
                server = s
                Log.i(TAG, "control server on :$port")
                while (running) {
                    val client = try { s.accept() } catch (e: Exception) { if (running) Log.w(TAG, "accept: $e"); break }
                    thread(name = "ctrl-conn") { handle(client) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "server failed: $e")
            }
        }
    }

    private fun handle(sock: Socket) {
        val addr = sock.inetAddress
        var mediaPort = -1
        try {
            sock.tcpNoDelay = true
            val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
            val writer = sock.getOutputStream()
            while (running) {
                val line = reader.readLine() ?: break
                val parts = line.trim().split(" ")
                when (parts[0].uppercase()) {
                    "HELLO" -> {
                        mediaPort = parts.getOrNull(1)?.toIntOrNull() ?: continue
                        val (w, h) = listener.videoSize()
                        writer.write(
                            (
                                "OK $w $h ${listener.videoCodec()} ${listener.sourceKind()} " +
                                    "aac ${listener.audioSampleRate()} ${listener.audioChannels()}\n"
                            ).toByteArray()
                        )
                        writer.flush()
                        listener.onTargetAdded(addr, mediaPort)
                        Log.i(TAG, "monitor joined ${addr.hostAddress}:$mediaPort")
                    }
                    "KEYFRAME" -> listener.onKeyframeRequested()
                    "PING" -> {
                        // clock-offset probe: echo the caller's t0 + our wall-clock now
                        val t0 = parts.getOrNull(1) ?: "0"
                        writer.write("PONG $t0 ${System.currentTimeMillis()}\n".toByteArray())
                        writer.flush()
                    }
                    "BYE" -> break
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "conn ${addr.hostAddress}: $e")
        } finally {
            if (mediaPort >= 0) listener.onTargetRemoved(addr, mediaPort)
            try { sock.close() } catch (_: Exception) {}
        }
    }

    fun stop() {
        running = false
        try { server?.close() } catch (_: Exception) {}
    }

    companion object { private const val TAG = "ControlServer" }
}
