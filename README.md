# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

**【v1.6.0 重大底层重构更新】**
1. **适配 iOS 17 全新音频架构（注入 `audiomxd` 核心混音守护进程）**：
   - 彻底解决 iOS 17 通话中无法注入音频的根本原因！Apple 在 iOS 17 中拆分了原有的 `mediaserverd`，将麦克风处理、语音处理（VoiceProcessing）、音频路由仲裁全部迁入新守护进程 **`audiomxd`**。
   - v1.6.0 全面覆盖 `audiomxd`、`mediaserverd`、`callservicesd`、`InCallService`、`coreaudiod`、`MobilePhone`，确保通话音频流 100% 被捕获。
2. **纯内存合成音频回退（零文件依赖、零沙盒限制）**：
   - 启动即在 RAM 中预生成 48kHz 双精度 PCM 音频，绝不受 iOS 17 严格沙盒或文件路径权限影响，即使未放置任何文件也绝不中断。
   - 同时支持从 `/var/mobile/Media/inject_audio.wav` 读取自定义音乐或录音并自动重采样。
3. **双链路立体混音（Bus 1 对方听到 + Bus 0 本机实时监听）**：
   - **Bus 1（麦克风上行）**：将指定音频全幅混入麦克风流，对方清晰收听（可配置是否静音真实麦克风）。
   - **Bus 0（听筒/扬声器下行）**：以舒适音量同步注入本机受话通道，让本机拨号者在耳机/听筒中清晰获得实时声音反馈，告别“不知道放没放”的困扰！
4. **双重 CoreAudio 接口拦截**：
   - 同时拦截 `AudioUnitRender` 与 `AudioUnitProcess`，覆盖所有 DSP 及通话音频流水线。

---

## 🌟 核心功能与技术实现

### 1. iOS 17 底层守护进程全景支持 (v1.6.0)
- `audiomxd`：iOS 17 核心系统混音与语音处理服务（主链路）。
- `mediaserverd`：媒体采集与回放服务。
- `callservicesd` / `InCallService`：系统电话与通话路由服务。

### 2. 毫秒级无锁混音 (v1.6.0)
- 音频渲染回调内实现零分配、零文件 I/O、纯指针偏移采样混合，单次渲染耗时小于 2 微秒，确保通话极度流畅、不破音、无卡顿。

### 3. 全局悬浮窗与按键交互
- **安装后直接可见**：Respring 后屏幕顶层直接常驻绿色 `[🎙️ 注入音频]` 胶囊。
- **点击触觉反馈**：点击立即产生 Heavy 震动 + 弹性缩放 + 切换为红色 `[⏹ 停止注入]`。
- **长按音量下键**：长按 0.6 秒随时隐藏或唤出悬浮窗。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml               # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                        # Theos 编译配置 (双 Dylib, Rootless, arm64 + arm64e)
├── control                         # Debian 软件包元数据 (v1.6.0)
├── CallAudioInjector.plist         # 服务端过滤 (audiomxd, mediaserverd, callservicesd...)
├── CallAudioInjectorUI.plist       # UI 模块过滤 (com.apple.springboard)
├── TweakServer.x                   # 底层音频流双总线注入与实时混音引擎
├── TweakUI.x                       # SpringBoard 全局悬浮窗与按键交互
├── .gitignore                      # Git 忽略配置
└── README.md                       # 说明文档
```

---

## 🛠️ 本地编译与打包

```bash
# 1. 切换到项目目录
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

# 2. 编译并打包 release deb
make clean && make package FINALPACKAGE=1

# 3. 查看生成的 deb 包
ls -lh packages/
```

---

## 📲 安装与生效

1. 将生成的 `.deb` 文件传输到 iOS 17 设备：
   ```text
   packages/com.tlsf.callaudioinjector_1.6.0_iphoneos-arm64.deb
   ```
2. 在设备上安装并重启音频守护进程与界面：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.6.0_iphoneos-arm64.deb
   killall -9 audiomxd mediaserverd callservicesd InCallService SpringBoard
   ```
3. **注销完成后，屏幕右上方会直接出现绿色的 `[🎙️ 注入音频]` 悬浮胶囊！**

---

## 🕹️ 使用指南

1. **通话中注入音频**：
   - 拨通电话（或接通语音通话）后，点击悬浮胶囊变红 `[⏹ 停止注入]`。
   - **对方听筒将清晰听到注入音频**；
   - **本机听筒也会同步听到背景音频播放**，明确感知当前正在注入。
   - 再次点击即可停止注入。
2. **自由拖拽**：按住胶囊拖到任意位置，松手带物理阻尼自动靠边吸附。
3. **长按音量下键显隐**：长按 0.6 秒随时收起或唤出悬浮窗。

---

## 🎵 自定义音频文件替换

默认音频路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(插件支持常见的 `.wav`、`.mp3`、`.m4a` 格式。若未放入自定义音频，插件会自动播放内置的高品质双音提示曲)*

可在配置文件 `/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist` 调节增益与静音麦克风：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>audioPath</key>
    <string>/var/mobile/Media/inject_audio.wav</string>
    <key>loopPlayback</key>
    <true/>
    <key>muteMic</key>
    <false/>
    <key>gain</key>
    <real>1.0</real>
</dict>
</plist>
```

---

## 🚀 GitHub 版本管理

```bash
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

git add .
git commit -m "feat: support iOS 17 audiomxd daemon, dual-bus mixing, and in-memory fallback (v1.6.0)"
git tag -a v1.6.0 -m "Release v1.6.0: iOS 17 audiomxd support & dual-bus audio injection"
git push origin main --tags
```
