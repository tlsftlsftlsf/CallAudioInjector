# CallAudioInjector (iOS 15 - 17 越狱插件)

CallAudioInjector 是一款专为 iOS 15 - 17（Rootless 无根越狱架构，如 Dopamine、palera1n）设计的系统级通话音频注入插件。

本插件能够在通话过程中，将本地指定的音频文件实时混入麦克风采集音频流（Uplink / Bus 1），**让通话另一方（对方）清晰听到指定音频**。支持**长按电源键（侧边键）随时唤出/隐藏悬浮控制按钮**。

---

## 🌟 核心特性

1. **对方听到（底层麦克风流注入）**：
   - 注入系统底层 `mediaserverd`，Hook `AudioUnitRender`。
   - 截获麦克风采集端音频，实现混音（Mix）或麦克风静音独占播放（Replace）。
2. **长按电源键 / 侧边键唤出（交互优化）**：
   - Hook `SpringBoard` 的 `SBSiriHardwareButtonInteraction` 与 `SBHBLongPressGestureRecognizer`。
   - 通话中**长按电源键/侧边键**即可唤出或隐藏半透明悬浮控制胶囊，带有轻触触觉震动反馈。
   - 通话中拦截长按操作，防止意外唤起 Siri 打扰通话。
3. **音频自动重采样（彻底解决杂音/变调）**：
   - 基于 Apple CoreAudio `ExtAudioFile`，自动匹配当前通话硬件采样率（如 16kHz/24kHz/48kHz）与声道数。
   - 支持 16-bit 线性 PCM 与 32-bit Float PCM 混音，内置溢出保护防爆音。
4. **通话悬浮控制胶囊**：
   - 半透明磨砂质感按钮：`[🎙️ 注入音频]`（绿色） / `[⏹ 停止注入]`（红色）。
   - 支持全屏幕任意拖动，通话结束后自动隐藏并停止注入。
5. **现代架构兼容与持续集成**：
   - 兼容 iOS 15.0 ~ 17.x（支持 arm64 与 arm64e PAC 指针验证）。
   - 配备 GitHub Actions 持续集成工作流，打 Tag 自动打包 Release `.deb`。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 自动化构建 & Release 工作流
├── Makefile                      # Theos 编译配置 (Rootless, arm64 + arm64e)
├── control                       # Debian 软件包元数据 (v1.1.0)
├── CallAudioInjector.plist       # 进程过滤 (mediaserverd, SpringBoard, InCallService)
├── Tweak.x                       # 插件核心源码 (AudioUnit Hook, 硬件按键拦截, 悬浮窗)
├── .gitignore                    # Git 忽略配置
└── README.md                     # 说明文档
```

---

## 🛠️ 本地编译与打包

确保开发环境已安装 Theos，并配置好 iOS SDK：

```bash
# 1. 切换到项目目录
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

# 2. 编译并打包 release deb
make clean && make package FINALPACKAGE=1

# 3. 生成的 deb 文件位于 packages/ 目录下
ls -lh packages/
```

---

## 📲 安装与部署

1. 将生成的 `.deb` 文件传输到手机：
   ```text
   packages/com.tlsf.callaudioinjector_1.1.0_iphoneos-arm64.deb
   ```
2. 在手机上使用 **Sileo**、**Zebra**、**Filza** 安装，或在终端执行：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.1.0_iphoneos-arm64.deb
   killall -9 mediaserverd SpringBoard InCallService
   ```

---

## 🎵 音频文件准备与配置

### 1. 放置音频文件
默认音频文件路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(支持 `.wav`、`.mp3`、`.m4a` 等，在配置文件中指定即可)*

**权限设置**（重要）：
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

    <!-- 音量增益倍数 (1.0 为原始音量) -->
    <key>gain</key>
    <real>1.0</real>

    <!-- 长按电源键是否仅在通话中生效 (YES: 仅通话中唤出，平时仍为 Siri/关机；NO: 随时生效) -->
    <key>requireCallForPowerButton</key>
    <true/>

    <!-- 初始是否直接显示悬浮按钮 (NO: 默认隐藏，等待长按电源键唤出；YES: 接通即显示) -->
    <key>showFloatingButtonInitially</key>
    <false/>
</dict>
</plist>
```

---

## 🕹️ 使用方法

1. **接通电话**（普通蜂窝电话、FaceTime 或微信/CallKit 电话均支持）。
2. **长按机身电源键（侧边键）约 0.8~1 秒**：
   - 手机会产生一次轻触触觉震动反馈；
   - 屏幕上将平滑浮现 `[🎙️ 注入音频]` 悬浮胶囊；
3. **点击悬浮按钮**：
   - 按钮变为红色 `[⏹ 停止注入]`，音频文件开始注入麦克风，对方能实时清晰听到；
   - 再次点击停止注入；
4. **再次长按电源键**：
   - 悬浮按钮平滑淡出隐藏，不遮挡屏幕；
5. **通话挂断**：
   - 自动停止音频播放并清理悬浮窗。

---

## 🚀 GitHub 版本管理与发布

### 提交更新并打 Tag
```bash
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

git add .
git commit -m "feat: add power button long press to toggle floating button (v1.1.0)"

# 打版本标签发布 Release
git tag -a v1.1.0 -m "Release version 1.1.0: support long press power button trigger"

# 推送至 GitHub（若已关联 remote）
git push origin main --tags
```
GitHub Actions 会自动在 macOS 云端构建并将包含 arm64 + arm64e 的 deb 发布至 GitHub Releases！
