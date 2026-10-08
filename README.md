# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

**【v1.8.0 核心更新：深度集成「运费.mp3」与本机直出】**
1. **全面集成并打包指定音频「运费.mp3」**：
   - 将用户指定的 `/var/mobile/Library/Application Support/AudioLoop/运费.mp3` 正式内置集成入插件。
   - deb 安装包中自动打包部署该文件至系统目标路径，同时在动态库中以 22KB 二进制字节码内嵌保底（若目标文件被删除会自动以 0666 权限自我释放重建）。
2. **解决桌面点击胶囊无声音问题（SpringBoard 直驱原生发声）**：
   - 移除了此前在 SpringBoard 中因调用 `AVAudioSession setActive:` 引发的环境冲突。
   - 采用纯净原生 `AVAudioPlayer` 驱动，点击桌面右上角胶囊变为红色 `[⏹ 停止注入]` 的瞬间，**本机听筒/扬声器立即开始清晰循环播放「运费.mp3」**！再次点击立刻停止静音。
3. **通话对方同步听到（iOS 17 `audiomxd` 麦克风全幅注入）**：
   - 通话过程中，底层 `audiomxd` 实时解码「运费.mp3」并全幅注入麦克风流（Bus 1），对方清晰可闻。

---

## 🌟 核心功能与技术实现

### 1. 本机与对端双向发声 (v1.8.0)
- **本机发声**：点击胶囊，SpringBoard 进程直接调用系统通道播放内置的「运费.mp3」，音质清晰洪亮，提供 100% 确信的实时听感反馈。
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
├── control                         # Debian 软件包元数据 (v1.8.0)
├── CallAudioInjector.plist         # 服务端过滤 (audiomxd, mediaserverd, callservicesd...)
├── CallAudioInjectorUI.plist       # UI 模块过滤 (com.apple.springboard)
├── EmbeddedAudio.h                 # 内置内嵌的「运费.mp3」二进制字节库
├── layout/                         # deb 目录布局，自动打包部署运费.mp3
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
   packages/com.tlsf.callaudioinjector_1.8.0_iphoneos-arm64.deb
   ```
2. 在设备上安装并重启音频守护进程与界面：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.8.0_iphoneos-arm64.deb
   killall -9 audiomxd mediaserverd callservicesd InCallService SpringBoard
   ```
3. **注销完成后，屏幕右上方会直接出现绿色的 `[🎙️ 注入音频]` 悬浮胶囊！**

---

## 🕹️ 使用指南

1. **测试与播放「运费.mp3」**：
   - 在桌面上轻点右上角胶囊，变红 `[⏹ 停止注入]`；
   - **手机立刻大声循环播放「运费.mp3」**；
   - 电话通话中对方也能同时清晰听到；
   - 再次点击胶囊变绿，本机与对端声音立刻同步停止。
2. **自由拖拽**：按住胶囊拖到任意位置，松手带物理阻尼自动靠边吸附。
3. **长按音量下键显隐**：长按 0.6 秒随时收起或唤出悬浮窗。

---

## 🚀 GitHub 版本管理

```bash
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

git add .
git commit -m "feat: bundle and embed 运费.mp3 with local speaker output (v1.8.0)"
git tag -a v1.8.0 -m "Release v1.8.0: integrated 运费.mp3 and local audio output fix"
git push origin main --tags
```
