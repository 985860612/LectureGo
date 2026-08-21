# 开讲移动端

Android 音视频发送模块，只负责把手机来源送入同一局域网中的开讲 Mac 端。
发送协议与硬编基线迁自 AndroidScreenMonitor `aef7771`，监看与中转能力未迁入。

## 模式

- 共享屏幕：MediaProjection 画面 + AudioPlaybackCapture 系统/应用声音，最高 1080p/30fps。
- 使用摄像头：Camera2 + 手机麦克风，支持 540p、720p、1080p，以及硬件允许时的 4K/30fps。
- 视频使用 H.264 或 H.265，音频使用 AAC-LC 48kHz。

4K 同时检查摄像头输出尺寸和 MediaCodec 编码能力；不支持时禁用选项，不自动降级。

## 构建

```bash
./gradlew :app:assembleDebug :app:testDebugUnitTest --no-daemon
```

APK：`app/build/outputs/apk/debug/app-debug.apk`

## 网络

- Bonjour/NSD：`_screenmon._tcp`
- TCP 6060：控制和音视频参数协商
- UDP：Mac 在 `HELLO` 中提供独立接收端口，H.264/H.265/AAC 共用媒体包头

本模块不包含监看墙、中转服务器、公网房间或网页观看能力。
