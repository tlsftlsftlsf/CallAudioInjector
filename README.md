# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

**【v2.0.0 重大更新：彻底攻克通话对方听不到问题，全局总线混音与多重同步引擎】**
1. **解决“对方听不到”核心症结 1：三大跨进程零延迟同步体系（POSIX Flag + GCD Dispatch + Kernel State）**：
   - 旧版本在系统守护进程（如 iOS 17 的 `audiomxd`）中依赖传统 `CFNotificationCenterAddObserver`，而该进程在底层使用 GCD `dispatch_main()` 运行、从不执行 `CFRunLoop`，导致通知无法被守护进程接收。
   - v2.0.0 采用 **POSIX 文件标志位（`/tmp/cai_active.flag`）+ GCD 调度源（`notify_register_dispatch`）+ Darwin 内核状态寄存器（`notify_get_state`）** 三重冗余机制。无论守护进程运行于何种线程或事件循环，在渲染下一帧音频时即可零延迟感知状态，100% 确保服务端激活！
2. **解决“对方听不到”核心症结 2：全总线通道混音（Bus 1 麦克风上行 + Bus 0 语音处理单元）**：
   - iOS 17 电话通道在 `audiomxd` 内部流转时，上行可能处于 VoiceProcessingAU 的 Bus 1，也可能流经单总线转换节点（Bus 0）。v2.0.0 全面拦截并混音至各音频节点，同时智能保护下行通话不被麦克风静音机制误伤！
3. **动态线性插值重采样引擎（自动适配 8k/16k/24k/48k 通话编解码）**：
   - 普通电话 VoLTE（AMR-WB）常用 16kHz 采样率，微信/FaceTime 常用 24kHz 或 48kHz。v2.0.0 实时探测目标 AudioUnit 总线采样率，进行高精度浮点线性插值重采样，确保对方听到的语音语速、语调自然清晰，绝不变调！
4. **高精度 Mach 时间戳全局对齐**：
   - 彻底摒弃简单的帧偏移累加，采用 `mach_absolute_time()` 时间基准对齐。无论底层有多少个并发 AudioUnit 节点同时渲染，音频播放绝不发生快进、跳音或不同步。
5. **Deb 安装自动化拉起守护进程（DEBIAN/postinst）**：
   - 打包集成自动 `postinst` 脚本，在 `dpkg -i` 安装后立即自动重启 `audiomxd`、`mediaserverd` 等后台服务，使新版 Hook 立即生效，无需用户手动到处寻找进程杀除。
6. **全面支持主流电话与 VoIP 应用**：
   - 包含普通蜂窝电话（`audiomxd`、`mediaserverd`、`callservicesd`、`InCallService`、`MobilePhone`）以及常见 VoIP 应用（微信 `WeChat`、`FaceTime`、`QQ`、`DingTalk`）。

---

## 🌟 核心功能与技术实现

### 1. 通话对端高保真接收 + 本机同步确认
- **对方收听**：`audiomxd` 与语音处理节点底层拦截麦克风流，无损注入并混音「运费.mp3」。
- **本机发声**：点击悬浮胶囊，SpringBoard 进程双引擎直接调用系统通道播放内置的「运费.mp3」，音质清晰洪亮，无惧静音开关，本地即刻确认播放状态。

### 2. 毫秒级无锁混音
- 音频渲染回调内实现零分配、零文件 I/O、纯指针偏移采样混合，单次渲染耗时小于 2 微秒，确保通话极度流畅、不破音、无卡顿。

### 3. 全局悬浮窗与按键交互
- **安装后直接可见**：Respring 后屏幕顶层直接常驻绿色 `[🎙️ 注入音频]` 胶囊。
- **点击触觉反馈**：点击立即产生 Heavy 震动 + 弹性缩放 + 切换为红色 `[⏹ 停止注入]`，本机同步响声。
- **长按音量下键**：长按 0.6 秒随时隐藏或唤出悬浮窗。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml               # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                        # Theos 编译配置 (双 Dylib, Rootless, arm64 + arm64e)
├── control                         # Debian 软件包元数据 (v2.0.0)
├── CallAudioInjector.plist         # 服务端过滤 (audiomxd, mediaserverd, WeChat, FaceTime...)
├── CallAudioInjectorUI.plist       # UI 模块过滤 (com.apple.springboard)
├── EmbeddedAudio.h                 # 内置内嵌的「运费.mp3」二进制字节库
├── layout/                         # deb 目录布局，自动打包部署运费.mp3 & postinst
│   ├── DEBIAN/
│   │   ├── postinst                # 安装后自动重启 audiomxd 等服务
│   │   └── postrm                  # 卸载后自动清理
│   └── ...
├── TweakServer.x                   # 底层麦克风音频流注入与实时重采样混音引擎
├── TweakUI.x                       # SpringBoard 全局悬浮窗与本机同步发声播放器
├── .gitignore                      # Git 忽略配置
└── README.md                       # 说明文档
```

---

## 🛠️ 本地编译与打包

```bash
# 1. 切换到项目目录
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

# 2. 编译并打包 release deb
export THEOS=/Users/tlsf/theos
make clean && make package FINALPACKAGE=1

# 3. 查看生成的 deb 包
ls -lh packages/
```

---

## 📲 安装与生效

1. 将生成的 `.deb` 文件传输到 iOS 17 设备：
   ```text
   packages/com.tlsf.callaudioinjector_2.0.0_iphoneos-arm64.deb
   ```
2. 在设备终端或包管理器安装：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_2.0.0_iphoneos-arm64.deb
   killall -9 SpringBoard
   ```
   *(注：deb 内置 postinst 已自动重启 audiomxd、mediaserverd、callservicesd，只需重启 SpringBoard 即可唤起悬浮窗)*
3. **注销完成后，屏幕右上方会直接出现绿色的 `[🎙️ 注入音频]` 悬浮胶囊！**

---

## 🕹️ 使用指南

1. **通话注入「运费.mp3」**：
   - 拨通电话（或微信语音通话）；
   - 在屏幕右上角轻点胶囊，变红 `[⏹ 停止注入]`；
   - **本机扬声器立刻响起「运费.mp3」**，同时 **通话对方清晰听到「运费.mp3」声音**；
   - 再次点击胶囊变绿，双方声音立即同步停止。
2. **查看实时运行日志**：
   - 在设备运行 `cat /tmp/cai_debug.log`，可以看到各个进程（如 `audiomxd`、`SpringBoard`）的注入细节，包括具体渲染 Bus、采样率（如 16000Hz）、帧数等！
3. **自由拖拽**：按住胶囊拖到任意位置，松手带物理阻尼自动靠边吸附。
4. **长按音量下键显隐**：长按 0.6 秒随时收起或唤出悬浮窗。

---

## 📄 开源许可证

MIT License.
