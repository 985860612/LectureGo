package com.aiyu.screenmon.streamer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import com.aiyu.screenmon.control.ControlServer
import com.aiyu.screenmon.discovery.NsdHelper
import com.aiyu.screenmon.proto.Protocol
import com.aiyu.screenmon.ui.MainActivity
import java.net.InetAddress
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/** Owns one phone capture session: screen+playback audio or camera+microphone. */
class CaptureService : Service() {
    private var projection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var cameraSource: CameraSource? = null
    private var videoEncoder: ScreenEncoder? = null
    private var audioEncoder: AudioEncoder? = null
    private var sender: UdpSender? = null
    private var control: ControlServer? = null
    private var nsd: NsdHelper? = null
    private var mode = CaptureMode.SCREEN
    private val sequence = AtomicInteger()
    @Volatile private var audioConfig: ByteArray? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (isRunning) return START_NOT_STICKY
        mode = CaptureMode.valueOf(intent?.getStringExtra(EXTRA_MODE) ?: CaptureMode.SCREEN.name)
        val serviceTypes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (mode == CaptureMode.SCREEN) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
        } else {
            // Android 10 supports typed foreground services, but camera/microphone
            // type constants were added in Android 11.
            if (mode == CaptureMode.SCREEN) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0
        }
        startForeground(NOTIFICATION_ID, notification("正在准备音视频采集"), serviceTypes)
        isRunning = true
        try {
            startCapture(intent ?: error("缺少启动参数"))
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            lastError = e.message ?: "启动失败"
            isRunning = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startCapture(intent: Intent) {
        val quality = Quality.valueOf(intent.getStringExtra(EXTRA_QUALITY) ?: Quality.STANDARD.name)
        val preferHevc = intent.getBooleanExtra(EXTRA_HEVC, true)
        val fps = 30
        val sender = UdpSender { videoEncoder?.requestKeyframe() }.also { this.sender = it }

        val dimensions: Pair<Int, Int>
        val inputSurfaceFactory: (ScreenEncoder) -> Unit
        if (mode == CaptureMode.SCREEN) {
            require(quality != Quality.UHD) { "屏幕共享最高支持 1080p" }
            val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
            @Suppress("DEPRECATION")
            val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                ?: error("缺少屏幕共享授权")
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = manager.getMediaProjection(resultCode, data)
                ?: error("无法取得屏幕共享授权")
            projectionCallback = object : MediaProjection.Callback() {
                override fun onStop() { stopSelf() }
            }.also { projection!!.registerCallback(it, Handler(Looper.getMainLooper())) }
            val metrics = resources.displayMetrics
            val scale = minOf(1.0, quality.maxDimension.toDouble() / maxOf(metrics.widthPixels, metrics.heightPixels))
            val width = (metrics.widthPixels * scale).roundToInt() and -2
            val height = (metrics.heightPixels * scale).roundToInt() and -2
            dimensions = width to height
            inputSurfaceFactory = { encoder ->
                val surface = encoder.createInputSurface()
                virtualDisplay = projection!!.createVirtualDisplay(
                    "CourseRecMobile",
                    width,
                    height,
                    metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    surface,
                    null,
                    null,
                )
            }
        } else {
            val cameraId = intent.getStringExtra(EXTRA_CAMERA_ID) ?: error("未选择摄像头")
            val size = CaptureCapabilities.chooseCameraSize(this, cameraId, quality, preferHevc)
                ?: error("当前摄像头或编码器不支持 ${quality.label}")
            if (quality == Quality.UHD && (maxOf(size.width, size.height) < 3840 || minOf(size.width, size.height) < 2160)) {
                error("当前摄像头或编码器不支持 4K，未自动降级")
            }
            dimensions = size.width to size.height
            inputSurfaceFactory = { encoder ->
                val surface = encoder.createInputSurface()
                cameraSource = CameraSource(this, cameraId, size, fps, surface) { message ->
                    lastError = message
                    stopSelf()
                }.also { it.start() }
            }
        }

        val mime = if (preferHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        if (!ScreenEncoder.supportsSize(mime, dimensions.first, dimensions.second, fps)) {
            error("编码器不支持 ${dimensions.first}×${dimensions.second} ${if (preferHevc) "H.265" else "H.264"}")
        }
        val encoder = ScreenEncoder(
            dimensions.first,
            dimensions.second,
            quality.bitrate(preferHevc),
            fps,
            preferHevc,
        ) { buffer, size, ptsUs, protoFlags -> send(buffer, size, ptsUs, protoFlags) }
        videoEncoder = encoder
        inputSurfaceFactory(encoder)
        encoder.start()

        val audio = AudioEncoder(
            mode,
            projection,
            onFrame = { data, ptsUs, protoFlags -> send(data, data.size, ptsUs, protoFlags) },
            onError = { message -> lastError = message },
        ).also { it.start() }
        audioEncoder = audio

        control = ControlServer(Protocol.DEFAULT_CONTROL_PORT, object : ControlServer.Listener {
            override fun videoSize() = dimensions
            override fun videoCodec() = encoder.codec
            override fun sourceKind() = mode.wireValue
            override fun audioSampleRate() = audio.sampleRate
            override fun audioChannels() = audio.channels
            override fun onTargetAdded(addr: InetAddress, mediaPort: Int) {
                sender.addTarget(Target(addr, mediaPort))
                audioConfig?.let {
                    send(
                        it,
                        it.size,
                        System.currentTimeMillis() * 1000,
                        Protocol.FLAG_AUDIO or Protocol.FLAG_CONFIG,
                    )
                }
            }
            override fun onTargetRemoved(addr: InetAddress, mediaPort: Int) = sender.removeTarget(Target(addr, mediaPort))
            override fun onKeyframeRequested() = encoder.requestKeyframe()
        }).also { it.start() }
        nsd = NsdHelper(this).also {
            it.registerStreamer("开讲-${Build.MODEL}", Protocol.DEFAULT_CONTROL_PORT, mode.wireValue)
        }
        updateNotification("${mode.label} · ${dimensions.first}×${dimensions.second} · 音频已开启")
    }

    private fun send(buffer: ByteBuffer, size: Int, ptsUs: Long, flags: Int) {
        val shouldCacheAudioConfig = flags and Protocol.FLAG_AUDIO != 0 &&
            flags and Protocol.FLAG_CONFIG != 0
        if (!shouldCacheAudioConfig && sender?.hasTargets() != true) return
        val bytes = ByteArray(size)
        buffer.get(bytes)
        send(bytes, size, ptsUs, flags)
    }

    private fun send(bytes: ByteArray, size: Int, ptsUs: Long, flags: Int) {
        if (flags and Protocol.FLAG_AUDIO != 0 && flags and Protocol.FLAG_CONFIG != 0) {
            audioConfig = bytes.copyOf(size)
        }
        val currentSender = sender ?: return
        if (!currentSender.hasTargets()) return
        val payload = if (size == bytes.size) bytes else bytes.copyOf(size)
        currentSender.enqueue(payload, sequence.getAndIncrement(), flags, ptsUs)
    }

    override fun onDestroy() {
        isRunning = false
        nsd?.unregister()
        control?.stop()
        audioEncoder?.stop()
        cameraSource?.stop()
        virtualDisplay?.release()
        projectionCallback?.let { callback -> projection?.unregisterCallback(callback) }
        projection?.stop()
        videoEncoder?.release()
        sender?.close()
        nsd = null
        control = null
        audioEncoder = null
        cameraSource = null
        virtualDisplay = null
        projection = null
        projectionCallback = null
        videoEncoder = null
        sender = null
        super.onDestroy()
    }

    private fun notification(text: String) = NotificationCompat.Builder(this, CHANNEL)
        .setSmallIcon(android.R.drawable.presence_video_online)
        .setContentTitle("开讲移动端")
        .setContentText(text)
        .setOngoing(true)
        .setContentIntent(
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        )
        .build()

    private fun updateNotification(text: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, notification(text))
    }

    override fun onCreate() {
        super.onCreate()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
            NotificationChannel(CHANNEL, "开讲音视频共享", NotificationManager.IMPORTANCE_LOW)
        )
    }

    companion object {
        const val ACTION_STOP = "courserec.mobile.STOP"
        const val EXTRA_MODE = "mode"
        const val EXTRA_QUALITY = "quality"
        const val EXTRA_HEVC = "hevc"
        const val EXTRA_CAMERA_ID = "cameraId"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        @Volatile var isRunning = false
        @Volatile var lastError: String? = null
        private const val CHANNEL = "courserec-mobile"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "CaptureService"
    }
}
