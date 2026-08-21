package com.aiyu.screenmon.streamer

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Size

enum class CaptureMode(val wireValue: String, val label: String) {
    SCREEN("screen", "共享屏幕"),
    CAMERA("camera", "使用摄像头"),
}

enum class Quality(val label: String, val maxDimension: Int, val h264Bitrate: Int) {
    SMOOTH("流畅 540p", 960, 2_500_000),
    STANDARD("标准 720p", 1280, 4_000_000),
    HD("高清 1080p", 1920, 12_000_000),
    UHD("超清 4K", 3840, 32_000_000);

    fun bitrate(hevc: Boolean): Int = if (hevc) (h264Bitrate * 0.625).toInt() else h264Bitrate
}

data class CameraOption(val id: String, val label: String, val frontFacing: Boolean)

object CaptureCapabilities {
    fun cameras(context: Context): List<CameraOption> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return manager.cameraIdList.mapNotNull { id ->
            val c = manager.getCameraCharacteristics(id)
            val facing = c.get(CameraCharacteristics.LENS_FACING) ?: return@mapNotNull null
            CameraOption(
                id,
                if (facing == CameraCharacteristics.LENS_FACING_FRONT) "前置摄像头" else "后置摄像头",
                facing == CameraCharacteristics.LENS_FACING_FRONT,
            )
        }.sortedBy { it.frontFacing }
    }

    fun chooseCameraSize(context: Context, cameraId: String, quality: Quality, hevc: Boolean): Size? {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val map = manager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null
        val mime = if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        return map.getOutputSizes(MediaCodec::class.java)
            ?.filter { size ->
                val longest = maxOf(size.width, size.height)
                val shortest = minOf(size.width, size.height)
                val minFrameDuration = map.getOutputMinFrameDuration(MediaCodec::class.java, size)
                longest <= quality.maxDimension && shortest * 16 >= longest * 9 &&
                    (minFrameDuration == 0L || minFrameDuration <= 1_000_000_000L / 30) &&
                    ScreenEncoder.supportsSize(mime, size.width, size.height, 30)
            }
            ?.maxByOrNull { it.width.toLong() * it.height }
    }

    fun supports4K(context: Context, cameraId: String, hevc: Boolean): Boolean {
        val size = chooseCameraSize(context, cameraId, Quality.UHD, hevc) ?: return false
        return maxOf(size.width, size.height) >= 3840 && minOf(size.width, size.height) >= 2160
    }
}
