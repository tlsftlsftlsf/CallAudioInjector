# CallAudioInjector (iOS 17 专属越狱插件)

CallAudioInjector 是一款**专为 iOS 17（Rootless 无根越狱架构，Dopamine 2.x / palera1n）深度定制**的全局通话音频注入插件。

支持**在任何时候长按机身电源键（侧边键）唤出/隐藏全局悬浮控制胶囊**，并在通话过程中将指定音频文件实时混入麦克风采集音频流（Uplink / Bus 1），**让通话另一方（对方）清晰听到指定音频**。

---

## 🛠️ v1.2.1 针对“悬浮窗未显示”问题的核心排查与重构修复

此前悬浮窗未能正常显示的原因主要有三点，本版本已彻底重构解决：

1. **按键捕获机制升级为底层物理按键拦截（方案 1）**：
   - 之前使用的 `SBHBLongPressGestureRecognizer` 在 iOS 17（无物理 Home 键机型）上并非侧边电源键的识别器。
   - **现已直接 Hook `SpringBoard` 的物理按键事件 `_lockButtonDown:` 与 `_lockButtonUp:`**：
     - 用户按下电源键超过 0.65 秒时，高精度 GCD 定时器直接触发悬浮窗显隐，抬起时自动拦截锁屏动作；
     - 同时保留 `SBSiriHardwareButtonInteraction` 阻断 Siri 唤起；
     - 增加了通过终端命令行/快捷指令测试的专属广播通知：`notify_post com.tlsf.callaudioinjector.toggle_ui`。
2. **窗口宿主升级为 SpringBoard 专用的 `SBSecureWindow`**：
   - 普通 `UIWindow` 在 iOS 17 SpringBoard 多场景架构下，若未能正确绑定 active `UIWindowScene` 会被系统拒绝渲染。
   - **现已采用 SpringBoard 内部专用于顶层弹窗的 `SBSecureWindow` / `SBWindow`**，并从系统现有窗口中强绑定有效 `windowScene`，层级设定为 `10000000.0`，保证稳定绘制在所有 App 与桌面之上。
3. **窗口透明度逻辑修复**：
   - 彻底移除了导致窗口持续不可见的 `alpha = 0.0` 初始状态，改为保持 `alpha = 1.0` 并仅通过 `setHidden:` 与弹性缩放动画控制显隐，彻底避免了透明度卡在 0 导致的隐形问题。

---

## 📂 项目结构

```text
CallAudioInjector/
├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 自动化 CI 构建 & Release 工作流
├── Makefile                      # Theos 编译配置 (Rootless, arm64 + arm64e)
├── control                       # Debian 软件包元数据 (v1.2.1, 限制 firmware >= 17.0)
├── CallAudioInjector.plist       # 进程过滤 (mediaserverd & SpringBoard)
├── Tweak.x                       # 插件核心源码 (AudioUnit Hook, 物理按键拦截, SBSecureWindow)
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
   packages/com.tlsf.callaudioinjector_1.2.1_iphoneos-arm64.deb
   ```
2. 在设备上安装：
   ```bash
   dpkg -i com.tlsf.callaudioinjector_1.2.1_iphoneos-arm64.deb
   killall -9 mediaserverd SpringBoard
   ```

---

## 🕹️ 快捷调试与测试命令

安装后，若想无需按物理按键快速验证悬浮窗是否能在当前屏幕弹出，可以在手机终端执行：
```bash
notify_post com.tlsf.callaudioinjector.toggle_ui
```
执行后屏幕将立刻弹出绿色 `[🎙️ 注入音频]` 胶囊按钮！

查看插件实时加载与按键调试日志：
```bash
oslog | grep CallAudioInjector
```

---

## 🚀 GitHub 版本管理

```bash
cd /Users/tlsf/.gemini/antigravity/scratch/CallAudioInjector

git add .
git commit -m "fix: resolve floating window visibility with SBSecureWindow and SpringBoard _lockButtonDown hook (v1.2.1)"
git tag -a v1.2.1 -m "Release v1.2.1: fix floating window visibility"
git push origin main --tags
```
