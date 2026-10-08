#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <substrate.h>

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define DEFAULT_AUDIO_PATH @"/var/mobile/Media/inject_audio.wav"

// 通知定义
#define NOTIFY_PLAY       "com.tlsf.callaudioinjector.play"
#define NOTIFY_STOP       "com.tlsf.callaudioinjector.stop"
#define NOTIFY_TOGGLE     "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE      "com.tlsf.callaudioinjector.state_changed"

// ============================================================================
// PART 1: mediaserverd 注入音频核心引擎 (针对通话麦克风链路)
// ============================================================================

static BOOL g_isInjecting = NO;
static BOOL g_loopPlayback = YES;
static BOOL g_muteMic = NO;
static float g_gain = 1.0f;
static NSString *g_audioFilePath = DEFAULT_AUDIO_PATH;

// 缓存解码后的 PCM 数据
static UInt8 *g_pcmBuffer = NULL;
static UInt32 g_pcmBufferBytes = 0;
static UInt32 g_pcmTotalFrames = 0;
static UInt32 g_pcmFrameOffset = 0;
static AudioStreamBasicDescription g_cachedASBD;
static BOOL g_hasCachedASBD = NO;

// 原始 AudioUnitRender 函数指针
static OSStatus (*orig_AudioUnitRender)(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inOutputBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData);

static void ReloadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREF_PATH];
    if (prefs) {
        g_audioFilePath = prefs[@"audioPath"] ?: DEFAULT_AUDIO_PATH;
        g_loopPlayback = prefs[@"loopPlayback"] ? [prefs[@"loopPlayback"] boolValue] : YES;
        g_muteMic = prefs[@"muteMic"] ? [prefs[@"muteMic"] boolValue] : NO;
        g_gain = prefs[@"gain"] ? [prefs[@"gain"] floatValue] : 1.0f;
    } else {
        g_audioFilePath = DEFAULT_AUDIO_PATH;
        g_loopPlayback = YES;
        g_muteMic = NO;
        g_gain = 1.0f;
    }
}

static void FreePCMBuffer(void) {
    if (g_pcmBuffer) {
        free(g_pcmBuffer);
        g_pcmBuffer = NULL;
    }
    g_pcmBufferBytes = 0;
    g_pcmTotalFrames = 0;
    g_pcmFrameOffset = 0;
    g_hasCachedASBD = NO;
}

// 广播当前播放状态给全局
static void BroadcastInjectionState(BOOL active) {
    int token = 0;
    notify_register_check(NOTIFY_STATE, &token);
    notify_set_state(token, active ? 1 : 0);
    notify_post(NOTIFY_STATE);
}

// 使用 CoreAudio ExtAudioFile 将音频文件解码并重采样为指定格式
static BOOL LoadAudioFileForFormat(const AudioStreamBasicDescription *targetASBD) {
    ReloadPreferences();
    FreePCMBuffer();

    if (![[NSFileManager defaultManager] fileExistsAtPath:g_audioFilePath]) {
        NSLog(@"[CallAudioInjector] 错误: 音频文件不存在: %@", g_audioFilePath);
        return NO;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:g_audioFilePath];
    ExtAudioFileRef audioFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
    if (status != noErr || !audioFile) {
        NSLog(@"[CallAudioInjector] 打开音频文件失败, 错误码: %d, 路径: %@", (int)status, g_audioFilePath);
        return NO;
    }

    // 设置目标客户端数据格式（由 CoreAudio 自动完成重采样和声道转换）
    status = ExtAudioFileSetProperty(audioFile,
                                     kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription),
                                     targetASBD);
    if (status != noErr) {
        NSLog(@"[CallAudioInjector] 设置 ClientDataFormat 失败, 错误码: %d", (int)status);
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    // 获取音频总帧数
    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);
    if (status != noErr || totalFrames <= 0) {
        NSLog(@"[CallAudioInjector] 获取音频帧数失败: %d", (int)status);
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    UInt32 bytesPerFrame = targetASBD->mBytesPerFrame;
    if (bytesPerFrame == 0) {
        bytesPerFrame = (targetASBD->mBitsPerChannel / 8) * targetASBD->mChannelsPerFrame;
    }
    UInt32 totalBytes = (UInt32)(totalFrames * bytesPerFrame);

    g_pcmBuffer = (UInt8 *)malloc(totalBytes);
    if (!g_pcmBuffer) {
        NSLog(@"[CallAudioInjector] 内存分配失败, 需要字节: %u", (unsigned int)totalBytes);
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    AudioBufferList fillBufList;
    fillBufList.mNumberBuffers = 1;
    fillBufList.mBuffers[0].mNumberChannels = targetASBD->mChannelsPerFrame;
    fillBufList.mBuffers[0].mDataByteSize = totalBytes;
    fillBufList.mBuffers[0].mData = g_pcmBuffer;

    UInt32 framesToRead = (UInt32)(totalFrames);
    status = ExtAudioFileRead(audioFile, &framesToRead, &fillBufList);
    if (status != noErr) {
        NSLog(@"[CallAudioInjector] 读取 PCM 失败: %d", (int)status);
        FreePCMBuffer();
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    g_pcmBufferBytes = fillBufList.mBuffers[0].mDataByteSize;
    g_pcmTotalFrames = framesToRead;
    g_pcmFrameOffset = 0;
    g_cachedASBD = *targetASBD;
    g_hasCachedASBD = YES;

    NSLog(@"[CallAudioInjector] 音频加载成功! 采样率: %.1f Hz, 帧数: %u, 总字节: %u",
          targetASBD->mSampleRate, (unsigned int)g_pcmTotalFrames, (unsigned int)g_pcmBufferBytes);

    ExtAudioFileDispose(audioFile);
    return YES;
}

// 混音与 PCM 写入核心函数
static void InjectAudioIntoBufferList(AudioUnit inUnit, AudioBufferList *ioData, UInt32 inNumberFrames) {
    if (!g_isInjecting || ioData == NULL || inNumberFrames == 0) {
        return;
    }

    AudioStreamBasicDescription currentASBD;
    UInt32 asbdSize = sizeof(currentASBD);
    OSStatus status = AudioUnitGetProperty(inUnit,
                                           kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output,
                                           1, // Bus 1: Mic / Uplink
                                           &currentASBD,
                                           &asbdSize);
    if (status != noErr) {
        return;
    }

    BOOL needReload = NO;
    if (!g_hasCachedASBD || g_pcmBuffer == NULL) {
        needReload = YES;
    } else {
        if (g_cachedASBD.mSampleRate != currentASBD.mSampleRate ||
            g_cachedASBD.mChannelsPerFrame != currentASBD.mChannelsPerFrame ||
            g_cachedASBD.mFormatFlags != currentASBD.mFormatFlags) {
            needReload = YES;
        }
    }

    if (needReload) {
        if (!LoadAudioFileForFormat(&currentASBD)) {
            g_isInjecting = NO;
            BroadcastInjectionState(NO);
            return;
        }
    }

    if (g_pcmTotalFrames == 0 || g_pcmBuffer == NULL) {
        return;
    }

    UInt32 remainingFrames = g_pcmTotalFrames - g_pcmFrameOffset;
    UInt32 framesToMix = (inNumberFrames < remainingFrames) ? inNumberFrames : remainingFrames;
    if (framesToMix == 0) {
        if (g_loopPlayback) {
            g_pcmFrameOffset = 0;
            remainingFrames = g_pcmTotalFrames;
            framesToMix = (inNumberFrames < remainingFrames) ? inNumberFrames : remainingFrames;
        } else {
            g_isInjecting = NO;
            g_pcmFrameOffset = 0;
            BroadcastInjectionState(NO);
            return;
        }
    }

    BOOL isFloat = (currentASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 bytesPerFrame = currentASBD.mBytesPerFrame;
    if (bytesPerFrame == 0) {
        bytesPerFrame = (currentASBD.mBitsPerChannel / 8) * currentASBD.mChannelsPerFrame;
    }

    UInt8 *injectFramePtr = g_pcmBuffer + (g_pcmFrameOffset * bytesPerFrame);

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (buf->mData == NULL) continue;

        if (isFloat) {
            // 32-bit Float PCM 混音
            Float32 *mic = (Float32 *)buf->mData;
            Float32 *inj = (Float32 *)injectFramePtr;
            UInt32 samples = framesToMix * buf->mNumberChannels;

            for (UInt32 s = 0; s < samples; s++) {
                float injVal = inj[s] * g_gain;
                if (g_muteMic) {
                    mic[s] = injVal;
                } else {
                    float sum = mic[s] + injVal;
                    if (sum > 1.0f) sum = 1.0f;
                    else if (sum < -1.0f) sum = -1.0f;
                    mic[s] = sum;
                }
            }
        } else if (currentASBD.mBitsPerChannel == 16) {
            // 16-bit Signed Integer PCM 混音
            SInt16 *mic = (SInt16 *)buf->mData;
            SInt16 *inj = (SInt16 *)injectFramePtr;
            UInt32 samples = framesToMix * buf->mNumberChannels;

            for (UInt32 s = 0; s < samples; s++) {
                int32_t injVal = (int32_t)(inj[s] * g_gain);
                if (g_muteMic) {
                    if (injVal > 32767) injVal = 32767;
                    else if (injVal < -32768) injVal = -32768;
                    mic[s] = (SInt16)injVal;
                } else {
                    int32_t sum = (int32_t)mic[s] + injVal;
                    if (sum > 32767) sum = 32767;
                    else if (sum < -32768) sum = -32768;
                    mic[s] = (SInt16)sum;
                }
            }
        }
    }

    g_pcmFrameOffset += framesToMix;

    if (g_pcmFrameOffset >= g_pcmTotalFrames) {
        if (g_loopPlayback) {
            g_pcmFrameOffset = 0;
        } else {
            g_isInjecting = NO;
            g_pcmFrameOffset = 0;
            BroadcastInjectionState(NO);
        }
    }
}

// Hook AudioUnitRender (麦克风音频采集流)
static OSStatus my_AudioUnitRender(AudioUnit inUnit,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inOutputBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);

    // inOutputBusNumber == 1: 麦克风录音总线
    if (status == noErr && inOutputBusNumber == 1 && g_isInjecting && ioData != NULL) {
        InjectAudioIntoBufferList(inUnit, ioData, inNumberFrames);
    }

    return status;
}

// ============================================================================
// PART 2: SpringBoard 专属 —— 全局顶级悬浮窗与按键捕获 (iOS 17 Only)
// ============================================================================

@interface CAIFloatingWindow : UIWindow
@end

@implementation CAIFloatingWindow
// iOS 17 安全窗口，允许在锁屏与应用顶层展示
- (BOOL)_isSecure {
    return YES;
}
- (BOOL)_canBecomeKeyWindow {
    return NO;
}
// 只拦截点击在悬浮胶囊按钮上的事件，其余大面积透明区域全部穿透给系统/前台 App！
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}
@end

static CAIFloatingWindow *g_floatingWindow = nil;
static UIButton *g_floatingButton = nil;
static NSTimeInterval g_lastLongPressTriggerTime = 0;

static void UpdateFloatingButtonUI(BOOL active) {
    if (!g_floatingButton) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (active) {
            [g_floatingButton setTitle:@"⏹ 停止注入" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.92 green:0.25 blue:0.25 alpha:0.95];
        } else {
            [g_floatingButton setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.38 alpha:0.92];
        }
    });
}

static void OnFloatingButtonClicked(void) {
    notify_post(NOTIFY_TOGGLE);
}

// 为根控制器添加拖拽与点击动作
@interface UIViewController (CAIFloatingButtonActions)
- (void)toggleAudioAction;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation UIViewController (CAIFloatingButtonActions)
- (void)toggleAudioAction {
    OnFloatingButtonClicked();
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint translation = [pan translationInView:btn.superview];
    CGPoint newCenter = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat halfW = btn.bounds.size.width / 2.0;
    CGFloat halfH = btn.bounds.size.height / 2.0;
    CGFloat minX = halfW + 10;
    CGFloat maxX = screenSize.width - halfW - 10;
    CGFloat minY = halfH + 45; // 避开灵动岛
    CGFloat maxY = screenSize.height - halfH - 40; // 避开底部手势条

    if (newCenter.x < minX) newCenter.x = minX;
    if (newCenter.x > maxX) newCenter.x = maxX;
    if (newCenter.y < minY) newCenter.y = minY;
    if (newCenter.y > maxY) newCenter.y = maxY;

    btn.center = newCenter;
    [pan setTranslation:CGPointZero inView:btn.superview];

    // 松手时吸附至就近边缘
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat targetX = (newCenter.x < screenSize.width / 2.0) ? (halfW + 16) : (screenSize.width - halfW - 16);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:0 animations:^{
            btn.center = CGPointMake(targetX, btn.center.y);
        } completion:nil];
    }
}
@end

static void EnsureFloatingWindowCreated(void) {
    if (g_floatingWindow) return;

    UIWindowScene *activeScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }
    if (!activeScene) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (activeScene) {
        g_floatingWindow = [[CAIFloatingWindow alloc] initWithWindowScene:activeScene];
    } else {
        g_floatingWindow = [[CAIFloatingWindow alloc] initWithFrame:screenBounds];
    }

    g_floatingWindow.frame = screenBounds;
    g_floatingWindow.windowLevel = 10000000.0f; // 置于全局顶层，覆盖所有 App
    g_floatingWindow.backgroundColor = [UIColor clearColor];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    rootVC.view.frame = screenBounds;
    g_floatingWindow.rootViewController = rootVC;

    // 悬浮胶囊按钮设计
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(screenBounds.size.width - 130 - 16, 120, 130, 48);
    btn.layer.cornerRadius = 24.0;
    btn.layer.masksToBounds = YES;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    btn.layer.borderWidth = 1.0;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [btn setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.38 alpha:0.92];

    [btn addTarget:rootVC action:@selector(toggleAudioAction) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:rootVC action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];

    [rootVC.view addSubview:btn];
    g_floatingButton = btn;

    g_floatingWindow.hidden = YES;
    g_floatingWindow.alpha = 0.0f;
}

// 任何时候长按电源键，显隐悬浮窗口
static void ToggleFloatingWindowInSpringBoard(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastLongPressTriggerTime < 1.2) {
        return; // 1.2 秒防抖
    }
    g_lastLongPressTriggerTime = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        EnsureFloatingWindowCreated();

        // iOS 17 触觉震动反馈
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback prepare];
        [feedback impactOccurred];

        if (g_floatingWindow.hidden || g_floatingWindow.alpha < 0.1f) {
            // 唤出显示 (iOS 17 弹簧阻尼动画)
            g_floatingWindow.hidden = NO;
            g_floatingWindow.alpha = 0.0f;
            g_floatingButton.transform = CGAffineTransformMakeScale(0.7, 0.7);
            [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.8 options:0 animations:^{
                g_floatingWindow.alpha = 1.0f;
                g_floatingButton.transform = CGAffineTransformIdentity;
            } completion:nil];
            NSLog(@"[CallAudioInjector] 任何时候长按电源键 -> 悬浮窗已展示");
        } else {
            // 隐藏
            [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
                g_floatingWindow.alpha = 0.0f;
                g_floatingButton.transform = CGAffineTransformMakeScale(0.75, 0.75);
            } completion:^(BOOL finished) {
                g_floatingWindow.hidden = YES;
                g_floatingButton.transform = CGAffineTransformIdentity;
            }];
            NSLog(@"[CallAudioInjector] 任何时候长按电源键 -> 悬浮窗已隐藏");
        }
    });
}

%group SpringBoardHooks

// Hook 1: SBSiriHardwareButtonInteraction (iOS 17 侧边键长按事件拦截，阻断 Siri 唤起)
%hook SBSiriHardwareButtonInteraction
- (void)observeLongPressDidBegin {
    ToggleFloatingWindowInSpringBoard();
    // 拦截长按，不调用 %orig，防止唤起 Siri
}

- (BOOL)consumeLongPressUp {
    return YES;
}
%end

// Hook 2: SBHBLongPressGestureRecognizer (SpringBoard 硬件按键长按通用手势识别器)
%hook SBHBLongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    if (state == UIGestureRecognizerStateBegan) {
        ToggleFloatingWindowInSpringBoard();
    }
    %orig;
}
%end

%end // SpringBoardHooks

// ============================================================================
// PART 3: 构造入口与生命周期分发
// ============================================================================

static void HandleDarwinNotifications(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    NSString *notifyName = (__bridge NSString *)name;
    if ([notifyName isEqualToString:@NOTIFY_PLAY]) {
        ReloadPreferences();
        g_isInjecting = YES;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] mediaserverd 收到 PLAY");
        BroadcastInjectionState(YES);
    } else if ([notifyName isEqualToString:@NOTIFY_STOP]) {
        g_isInjecting = NO;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] mediaserverd 收到 STOP");
        BroadcastInjectionState(NO);
    } else if ([notifyName isEqualToString:@NOTIFY_TOGGLE]) {
        ReloadPreferences();
        g_isInjecting = !g_isInjecting;
        if (g_isInjecting) {
            g_pcmFrameOffset = 0;
        }
        NSLog(@"[CallAudioInjector] mediaserverd 收到 TOGGLE, 当前状态: %d", g_isInjecting);
        BroadcastInjectionState(g_isInjecting);
    }
}

static void HandleStateChangedNotification(CFNotificationCenterRef center,
                                           void *observer,
                                           CFStringRef name,
                                           const void *object,
                                           CFDictionaryRef userInfo) {
    // SpringBoard 收到 mediaserverd 的状态通知，更新悬浮按钮颜色与文字
    int token = 0;
    notify_register_check(NOTIFY_STATE, &token);
    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    UpdateFloatingButtonUI(state == 1);
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];

        // 1. mediaserverd：系统级音频流拦截与注入
        if ([processName isEqualToString:@"mediaserverd"]) {
            NSLog(@"[CallAudioInjector] 注入 mediaserverd 成功");
            ReloadPreferences();

            void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
            if (symbol) {
                MSHookFunction(symbol, (void *)my_AudioUnitRender, (void **)&orig_AudioUnitRender);
                NSLog(@"[CallAudioInjector] AudioUnitRender Hook 成功");
            } else {
                NSLog(@"[CallAudioInjector] 未找到 AudioUnitRender 符号");
            }

            CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_PLAY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_STOP), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_TOGGLE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // 2. SpringBoard：iOS 17 全局悬浮窗与任何时候长按电源键捕获
        if ([processName isEqualToString:@"SpringBoard"]) {
            NSLog(@"[CallAudioInjector] 注入 SpringBoard 成功，注册长按电源键拦截与全局悬浮窗");
            %init(SpringBoardHooks);

            CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(darwin, NULL, HandleStateChangedNotification, CFSTR(NOTIFY_STATE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}
