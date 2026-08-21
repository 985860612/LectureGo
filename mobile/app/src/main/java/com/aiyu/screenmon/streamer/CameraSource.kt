package com.aiyu.screenmon.streamer

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.util.Size
import android.view.Surface

/** Camera2 source that writes directly into MediaCodec's input surface. */
class CameraSource(
    private val context: Context,
    private val cameraId: String,
    private val size: Size,
    private val fps: Int,
    private val encoderSurface: Surface,
    private val onError: (String) -> Unit,
) {
    private val thread = HandlerThread("camera-source").also { it.start() }
    private val handler = Handler(thread.looper)
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null

    @SuppressLint("MissingPermission")
    fun start() {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                device = camera
                val callback = object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(created: CameraCaptureSession) {
                        session = created
                        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                            addTarget(encoderSurface)
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                            set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(fps, fps))
                        }.build()
                        created.setRepeatingRequest(request, null, handler)
                    }

                    override fun onConfigureFailed(created: CameraCaptureSession) {
                        onError("摄像头无法建立 ${size.width}×${size.height} 采集会话")
                    }
                }
                camera.createCaptureSession(
                    SessionConfiguration(
                        SessionConfiguration.SESSION_REGULAR,
                        listOf(OutputConfiguration(encoderSurface)),
                        { command -> handler.post(command) },
                        callback,
                    )
                )
            }

            override fun onDisconnected(camera: CameraDevice) {
                onError("摄像头已断开")
                camera.close()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                onError("摄像头启动失败（$error）")
                camera.close()
            }
        }, handler)
    }

    fun stop() {
        try { session?.stopRepeating() } catch (_: Exception) {}
        session?.close()
        device?.close()
        session = null
        device = null
        encoderSurface.release()
        thread.quitSafely()
    }
}
