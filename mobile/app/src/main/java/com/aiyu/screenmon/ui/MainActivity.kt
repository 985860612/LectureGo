package com.aiyu.screenmon.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.aiyu.screenmon.net.LanIface
import com.aiyu.screenmon.streamer.CameraOption
import com.aiyu.screenmon.streamer.CaptureCapabilities
import com.aiyu.screenmon.streamer.CaptureMode
import com.aiyu.screenmon.streamer.CaptureService
import com.aiyu.screenmon.streamer.Quality
import com.aiyu.screenmon.streamer.ScreenEncoder
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { ScreenMonTheme { MobileSourceScreen() } }
    }
}

@Composable
private fun MobileSourceScreen() {
    val ctx = LocalContext.current as ComponentActivity
    val cameras = remember { CaptureCapabilities.cameras(ctx) }
    var mode by remember { mutableStateOf(CaptureMode.SCREEN) }
    var quality by remember { mutableStateOf(Quality.STANDARD) }
    val hevcAvailable = remember { ScreenEncoder.hasEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC) }
    var hevc by remember { mutableStateOf(hevcAvailable) }
    var selectedCamera by remember { mutableStateOf(cameras.firstOrNull()) }
    var streaming by remember { mutableStateOf(CaptureService.isRunning) }
    var pendingMode by remember { mutableStateOf(mode) }
    val ip = remember { LanIface.bestLanAddress()?.hostAddress ?: "未连接局域网" }

    fun startService(resultCode: Int = 0, resultData: Intent? = null) {
        val intent = Intent(ctx, CaptureService::class.java).apply {
            putExtra(CaptureService.EXTRA_MODE, mode.name)
            putExtra(CaptureService.EXTRA_QUALITY, quality.name)
            putExtra(CaptureService.EXTRA_HEVC, hevc)
            selectedCamera?.let { putExtra(CaptureService.EXTRA_CAMERA_ID, it.id) }
            if (resultData != null) {
                putExtra(CaptureService.EXTRA_RESULT_CODE, resultCode)
                putExtra(CaptureService.EXTRA_RESULT_DATA, resultData)
            }
        }
        CaptureService.lastError = null
        ctx.startForegroundService(intent)
        streaming = true
    }

    val projectionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            startService(result.resultCode, result.data)
        }
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        val cameraOK = pendingMode != CaptureMode.CAMERA || grants[Manifest.permission.CAMERA] == true ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val audioOK = grants[Manifest.permission.RECORD_AUDIO] == true ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (cameraOK && audioOK) {
            if (pendingMode == CaptureMode.SCREEN) {
                val manager = ctx.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                projectionLauncher.launch(manager.createScreenCaptureIntent())
            } else {
                startService()
            }
        }
    }

    DisposableEffect(ctx) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) streaming = CaptureService.isRunning
        }
        ctx.lifecycle.addObserver(observer)
        onDispose { ctx.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(streaming) {
        while (streaming) {
            delay(500)
            streaming = CaptureService.isRunning
        }
    }

    val supports4K = selectedCamera?.let { CaptureCapabilities.supports4K(ctx, it.id, hevc) } == true
    val configurationValid = mode != CaptureMode.CAMERA || selectedCamera != null &&
        (quality != Quality.UHD || supports4K)

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("开讲移动端", style = MaterialTheme.typography.headlineSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                StatusDot(streaming)
                Text(
                    if (streaming) "音视频传输中" else CaptureService.lastError ?: "等待开始",
                    color = if (CaptureService.lastError != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text("本机 IP  $ip", color = MaterialTheme.colorScheme.onSurfaceVariant)

            Section("采集来源") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CaptureMode.entries.forEach { item ->
                        ModeButton(item, mode == item, !streaming, Modifier.weight(1f)) {
                            mode = item
                            if (item == CaptureMode.SCREEN && quality == Quality.UHD) quality = Quality.HD
                        }
                    }
                }
                if (mode == CaptureMode.SCREEN) {
                    Hint("共享手机画面和允许被捕获的应用声音。部分 App 会禁止系统内录。")
                } else {
                    if (cameras.isEmpty()) {
                        Hint("没有可用摄像头")
                    }
                    cameras.forEach { camera ->
                        Row(
                            Modifier.fillMaxWidth().selectable(
                                selected = selectedCamera == camera,
                                enabled = !streaming,
                                onClick = { selectedCamera = camera },
                            ).padding(vertical = 3.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(
                                selected = selectedCamera == camera,
                                enabled = !streaming,
                                onClick = { if (!streaming) selectedCamera = camera },
                            )
                            Text(camera.label)
                        }
                    }
                    Hint("摄像头画面与手机麦克风一起传输。")
                }
            }

            Section("画质") {
                Quality.entries.filter { mode == CaptureMode.CAMERA || it != Quality.UHD }.forEach { item ->
                    val enabled = !streaming && (item != Quality.UHD || supports4K)
                    Row(
                        Modifier.fillMaxWidth().selectable(
                            selected = quality == item,
                            enabled = enabled,
                            onClick = { quality = item },
                        ).padding(vertical = 3.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = quality == item, enabled = enabled, onClick = { if (enabled) quality = item })
                        Text(item.label, color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.weight(1f))
                        Text(
                            "${item.bitrate(hevc) / 1_000_000} Mbps",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                if (mode == CaptureMode.CAMERA && !supports4K) {
                    Hint("当前摄像头与所选编码器组合不支持 4K；不会自动降级。")
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = hevc,
                        enabled = !streaming && hevcAvailable,
                        onCheckedChange = { hevc = it },
                    )
                    Text("H.265（同画质节省带宽）")
                }
                if (!hevcAvailable) Hint("当前设备没有 H.265 编码器，请使用 H.264。")
                if (quality == Quality.UHD) Hint("4K 建议使用 5GHz/6GHz Wi‑Fi，并注意设备发热。")
            }

            Spacer(Modifier.height(6.dp))
            Button(
                onClick = {
                    if (streaming) {
                        ctx.stopService(Intent(ctx, CaptureService::class.java))
                        streaming = false
                    } else {
                        pendingMode = mode
                        val permissions = buildList {
                            add(Manifest.permission.RECORD_AUDIO)
                            if (mode == CaptureMode.CAMERA) add(Manifest.permission.CAMERA)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
                        }
                        permissionLauncher.launch(permissions.toTypedArray())
                    }
                },
                enabled = streaming || configurationValid,
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(3.dp),
                colors = if (streaming) {
                    ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                } else {
                    ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary)
                },
            ) {
                Text(if (streaming) "停止传输" else "开始音视频传输")
            }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(3.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        content()
    }
}

@Composable
private fun ModeButton(mode: CaptureMode, selected: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val border = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    Row(
        modifier.border(1.dp, border, RoundedCornerShape(3.dp)).clickable(enabled = enabled, onClick = onClick).padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SourceIcon(mode, if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        Text(mode.label)
    }
}

@Composable
private fun SourceIcon(mode: CaptureMode, color: Color) {
    Canvas(Modifier.size(19.dp)) {
        val stroke = Stroke(width = 1.6.dp.toPx())
        if (mode == CaptureMode.SCREEN) {
            drawRoundRect(color, style = stroke, cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()))
            drawLine(color, Offset(size.width * .35f, size.height * .82f), Offset(size.width * .65f, size.height * .82f), strokeWidth = stroke.width)
        } else {
            drawRect(
                color,
                topLeft = Offset(size.width * .08f, size.height * .25f),
                size = Size(size.width * .64f, size.height * .53f),
                style = stroke,
            )
            drawLine(color, Offset(size.width * .72f, size.height * .38f), Offset(size.width * .94f, size.height * .26f), strokeWidth = stroke.width)
            drawLine(color, Offset(size.width * .94f, size.height * .26f), Offset(size.width * .94f, size.height * .77f), strokeWidth = stroke.width)
            drawLine(color, Offset(size.width * .94f, size.height * .77f), Offset(size.width * .72f, size.height * .65f), strokeWidth = stroke.width)
        }
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun StatusDot(active: Boolean) {
    val color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    Canvas(Modifier.size(8.dp)) { drawCircle(color) }
}
