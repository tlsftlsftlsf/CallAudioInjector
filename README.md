# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

**【v1.5.0 核心更新】**
1. **解决点击按钮无反应问题**：彻底隔离拖拽手势与点击事件，增加 12pt 触控扩展热区（Hit Slop），实现**即时触觉震动 + 弹性缩放动画 + 即刻变色/改字**（零延迟反馈）。
2. **开箱即用自动生成测试音频**：若手机中尚未放入音频文件，插件自动在 `/var/mobile/Media/inject_audio.wav` 生成标准双音测试音频，避免因找不到文件导致注入静默失败。
3. **安装注销后屏幕直接常驻悬浮**：无需任何按键，注销后直接在屏幕顶层展现绿色 `[🎙️ 注入音频]` 胶囊。长按音量下键 0.6 秒随时收起/唤出。

---

## 🌟 核心功能与技术实现

### 1. 极速触控响应与双重事件保障 (v1.5.0)
- **手势防吞食**：将 `UIPanGestureRecognizer` 设为与 `UITapGestureRecognizer` 互斥识别（`requireGestureRecognizerToFail:`），彻底解决此前拖拽手势吞食点击事件导致的“按了没反应”。
- **零延迟界面与震动反馈**：点击瞬间立即触发 Heavy 触觉震动反馈、弹性缩放按压动画，并立即在主线程将按钮切换为红色 `[⏹ 停止注入]`，无需等待底层跨进程 IPC 响应。
- **12pt 点击热区扩展**：在 `hitTest:` 中对胶囊按钮四周扩展 12pt 热区，单手轻触也能精准命中。

### 2. 内置默认测试音频 (v1.5.0)
- 启动或点击注入时若检测到 `/var/mobile/Media/inject_audio.wav` 不存在，将自动合成一段 16kHz 16-bit PCM 测试音频并赋予读写权限，真正做到安装即用，随时验证通话效果。

### 3. 双 Dylib 架构
- `CallAudioInjector.dylib`：专职注入 `mediaserverd`，拦截 CoreAudio `AudioUnitRender`（Bus 1 麦克风录音链路），实现对端清晰收听。
- `CallAudioInjectorUI.dylib`：专职注入 `SpringBoard`，提供全局穿透悬浮窗与按键捕获。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml               # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                        # Theos 编译配置 (双 Dylib, Rootless, arm64 + arm64e)
├── control                         # Debian 软件包元数据 (v1.5.0)
├── CallAudioInjector.plist         # 服务端过滤 (mediaserverd)
├── CallAudioInjectorUI.plist       # UI 模块过滤 (com.apple.springboard)
├── TweakServer.x                   # 底层音频流注入与格式自适应重采样
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
   packages/com.tlsf.callaudioinjector_1.5.0_iphoneos-arm64.deb
   ```
2. 在设备上安装并注销：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.5.0_iphoneos-arm64.deb
   killall -9 mediaserverd SpringBoard
   ```
3. **注销完成后，屏幕右上方会直接出现绿色的 `[🎙️ 注入音频]` 悬浮胶囊！**

---

## 🕹️ 使用指南

1. **点击注入音频**：接通电话/VoIP语音后，点击悬浮胶囊立即震动并变为红色 `[⏹ 停止注入]`，音频注入麦克风流，**对方即可听到**；再次点击停止注入。
2. **自由拖拽**：用手指按住拖动悬浮胶囊到屏幕任意位置，松手带物理弹簧阻尼吸附靠边。
3. **长按音量下键显隐**：按住机身左侧「音量下键」约 0.6 秒即可隐藏悬浮窗；再次长按重新唤出。

---

## 🎵 自定义音频文件替换

默认音频路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(插件支持常见的 `.wav`、`.mp3`、`.m4a` 格式，放置后执行 `chmod 644 /var/mobile/Media/inject_audio.wav` 即可自动解码与重采样)*

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
git commit -m "fix: touch hit-testing, immediate visual feedback, and auto test audio fallback (v1.5.0)"
git tag -a v1.5.0 -m "Release v1.5.0: fix button touch responsiveness"
git push origin main --tags
```
