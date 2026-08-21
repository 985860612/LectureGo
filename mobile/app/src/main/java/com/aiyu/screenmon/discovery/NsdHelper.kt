package com.aiyu.screenmon.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import com.aiyu.screenmon.proto.Protocol

/**
 * Registers the CourseRec mobile source through Android NSD (mDNS/Bonjour).
 */
class NsdHelper(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var regListener: NsdManager.RegistrationListener? = null

    // ---- streamer side ----
    fun registerStreamer(name: String, controlPort: Int, sourceKind: String) {
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = Protocol.NSD_SERVICE_TYPE
            port = controlPort
            setAttribute("app", "courserec")
            setAttribute("source", sourceKind)
            setAttribute("protocol", "2")
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(s: NsdServiceInfo) { Log.i(TAG, "registered ${s.serviceName}") }
            override fun onRegistrationFailed(s: NsdServiceInfo, code: Int) { Log.e(TAG, "reg failed $code") }
            override fun onServiceUnregistered(s: NsdServiceInfo) {}
            override fun onUnregistrationFailed(s: NsdServiceInfo, code: Int) {}
        }
        regListener = l
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun unregister() {
        regListener?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        regListener = null
    }

    companion object { private const val TAG = "NsdHelper" }
}
