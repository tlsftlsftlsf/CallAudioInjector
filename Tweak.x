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
#define NOTIFY_TOGGLE_UI  "com.tlsf.callaudioinjector.toggle_ui"

// ============================================================================
// PART 1: mediaserverd 注入音频核心引擎
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

    status = ExtAudioFileSetProperty(audioFile,
                                     kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription),
                                     targetASBD);
    if (status != noErr) {
        NSLog(@"[CallAudioInjector] 设置 ClientDataFormat 失败, 错误码: %d", (int)status);
        ExtAudioFileDispose(audioFile);
        return NO;
    }

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

// Hook AudioUnitRender
static OSStatus my_AudioUnitRender(AudioUnit inUnit,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inOutputBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);

    if (status == noErr && inOutputBusNumber == 1 && g_isInjecting && ioData != NULL) {
        InjectAudioIntoBufferList(inUnit, ioData, inNumberFrames);
    }

    return status;
}

// ============================================================================
// PART 2: SpringBoard 进程 —— 全局穿透悬浮窗与按键捕获 (iOS 17)
// ============================================================================

@interface CAIFloatingWindow : UIWindow
@end

@implementation CAIFloatingWindow
- (BOOL)_isSecure {
    return YES;
}
- (BOOL)_canBecomeKeyWindow {
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    // 只有点击到胶囊按钮本身才响应，透明背景区域全部穿透给底层系统/App！
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}
@end

static UIWindow *g_floatingWindow = nil;
static UIButton *g_floatingButton = nil;
static NSTimeInterval g_lastLongPressTriggerTime = 0;

static void UpdateFloatingButtonUI(BOOL active) {
    if (!g_floatingButton) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (active) {
            [g_floatingButton setTitle:@"⏹ 停止注入" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.92 green:0.22 blue:0.22 alpha:0.95];
        } else {
            [g_floatingButton setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.38 alpha:0.95];
        }
    });
}

static void OnFloatingButtonClicked(void) {
    NSLog(@"[CallAudioInjector] 悬浮按钮被点击，发送 TOGGLE 通知");
    notify_post(NOTIFY_TOGGLE);
}

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
    CGFloat minY = halfH + 45;
    CGFloat maxY = screenSize.height - halfH - 40;

    if (newCenter.x < minX) newCenter.x = minX;
    if (newCenter.x > maxX) newCenter.x = maxX;
    if (newCenter.y < minY) newCenter.y = minY;
    if (newCenter.y > maxY) newCenter.y = maxY;

    btn.center = newCenter;
    [pan setTranslation:CGPointZero inView:btn.superview];

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

    // 1. 获取 SpringBoard 当前可靠的 WindowScene
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            activeScene = (UIWindowScene *)scene;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                break;
            }
        }
    }

    if (!activeScene) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.windowScene) {
                activeScene = w.windowScene;
                break;
            }
        }
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;

    // 2. 优先采用 SpringBoard 自身的 SBSecureWindow
    Class sbSecureWindowClass = objc_getClass("SBSecureWindow");
    if (!sbSecureWindowClass) {
        sbSecureWindowClass = objc_getClass("SBWindow");
    }

    if (sbSecureWindowClass && activeScene) {
        g_floatingWindow = [[sbSecureWindowClass alloc] initWithWindowScene:activeScene];
        NSLog(@"[CallAudioInjector] 使用 SBSecureWindow 创建悬浮窗成功");
    } else if (activeScene) {
        g_floatingWindow = [[CAIFloatingWindow alloc] initWithWindowScene:activeScene];
        NSLog(@"[CallAudioInjector] 使用 CAIFloatingWindow(activeScene) 创建悬浮窗成功");
    } else {
        g_floatingWindow = [[CAIFloatingWindow alloc] initWithFrame:screenBounds];
        NSLog(@"[CallAudioInjector] 警告: 未找到 WindowScene, 使用 initWithFrame 创建");
    }

    g_floatingWindow.frame = screenBounds;
    g_floatingWindow.windowLevel = 10000000.0f; // 顶层窗口
    g_floatingWindow.backgroundColor = [UIColor clearColor];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    rootVC.view.frame = screenBounds;
    g_floatingWindow.rootViewController = rootVC;

    // 3. 悬浮胶囊按钮
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(screenBounds.size.width - 130 - 16, 120, 130, 48);
    btn.layer.cornerRadius = 24.0;
    btn.layer.masksToBounds = YES;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
    btn.layer.borderWidth = 1.0;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [btn setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.38 alpha:0.95];

    [btn addTarget:rootVC action:@selector(toggleAudioAction) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:rootVC action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];

    [rootVC.view addSubview:btn];
    g_floatingButton = btn;

    g_floatingWindow.hidden = YES;
    g_floatingWindow.alpha = 1.0f; // 保持 alpha 始终为 1.0，完全依靠 hidden 控制显隐
}

// 显隐悬浮窗口
static void ToggleFloatingWindowInSpringBoard(void) {
    NSTimeInterval now = CACurrentMediaTime();
    if (now - g_lastLongPressTriggerTime < 0.6) {
        return;
    }
    g_lastLongPressTriggerTime = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        EnsureFloatingWindowCreated();

        // 触觉反馈
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback prepare];
        [feedback impactOccurred];

        if (g_floatingWindow.hidden) {
            [g_floatingWindow setHidden:NO];
            g_floatingWindow.alpha = 1.0f;
            g_floatingButton.transform = CGAffineTransformMakeScale(0.7, 0.7);
            [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.8 options:0 animations:^{
                g_floatingButton.transform = CGAffineTransformIdentity;
            } completion:nil];
            NSLog(@"[CallAudioInjector] ★★★ 悬浮窗已成功展现！frame: %@ ★★★", NSStringFromCGRect(g_floatingButton.frame));
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                g_floatingButton.transform = CGAffineTransformMakeScale(0.75, 0.75);
            } completion:^(BOOL finished) {
                [g_floatingWindow setHidden:YES];
                g_floatingButton.transform = CGAffineTransformIdentity;
            }];
            NSLog(@"[CallAudioInjector] 悬浮窗已隐藏");
        }
    });
}

// ============================================================================
// PART 3: 硬件电源键底层长按捕获 (4 重保障机制)
// ============================================================================

static dispatch_source_t g_longPressTimer = nil;
static BOOL g_isLongPressTriggered = NO;

static void OnLockButtonDown(void) {
    g_isLongPressTriggered = NO;

    if (g_longPressTimer) {
        dispatch_source_cancel(g_longPressTimer);
        g_longPressTimer = nil;
    }

    g_longPressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_longPressTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(g_longPressTimer, ^{
        g_isLongPressTriggered = YES;
        NSLog(@"[CallAudioInjector] [方案1] 电源键长按达到 0.65 秒 -> 触发显隐悬浮窗！");
        ToggleFloatingWindowInSpringBoard();
        if (g_longPressTimer) {
            dispatch_source_cancel(g_longPressTimer);
            g_longPressTimer = nil;
        }
    });
    dispatch_resume(g_longPressTimer);
}

static BOOL OnLockButtonUp(void) {
    if (g_longPressTimer) {
        dispatch_source_cancel(g_longPressTimer);
        g_longPressTimer = nil;
    }

    if (g_isLongPressTriggered) {
        NSLog(@"[CallAudioInjector] 电源键抬起：长按已触发，拦截锁屏动作");
        g_isLongPressTriggered = NO;
        return YES; // 消费按键，阻止锁屏
    }
    return NO;
}

%group SpringBoardHooks

// 方案 1: Hook SpringBoard 底层电源键按压物理事件
%hook SpringBoard

- (void)_lockButtonDown:(id)arg1 fromSource:(int)arg2 {
    OnLockButtonDown();
    %orig;
}

- (void)_lockButtonUp:(id)arg1 fromSource:(int)arg2 {
    if (OnLockButtonUp()) {
        return;
    }
    %orig;
}

- (void)_lockButtonDown:(id)arg1 {
    OnLockButtonDown();
    %orig;
}

- (void)_lockButtonUp:(id)arg1 {
    if (OnLockButtonUp()) {
        return;
    }
    %orig;
}

%end

// 方案 2: Hook SBSiriHardwareButtonInteraction (侧边键长按调起 Siri 交互点)
%hook SBSiriHardwareButtonInteraction
- (void)observeLongPressDidBegin {
    NSLog(@"[CallAudioInjector] [方案2] SBSiriHardwareButtonInteraction observeLongPressDidBegin 触发！");
    ToggleFloatingWindowInSpringBoard();
}

- (BOOL)consumeLongPressUp {
    return YES;
}
%end

// 方案 3: Hook SBHBLongPressGestureRecognizer (长按手势识别器)
%hook SBHBLongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    if (state == UIGestureRecognizerStateBegan) {
        NSLog(@"[CallAudioInjector] [方案3] SBHBLongPressGestureRecognizer 状态变为 Began！");
        ToggleFloatingWindowInSpringBoard();
    }
    %orig;
}
%end

%end // SpringBoardHooks

// ============================================================================
// PART 4: 构造入口与生命周期分发
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
    int token = 0;
    notify_register_check(NOTIFY_STATE, &token);
    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    UpdateFloatingButtonUI(state == 1);
}

static void HandleToggleUINotification(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    NSLog(@"[CallAudioInjector] [方案4] 收到 Darwin NOTIFY_TOGGLE_UI 指令，切换悬浮窗！");
    ToggleFloatingWindowInSpringBoard();
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        NSLog(@"[CallAudioInjector] ctor 初始化, 进程: %@, Bundle: %@", processName, bundleID);

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

        // 2. SpringBoard：iOS 17 全局悬浮窗与硬件长按捕获
        if ([processName isEqualToString:@"SpringBoard"] || [bundleID isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[CallAudioInjector] 注入 SpringBoard 成功，激活 Hooks");
            %init(SpringBoardHooks);

            CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(darwin, NULL, HandleStateChangedNotification, CFSTR(NOTIFY_STATE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwin, NULL, HandleToggleUINotification, CFSTR(NOTIFY_TOGGLE_UI), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

            // 开机/注销 2 秒后预初始化悬浮窗对象
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                EnsureFloatingWindowCreated();
            });
        }
    }
}
