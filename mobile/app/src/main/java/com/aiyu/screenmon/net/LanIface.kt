package com.aiyu.screenmon.net

import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * Picks the right *local* IPv4 to source our sockets from, so traffic goes out
 * the intended interface regardless of which network Android considers default.
 *
 * Why bind by local address instead of [android.net.ConnectivityManager]
 * .bindProcessToNetwork: USB tethering links and a streamer's own hotspot are
 * not always exposed as a bindable [android.net.Network], but they always have a
 * local interface address. Binding the socket's source address makes the OS route
 * table choose the matching interface — this fixes both the "socket went out
 * cellular" WiFi bug and the USB-direct case with one mechanism.
 *
 * Preference order: wired/USB (usb, rndis, eth) over WiFi (wlan) over anything
 * else, always excluding cellular (rmnet) and virtual NICs.
 */
object LanIface {
    private const val TAG = "LanIface"

    private fun isExcluded(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("rmnet") || n.startsWith("utun") || n.startsWith("docker") ||
            n.startsWith("br-") || n.startsWith("veth") || n.contains("tailscale") ||
            n.startsWith("dummy") || n.startsWith("ip6tnl")
    }

    private fun rank(name: String): Int {
        val n = name.lowercase()
        return when {
            n.startsWith("usb") || n.startsWith("rndis") || n.startsWith("eth") || n.startsWith("ncm") -> 3
            n.startsWith("wlan") || n.startsWith("ap") -> 2
            else -> 1
        }
    }

    /** Best LAN-side local IPv4, wired/USB preferred over WiFi. */
    fun bestLanAddress(): InetAddress? = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.isVirtual && !isExcluded(it.name) }
            .flatMap { ni -> ni.inetAddresses.toList().filterIsInstance<Inet4Address>().map { ni to it } }
            .filterNot { it.second.isLoopbackAddress }
            .maxByOrNull { rank(it.first.name) }
            ?.second
            ?.also { Log.i(TAG, "bestLanAddress=${it.hostAddress}") }
    } catch (e: Exception) {
        Log.w(TAG, "bestLanAddress failed: $e"); null
    }

    /**
     * Local IPv4 on the same subnet as [targetIp] — the precise source address to
     * reach that peer. Falls back to [bestLanAddress] when no subnet matches.
     */
    fun localAddressForTarget(targetIp: String): InetAddress? {
        val target = try { InetAddress.getByName(targetIp) } catch (e: Exception) { return bestLanAddress() }
        if (target !is Inet4Address) return bestLanAddress()
        val tb = target.address
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                if (!ni.isUp || ni.isLoopback || ni.isVirtual || isExcluded(ni.name)) continue
                for (ia in ni.interfaceAddresses) {
                    val addr = ia.address
                    if (addr !is Inet4Address) continue
                    if (sameSubnet(addr.address, tb, ia.networkPrefixLength.toInt())) {
                        Log.i(TAG, "localAddressForTarget($targetIp)=${addr.hostAddress} via ${ni.name}")
                        return addr
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "localAddressForTarget failed: $e")
        }
        return bestLanAddress()
    }

    /** True for LAN/loopback/link-local targets; false for public (e.g. relay) IPs. */
    fun isPrivate(ip: String): Boolean = try {
        val a = InetAddress.getByName(ip)
        a.isSiteLocalAddress || a.isLinkLocalAddress || a.isLoopbackAddress
    } catch (e: Exception) {
        false
    }

    private fun sameSubnet(a: ByteArray, b: ByteArray, prefixLen: Int): Boolean {
        if (a.size != b.size) return false
        var bits = prefixLen
        var i = 0
        while (bits > 0 && i < a.size) {
            val take = if (bits >= 8) 8 else bits
            val mask = (0xFF shl (8 - take)) and 0xFF
            if ((a[i].toInt() and mask) != (b[i].toInt() and mask)) return false
            bits -= take
            i++
        }
        return true
    }
}
