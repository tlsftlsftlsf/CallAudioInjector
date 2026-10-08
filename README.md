# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

支持**在任何时候长按机身电源键（侧边键）唤出/隐藏全局悬浮控制胶囊**，并在通话过程中将指定音频文件实时混入麦克风采集音频流（Uplink / Bus 1），**让通话另一方（对方）清晰听到指定音频**。

---

## 🌟 核心功能特性（iOS 17 专属优化）

1. **任何时候长按电源键显隐悬浮窗（全局顶级覆盖）**：
   - 注入 iOS 17 核心系统进程 `SpringBoard`，Hook 硬件侧边键逻辑（`SBSiriHardwareButtonInteraction` 与 `SBHBLongPressGestureRecognizer`）。
   - **无论在桌面、锁屏、任何 App 内部还是通话界面中**，长按电源键均可即时显隐悬浮窗，并伴有 iOS 17 触觉反馈（`UIImpactFeedbackGenerator`）。
   - 拦截长按操作以阻止唤起 Siri，体验完全无缝。
2. **非侵入式全局穿透悬浮窗（CAIFloatingWindow）**：
   - 基于 iOS 17 `_isSecure` 顶层窗口机制（`windowLevel = 10000000.0`），保证悬浮窗置于全局最顶层。
   - 重写 `hitTest:` 机制：**仅响应点击/拖拽悬浮胶囊本身的事件，其余大面积透明区域 100% 穿透至底层屏幕**，完全不干扰正常滑动手机和使用其他 App。
   - 支持全屏幕自由拖拽，松手时带平滑物理弹簧吸附至就近边缘。
3. **对方听到（系统底层麦克风链路注入）**：
   - 注入 `mediaserverd`，Hook CoreAudio 的 `AudioUnitRender` 函数。
   - 在通话时截获麦克风采集端音频（Bus 1），实现音频混音（Mix）或麦克风静音独占播放（Replace）。
4. **全自动格式与采样率重采样**：
   - 基于 Apple CoreAudio `ExtAudioFile`，自动实时对齐当前通话硬件采样率（如 16kHz/24kHz/48kHz）与声道数。
   - 支持 16-bit 线性 PCM 与 32-bit Float PCM 混音，内置防爆音饱和算法。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                      # Theos 编译配置 (Rootless, arm64 + arm64e)
├── control                       # Debian 软件包元数据 (v1.2.0, 限制 firmware >= 17.0)
├── CallAudioInjector.plist       # 进程过滤 (mediaserverd & SpringBoard)
├── Tweak.x                       # 插件核心源码 (AudioUnit Hook, 硬件按键拦截, 全局悬浮窗)
├── .gitignore                    # Git 忽略配置
└── README.md                     # 说明文档
```

---

## 🛠️ 本地编译与打包

确保开发环境已安装 Theos 与 iOS SDK：

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
   packages/com.tlsf.callaudioinjector_1.2.0_iphoneos-arm64.deb
   ```
2. 在设备上使用 **Sileo**、**Zebra**、**Filza** 安装，或在终端执行：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.2.0_iphoneos-arm64.deb
   killall -9 mediaserverd SpringBoard
   ```

---

## 🎵 音频文件准备与配置

### 1. 放置音频文件
默认音频文件路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(支持 `.wav`、`.mp3`、`.m4a` 等，在配置文件中指定即可)*

**设置读取权限**：
```bash
chmod 644 /var/mobile/Media/inject_audio.wav
```

### 2. 配置文件选项
配置文件路径为 `/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 音频文件路径 -->
    <key>audioPath</key>
    <string>/var/mobile/Media/inject_audio.wav</string>

    <!-- 是否循环播放 (YES / NO) -->
    <key>loopPlayback</key>
    <true/>

    <!-- 是否静音麦克风原声 (NO: 混音模式；YES: 仅播放音频，你的声音被静音) -->
    <key>muteMic</key>
    <false/>

    <!-- 音量增益倍数 (默认 1.0) -->
    <key>gain</key>
    <real>1.0</real>
</dict>
</plist>
```

---

## 🕹️ 使用指南

1. **任何时候长按电源键（侧边键）约 0.8~1 秒**：
   - 伴随触觉微震动，屏幕上方将平滑弹出 `[🎙️ 注入音频]` 悬浮胶囊；
2. **点击悬浮按钮**：
   - 按钮实时变为红色 `[⏹ 停止注入]`，音频注入麦克风流，通话另一方即可听到音频；
   - 再次点击停止注入；
3. **拖拽调整位置**：
   - 悬浮胶囊支持在屏幕任意区域拖动，松手自动靠边吸附；
4. **再次长按电源键**：
   - 悬浮胶囊淡出隐藏，不遮挡任何界面。

---

## 🚀 GitHub 版本管理与发布

### 提交更新并打 Tag
```bash
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

git add .
git commit -m "feat: iOS 17 specific release with global floating window on power button long press (v1.2.0)"

# 打版本标签发布 Release
git tag -a v1.2.0 -m "Release v1.2.0: iOS 17 dedicated, power button long press anytime"

# 推送至 GitHub（若已配置 remote）
git push origin main --tags
```
推送标签后，GitHub Actions 会在 macOS 云端自动编译并挂载 `.deb` 附件到 GitHub Releases 供下载！
