<p align="center">
  <img src="Resources/LectureGoMark.svg" width="96" alt="开讲 LectureGo">
</p>

<h1 align="center">开讲 LectureGo</h1>

<p align="center">多源课程录制工作台</p>

<p align="center">
  <a href="https://985860612.github.io/LectureGo/">项目主页</a> ·
  <a href="https://github.com/985860612/LectureGo/issues">问题反馈</a> ·
  <a href="LICENSE">非商业许可</a>
</p>

> [!IMPORTANT]
> 本项目源码公开，仅允许非商业使用。商业使用、商业集成、付费交付及以盈利为目的的部署均未获得授权，详见 [LICENSE](LICENSE)。

开讲是一套 macOS + Android 多源课程录制工具：按需添加屏幕、窗口、摄像头、局域网移动端、RTMP 和麦克风，一键得到合成成片、混音与各来源独立文件。Android 发送端作为 `mobile/` 独立模块随仓库维护。

## 快速开始

环境要求：macOS 14 或以上、Swift 5.9 或以上；构建移动端还需要 JDK 17 和 Android SDK。

```bash
git clone https://github.com/985860612/LectureGo.git
cd LectureGo
./scripts/build-app.sh
open CourseRec.app
```

首次构建会下载 SwiftPM 依赖和经过 SHA-256 校验的 MediaMTX。应用首次运行时需要授权屏幕录制、摄像头、麦克风和局域网访问。

## 背景

替代「OBS + Source Record 插件」的繁琐配置，原生支持：

- 来源池可同时添加多个屏幕、应用窗口、摄像头、开讲移动端、RTMP(S) 和麦克风，并阻止重复来源
- 移动端可发送屏幕或摄像头；摄像头在硬件支持时提供 4K/30 fps，并同步发送 AAC 系统声或麦克风声音
- 内置 RTMP 接收服务自动生成 `stream-xxxxxxxxxx` 流名，任何支持 RTMP 推流的设备或软件均可直接接入
- 来源配置自动恢复，支持重命名、启停、静音、Solo、耳机监听、麦克风增益和独立文件开关
- 每路视频源独立 ISO、每路麦克风独立音频，时间轴统一
- 音频分轨：多路人声 / 电脑声分开（系统声只采一次，避免多屏重复叠加）
- 实时输出监看：所有视频来源统一为有序图层，6 种模板和手工布局共用同一个成片合成器
- 每个图层均可完整显示、裁切填满或拉伸填满，并可直接拖动、缩放、隐藏、锁定和调整层级
- 自定义场景保存来源绑定、图层位置/层级、声音路由、切换效果和录制参数，录制中允许实时导播
- 输出参数：跟随首层来源 / 720p / 1080p / 2K / 4K，15–60 fps，H.264 / HEVC 与码率档位
- 左右来源与设置侧栏可以独立隐藏，让输出监看占满窗口
- 麦克风实时电平、峰值保持、过载提示和 -12～+12 dB 增益
- 实时显示目标/实际帧率、CPU、GPU 合成链路耗时、写盘速率、丢帧和磁盘余量；结束后逐文件生成录制报告
- `.partial` 事务式写入、10 秒可恢复片段、启动时扫描未完成录制
- 全局快捷键启停 + 分段打点标记

## 技术路线

无完整 Xcode（仅 Command Line Tools）环境下的纯 Swift 路线：

- Swift 5.9 / SwiftUI，SwiftPM executable target
- ScreenCaptureKit（屏幕 + 系统声音）、AVFoundation（摄像头 + 麦克风）
- 开讲移动端局域网协议（Bonjour + TCP 控制 + UDP H.264/H.265/AAC）与 VideoToolbox 硬解
- HaishinKit RTMP playback（原生 SwiftPM 依赖，不要求安装 FFmpeg）
- AVAssetWriter 多路并行写文件
- 手工组装 .app bundle + ad-hoc 签名（见 `scripts/build-app.sh`）

## 构建与运行

```bash
./scripts/build-app.sh              # debug 构建
./scripts/build-mobile.sh           # Android debug APK + 单测
./scripts/check-mobile-protocol.sh  # 移动端协议单测
./scripts/check-mobile-input.sh     # TCP/UDP/H.264/H.265 硬解烟测（需 ffmpeg）
open CourseRec.app                  # 运行
```

可靠性与编码烟测：

```bash
swiftc scripts/reliability-smoke.swift \
  Sources/CourseRec/Recording/{TrackWriter,CompositionLayout,CompositionLayer,CompositionScene,OutputVideoSettings}.swift \
  Sources/CourseRec/Recording/RecordingSourceDefinition.swift \
  -framework AVFoundation -framework CoreVideo -framework VideoToolbox \
  -o /tmp/courserec-reliability-smoke && /tmp/courserec-reliability-smoke

# Debug App 真实设备定时实录
COURSE_REC_SMOKE_SECONDS=8 ./CourseRec.app/Contents/MacOS/CourseRec

# 三路视频、多图层和录制中场景淡入；可按窗口标题指定测试窗口
COURSE_REC_SMOKE_SECONDS=8 COURSE_REC_SMOKE_LAYOUT=multilayer \
  COURSE_REC_SMOKE_WINDOW_TITLE='窗口标题' ./CourseRec.app/Contents/MacOS/CourseRec

# 只把麦克风送入成片，验证独听路由
COURSE_REC_SMOKE_SECONDS=5 COURSE_REC_SMOKE_AUDIO_SOLO=microphone \
  ./CourseRec.app/Contents/MacOS/CourseRec

# 缩小并拉伸主画框，验证监看与成片使用相同的自由画框
COURSE_REC_SMOKE_SECONDS=5 COURSE_REC_SMOKE_PRIMARY_MODE=stretch \
  ./CourseRec.app/Contents/MacOS/CourseRec
```

首次构建会由 SwiftPM 下载 HaishinKit，并下载、校验和签名 MediaMTX v1.18.2；后续构建使用 `.build/tools` 缓存。运行时不需要另外安装 RTMP 服务。

首次运行需在系统弹窗中授权：相机、麦克风、屏幕录制、局域网（系统设置 → 隐私与安全性）。使用移动端或 RTMP 视频源时不要求相机权限。
授权后若列表为空，点界面上的「刷新设备」。

> 签名说明：使用钥匙串中的自签名证书「CourseRec Dev」（openssl 生成的自签名根 CA，
> 已导入登录钥匙串）。签名身份稳定，**重编译不会丢权限**。若证书被删导致退回
> ad-hoc 签名，则每次构建都需重新授权，且需先
> `tccutil reset ScreenCapture/Camera/Microphone com.wangxiaojie.courserec`。

## 联系与支持

遇到问题可以通过 Issue 反馈；涉及安全问题或不适合公开的信息，请按
[SECURITY.md](SECURITY.md) 联系作者。参与开发请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

<table>
  <tr>
    <th>联系作者</th>
    <th>微信赞赏</th>
    <th>支付宝赞赏</th>
  </tr>
  <tr>
    <td><img src="Resources/Support/wechat-contact.jpg" width="220" alt="微信联系作者"></td>
    <td><img src="Resources/Support/wechat-support.jpg" width="220" alt="微信赞赏"></td>
    <td><img src="Resources/Support/alipay-support.jpg" width="220" alt="支付宝赞赏"></td>
  </tr>
</table>

赞赏完全自愿，用于支持持续开发，不产生商业授权、优先支持或服务承诺。

## 许可

Copyright 2026 Wang Xiaojie。

源码按 [PolyForm Noncommercial License 1.0.0](LICENSE) 提供。允许个人学习、研究、实验、公益、教育机构及其他条款明确允许的非商业用途；不允许商业使用。本项目因此属于源码公开软件，而不是 OSI 定义下的开源软件。

第三方组件继续遵循各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 里程碑

- [x] M1 工程脚手架 + 权限 + 设备枚举 + 三源预览
- [x] M2 一键录制三源独立文件
- [x] M3 输出画面合成 + Retina 修正
- [x] M4 成片双音轨（人声/电脑声），随 M3 落地
- [x] M5 全局快捷键（⌘⇧R 启停、⌘⇧M 打点）+ 分段标记.txt

全部完成并实测验证（2026-08-20）：三文件时长对齐误差 <0.2s，零丢帧。

- [x] M6 OBS 式多源来源池 + 有序图层 + 6 种输出模板 + 实时音频电平 + 输出编码设置
- [x] M7 事务式录制与恢复、逐文件报告、真实帧率和磁盘预检
- [x] M8 任意输出图层、场景保存、录制中导播、窗口来源和音频混音
- [x] M9 局域网移动端（H.264/H.265）与 RTMP(S) 视频源接入多源池
- [x] M10 Android 模块迁入：屏幕/摄像头、4K 摄像头、AAC 音频与多源池路由

## 移动端与 RTMP 视频源

移动端源码位于 `mobile/`，保留 AndroidScreenMonitor 的局域网直连核心并移除监看墙、中转和 Web Viewer。Bonjour `_screenmon._tcp` 自动发现来源类型，TCP 6060 完成控制与音视频协商，UDP 使用 Mac 动态分配的端口传输 H.264/H.265/AAC；支持丢包丢整帧、关键帧恢复和断线自动重连。Bonjour 不可用时，可在“+ 移动端”中手动填写手机 IP。

手机端选择“共享屏幕”或“使用摄像头”后开始传输。屏幕模式最高 1080p，并通过 Android AudioPlaybackCapture 发送允许录制的应用声音；摄像头模式固定使用手机麦克风，硬件支持时可选 4K/30 fps。若目标 App 禁止内部录音，屏幕视频仍会继续传输，但该 App 的声音为空。

开讲启动时会自动运行通用 RTMP 接收服务，并在来源栏显示类似 `rtmp://192.168.1.10:1935/live/stream-k7m2p9x4qa` 的随机地址。把完整地址填入相机、编码器、手机或推流软件的 RTMP 地址栏；检测到推流后，“内置 RTMP”来源会自动显示画面，可直接加入输出图层。流名首次生成后保持稳定，也可点击“重新生成流名”。

“+ 外部 RTMP”仍支持拉取已有 RTMP/RTMPS 服务器，例如 `rtmp://server/live/camera`。外部地址可能包含密钥，因此不会持久化。RTMP 当前只接入视频，人声仍由本机麦克风提供。

## 输出约定

录制文件默认写入 `~/Movies/课录/`：

```
课程名称-YYYYMMDD-HHmmss/
├── 成片.mov                  # 当前有序图层合成，保留各音频轨
├── 成片混音.m4a              # 多条成片音轨自动混合，便于普通播放器使用
├── 01-屏幕 1-ISO.mov         # 每个视频来源各一份 ISO
├── 02-摄像头 1-ISO.mov
├── 01-屏幕 1-系统声.m4a      # 系统声只抓一次
├── 03-麦克风 1-人声.m4a      # 每个麦克风各一份音频
├── 课录.xml                  # DaVinci Resolve 18.1+ 多轨时间线
├── 课录.otio                 # DaVinci Resolve 18.5+ OTIO 时间线
├── 分段标记.txt              # 打点时刻（有打点时才有）
├── 录制报告.txt              # 文件大小、帧数、实际 fps、丢帧、错误与警告
└── 调试日志.txt              # 写入器状态流水（排障用）
```

录制过程中先写成 `*.partial.mov`；正常封盘后才原子改名。应用异常退出后，若文件已包含可恢复片段，底栏会显示“恢复未完成录制”。

在 DaVinci Resolve 中选择“文件 → 导入 → 时间线”：Resolve 18.1–18.4 打开
`课录.xml`，18.5 及以上优先打开 `课录.otio`。时间线会按本次实际来源动态创建轨道，
成片参考默认显示，各视频 ISO 默认关闭，独立音轨默认开启；录制打点同步成为时间线标记。
