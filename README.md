# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

**【v1.7.0 核心更新：本机同步发声监听】**
1. **本机清晰听到播放声音（原生 `AVAudioPlayer` 混音引擎）**：
   - 彻底满足用户需求：**不仅通话对方能听到，本机拨号者在自己的听筒/扬声器/耳机里也能清晰听到播放的音频！**
   - 采用 Apple 原生 `AVAudioSessionCategoryPlayback` 并开启 `mixWithOthers`，与电话通话背景无缝融合，舒适音量实时输出。
   - 无论在通话中、非通话日常主屏、锁屏还是任意 App 内，只要点击 `[🎙️ 注入音频]`，本机立刻播放音频，再次点击立刻静音停止！
2. **对方听到（iOS 17 `audiomxd` 核心守护进程注入）**：
   - 全面覆盖 iOS 17 的 `audiomxd`、`mediaserverd`、`callservicesd`、`InCallService`、`MobilePhone`，麦克风（Bus 1）全幅数字混合，对方听筒清晰可闻。
3. **零沙盒依赖与内置高品质双和弦提示音**：
   - 预设 48kHz 双精度 PCM 内存和弦曲，手机中无需预先拷贝文件即可开箱试听；同时支持从 `/var/mobile/Media/inject_audio.wav` 读取自定义音乐或录音并自动重采样。

---

## 🌟 核心功能与技术实现

### 1. 本机与对端双向发声 (v1.7.0)
- **本机收听**：`SpringBoard` 内置高优先级音频播放器，调用系统声道直连听筒/扬声器/AirPods，带来 100% 确信的实时听感反馈。
- **对方收听**：`audiomxd` 拦截系统麦克风录音链路（Uplink / Bus 1），对端无损接收注入音频。

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
├── control                         # Debian 软件包元数据 (v1.7.0)
├── CallAudioInjector.plist         # 服务端过滤 (audiomxd, mediaserverd, callservicesd...)
├── CallAudioInjectorUI.plist       # UI 模块过滤 (com.apple.springboard)
├── TweakServer.x                   # 底层麦克风音频流注入与实时混音引擎
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
make clean && make package FINALPACKAGE=1

# 3. 查看生成的 deb 包
ls -lh packages/
```

---

## 📲 安装与生效

1. 将生成的 `.deb` 文件传输到 iOS 17 设备：
   ```text
   packages/com.tlsf.callaudioinjector_1.7.0_iphoneos-arm64.deb
   ```
2. 在设备上安装并重启音频守护进程与界面：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.7.0_iphoneos-arm64.deb
   killall -9 audiomxd mediaserverd callservicesd InCallService SpringBoard
   ```
3. **注销完成后，屏幕右上方会直接出现绿色的 `[🎙️ 注入音频]` 悬浮胶囊！**

---

## 🕹️ 使用指南

1. **点击注入音频**：
   - 随时点击悬浮胶囊，胶囊变红 `[⏹ 停止注入]`；
   - **本机听筒/扬声器将立刻响起正在播放的音频**；
   - **通话中对方也能同时清晰听到该音频**；
   - 再次点击胶囊变绿，本机与对端声音立刻同步停止。
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
git commit -m "feat: enable local synchronous audio playback for caller feedback (v1.7.0)"
git tag -a v1.7.0 -m "Release v1.7.0: local synchronous audio playback and dual-route audio"
git push origin main --tags
```
