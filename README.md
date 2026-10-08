# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

**【v1.4.0 核心更新】安装后直接在屏幕顶层显示悬浮窗口，无需按任何按键！**
同时支持**长按音量下键随时隐藏/唤出悬浮窗**，并在通话过程中将指定音频文件实时混入麦克风采集音频流（Uplink / Bus 1），**让通话另一方（对方）清晰听到指定音频**。

---

## 🌟 v1.4.0 架构升级与“不显示”问题根本解决

### 1. 彻底解决“悬浮窗不显示”：双 Dylib 架构分离
- 此前由于在单个 plist 中同时声明了 `Bundles`（SpringBoard）与 `Executables`（mediaserverd），在部分越狱加载器（如 ElleKit）中会导致过滤逻辑冲突，致使 SpringBoard 根本未加载 UI 模块！
- **重构为双 Dylib 独立架构**：
  - `CallAudioInjector.dylib`：专职注入 `mediaserverd`，仅处理麦克风底层 CoreAudio 音频混合。
  - `CallAudioInjectorUI.dylib`：专职注入 `SpringBoard`，仅处理全局穿透悬浮窗与按键交互。
  - 两个模块通过 Darwin 跨进程通信，彻底消除了加载器冲突。

### 2. 安装/注销完成后「直接在屏幕显示悬浮窗」
- 移除了启动时的 `hidden = YES`，窗口创建后**直接调用 `makeKeyAndVisible` 并保持常驻可见**！
- 安装 deb 并注销（Respring）后，屏幕右上侧**立刻出现**绿色 `[🎙️ 注入音频]` 胶囊悬浮按钮，无需额外摸索触发！

### 3. 长按音量下键收起/唤出（Volume Down）
- 胶囊支持全屏幕自由拖拽，松手带物理阻尼吸附靠边。
- 若觉得常驻遮挡，**按住机身左侧「音量下键」0.6 秒**即可平滑收起隐藏；再次长按音量下键重新唤出。
- 长按期间自动抑制音量连续递减，短按则保持原本的调小音量功能。

### 4. 对方听到（系统底层麦克风链路注入）
- 拦截 CoreAudio `AudioUnitRender`（Bus 1 麦克风录音端），自动重采样并混入 PCM 音频，实现对端清晰收听。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml               # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                        # Theos 编译配置 (双 Dylib, Rootless, arm64 + arm64e)
├── control                         # Debian 软件包元数据 (v1.4.0)
├── CallAudioInjector.plist         # 服务端过滤 (mediaserverd)
├── CallAudioInjectorUI.plist       # UI 模块过滤 (com.apple.springboard)
├── TweakServer.x                   # 底层音频流注入引擎源码
├── TweakUI.x                       # SpringBoard 全局悬浮窗与按键捕获源码
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
   packages/com.tlsf.callaudioinjector_1.4.0_iphoneos-arm64.deb
   ```
2. 在设备上安装并注销：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.4.0_iphoneos-arm64.deb
   killall -9 mediaserverd SpringBoard
   ```
3. **注销完成后，屏幕右上方会直接出现绿色的 `[🎙️ 注入音频]` 悬浮胶囊！**

---

## 🕹️ 使用指南

1. **拖拽调整位置**：直接用手指拖动悬浮胶囊到舒适的位置，松手自动靠边吸附。
2. **通话时注入音频**：接通电话后，点击悬浮胶囊变为红色 `[⏹ 停止注入]`，音频混入麦克风流，对方即可清晰听到；再次点击停止注入。
3. **长按音量下键切换显隐**：按住「音量下键」约 0.6 秒可收起隐藏悬浮窗；再次长按重新唤出。

---

## 🎵 音频文件准备

默认音频路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(支持 `.wav`、`.mp3`、`.m4a`，放置后执行 `chmod 644 /var/mobile/Media/inject_audio.wav`)*

在 `/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist` 中可自由配置音量增益与静音模式：
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
git commit -m "feat: split into dual dylibs and show floating window directly on install (v1.4.0)"
git tag -a v1.4.0 -m "Release v1.4.0: direct floating window display, dual dylib architecture"
git push origin main --tags
```
