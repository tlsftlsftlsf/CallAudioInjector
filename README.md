# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

支持**在任何时候长按机身音量下键（Volume Down）唤出/隐藏全局悬浮控制胶囊**，并在通话过程中将指定音频文件实时混入麦克风采集音频流（Uplink / Bus 1），**让通话另一方（对方）清晰听到指定音频**。

---

## 🌟 v1.3.0 核心更新与交互升级

1. **按键触发全面迁移至「长按音量下键」**：
   - 深入 Hook `SpringBoard` 的物理音量按键链路：`SBVolumeHardwareButtonActions`（`volumeDecreasePressDown` / `volumeDecreasePressUp`）。
   - **按下音量下键超过 0.6 秒**直接判定为长按，触发触觉震动并显隐全局悬浮窗；
   - 长按期间自动 Hook `SBVolumeControl`（`decreaseVolume`），**防止音量被连续递减归零**；
   - 快速短按音量下键仍保持正常的系统调小音量功能。
2. **底层渲染管线修复（彻底解决悬浮窗不显示的问题）**：
   - 采用标准 SpringBoard 窗口挂载模式：在 `applicationDidFinishLaunching:` 时期使用有效 `UIWindowScene` 创建 `CAIPassThroughWindow`；
   - 关键修复：**调用 `makeKeyAndVisible` 将图层强行挂载入系统的渲染树管线（Render Server Pipeline）**，然后设置为 `hidden = YES`。避免此前由于图层未曾注册至渲染管线导致 `hidden = NO` 时仍不渲染的问题。
3. **全穿透触控交互**：
   - 重写 `hitTest:`：仅悬浮胶囊本身响应触控与拖动，背景大面积透明区域 100% 穿透至底层屏幕。
4. **对方听到（系统底层麦克风注入）**：
   - 注入 `mediaserverd`，Hook `AudioUnitRender`（Bus 1 麦克风录音端），自动重采样并混入 PCM 音频。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                      # Theos 编译配置 (Rootless, arm64 + arm64e)
├── control                       # Debian 软件包元数据 (v1.3.0, 限制 firmware >= 17.0)
├── CallAudioInjector.plist       # 进程过滤 (mediaserverd & SpringBoard)
├── Tweak.x                       # 插件核心源码 (AudioUnit Hook, 音量下键长按, 全局悬浮窗)
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
   packages/com.tlsf.callaudioinjector_1.3.0_iphoneos-arm64.deb
   ```
2. 在设备上安装并注销：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.3.0_iphoneos-arm64.deb
   killall -9 mediaserverd SpringBoard
   ```

---

## 🕹️ 使用方法与快捷测试

1. **物理按键唤出**：
   - 在任何界面（桌面、锁屏、设置、微信或通话中）**按住机身左侧「音量下键」约 0.6 秒**；
   - 手机会产生一次轻触触觉震动反馈，屏幕立刻弹出绿色 `[🎙️ 注入音频]` 胶囊按钮！
   - 再次长按音量下键，悬浮胶囊平滑淡出收起。
2. **终端快捷命令测试**（无需按物理键）：
   ```bash
   notify_post com.tlsf.callaudioinjector.toggle_ui
   ```
3. **查看实时日志**：
   ```bash
   oslog | grep CallAudioInjector
   ```

---

## 🎵 音频文件准备与配置

默认音频路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(支持 `.wav`、`.mp3`、`.m4a`，放置后执行 `chmod 644 /var/mobile/Media/inject_audio.wav`)*

在 `/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist` 中可调节混音模式与音量：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>audioPath</key>
    <string>/var/mobile/Media/inject_audio.wav</string>
    <!-- 是否循环播放 -->
    <key>loopPlayback</key>
    <true/>
    <!-- 是否静音自己麦克风（NO 为混音模式，对方既能听见你也能听见音频；YES 仅放音频） -->
    <key>muteMic</key>
    <false/>
    <!-- 播放音量增益倍数 -->
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
git commit -m "feat: switch trigger to long press volume down button and fix window rendering pipeline (v1.3.0)"
git tag -a v1.3.0 -m "Release v1.3.0: long press volume down trigger"
git push origin main --tags
```
