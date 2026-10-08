# CallAudioInjector (iOS 15 - 17 越狱插件)

CallAudioInjector 是一款专为 iOS 15 - 17（Rootless 无根越狱架构，如 Dopamine、palera1n）设计的系统级通话音频注入插件。

本插件能够在通话过程中，将本地指定的音频文件解码并实时混入（或替换）麦克风采集音频流（Uplink / Bus 1），**实现通话对端（对方）清晰听到指定音频**。

---

## 🌟 特性功能

1. **对方听到（Uplink 麦克风注入）**：
   - 拦截系统底层 `mediaserverd` 的 `AudioUnitRender` 函数。
   - 截获麦克风采集数据，实现与原声混音（Mix）或麦克风静音独占播放（Replace）。
2. **多格式自动重采样（无杂音/无变调）**：
   - 基于 Apple CoreAudio `ExtAudioFile`，无论源音频是 WAV、MP3 还是 M4A，均会自动根据当前通话硬件采样率（如 16kHz/24kHz/48kHz）进行实时重采样与声道对齐。
   - 支持 16-bit 线性 PCM 与 32-bit Float PCM 混音，内置饱和度截断算法防止爆音。
3. **通话悬浮控制按钮**：
   - 接通电话时自动在 `InCallService`（通话界面）上提供可自由拖拽的半透明悬浮胶囊按钮：`[🎙️ 注入音频]` / `[⏹ 停止注入]`。
   - 点击即可瞬间开启或停止注入，状态实时切换。
4. **灵活触发与自动化**：
   - 支持全局 Darwin 通知触发（可在快捷指令/终端调用 `notify_post`）。
   - 支持设置“接通电话自动开始播放”。
   - 支持单曲循环播放与音量增益调节。
5. **现代架构兼容**：
   - 兼容 iOS 15.0 ~ 17.x。
   - 适配 Rootless 方案（ElleKit / MobileSubstrate，支持 arm64 与 arm64e / PAC）。
   - 配备 GitHub Actions 持续集成与自动化 Release 打包。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 自动化构建 & Release 工作流
├── Makefile                      # Theos 编译配置 (Rootless, arm64 + arm64e)
├── control                       # Debian 软件包元数据
├── CallAudioInjector.plist       # 进程过滤 (mediaserverd & InCallService)
├── Tweak.x                       # 插件核心源码 (CoreAudio Hook & 悬浮窗)
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
make package FINALPACKAGE=1

# 3. 生成的 deb 文件位于 packages/ 目录下
ls -lh packages/
```

> **提示**：若要在手机上快速安装并测试，可设置手机 IP 运行：
> ```bash
> make do THEOS_DEVICE_IP=192.168.1.xxx
> ```

---

## 📲 安装与部署

1. 将生成的 `.deb` 文件（如 `com.tlsf.callaudioinjector_1.0.0_iphoneos-arm64.deb`）传输到手机。
2. 使用 **Sileo**、**Zebra**、**Filza** 或终端安装：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.0.0_iphoneos-arm64.deb
   ```
3. 重启音频服务以确保插件载入：
   ```bash
   killall -9 mediaserverd
   ```

---

## 🎵 音频文件准备与配置

### 1. 放置音频文件
默认音频文件路径为：
```text
/var/mobile/Media/inject_audio.wav
```
*(也可以是 `.mp3` 或 `.m4a`，在配置文件中指定即可)*

**重要**：放置音频后，请确保文件拥有读取权限：
```bash
chmod 644 /var/mobile/Media/inject_audio.wav
```

### 2. 配置文件选项
可在 `/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist` 中自定义配置（修改后实时生效或通过通知重载）：

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

    <!-- 是否将麦克风静音（NO: 混音模式，对方既能听见你也能听见音频；YES: 仅播放音频） -->
    <key>muteMic</key>
    <false/>

    <!-- 音量增益倍数 (1.0 为原始音量) -->
    <key>gain</key>
    <real>1.0</real>

    <!-- 通话接通时是否自动播放 (YES / NO) -->
    <key>autoPlayOnCall</key>
    <false/>

    <!-- 是否在通话界面显示悬浮控制按钮 -->
    <key>showFloatingButton</key>
    <true/>
</dict>
</plist>
```

---

## 🕹️ 控制方式

### 方式一：通话界面悬浮按钮
接通电话时，通话屏幕上方会出现绿色 `[🎙️ 注入音频]` 按钮：
- 点击变为红色 `[⏹ 停止注入]`，音频开始混入麦克风流传输给对方；
- 再次点击停止；
- 按钮支持任意拖动位置。

### 方式二：命令行 / 快捷指令 (Darwin 通知)
通过终端命令或越狱快捷指令插件触发广播：
```bash
# 开始播放
notify_post com.tlsf.callaudioinjector.play

# 停止播放
notify_post com.tlsf.callaudioinjector.stop

# 切换播放/停止
notify_post com.tlsf.callaudioinjector.toggle
```

---

## 🚀 GitHub 版本管理与发布

本项目已配置 `.github/workflows/build.yml` 工作流。

### 1. 关联并推送到 GitHub 远程仓库
```bash
# 初始化并提交本地修改
git init
git add .
git commit -m "feat: initial commit for CallAudioInjector v1.0.0"

# 使用 GitHub CLI 一键创建远程仓库（或手动在 GitHub 网页新建）
gh repo create CallAudioInjector --public --source=. --push
```

### 2. 发布新版本（自动化生成 Release & Deb）
当需要发布新版本时，只需打 Tag 并推送至 GitHub：
```bash
# 1. 修改 control 中的 Version: 1.0.1
# 2. 提交并打标签
git add control
git commit -m "release: v1.0.1"
git tag -a v1.0.1 -m "Release version 1.0.1"
git push origin main --tags
```
GitHub Actions 将自动执行编译、生成 arm64/arm64e 双架构 rootless deb，并将 deb 文件直接挂载到该 GitHub Release 附件中供下载！
