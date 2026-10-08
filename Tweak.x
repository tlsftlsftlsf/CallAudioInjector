#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <notify.h>
#import <dlfcn.h>
#import <substrate.h>

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define DEFAULT_AUDIO_PATH @"/var/mobile/Media/inject_audio.wav"

#define NOTIFY_PLAY   "com.tlsf.callaudioinjector.play"
#define NOTIFY_STOP   "com.tlsf.callaudioinjector.stop"
#define NOTIFY_TOGGLE "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE  "com.tlsf.callaudioinjector.state_changed"

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

// 释放缓存的 PCM 内存
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

    UInt32 framesToRead = (UInt32)totalFrames;
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

    // 查询当前 Bus 1 的音频格式
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

    // 检查是否需要加载或重新对齐音频格式
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
            notify_post(NOTIFY_STATE);
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
            notify_post(NOTIFY_STATE);
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
            notify_post(NOTIFY_STATE);
        }
    }
}

// Hook 目标函数: AudioUnitRender
static OSStatus my_AudioUnitRender(AudioUnit inUnit,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inOutputBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);

    // inOutputBusNumber == 1: 麦克风输入录音总线 (AUVoiceIO / AUHAL)
    if (status == noErr && inOutputBusNumber == 1 && g_isInjecting && ioData != NULL) {
        InjectAudioIntoBufferList(inUnit, ioData, inNumberFrames);
    }

    return status;
}

// ============================================================================
// PART 2: InCallService 交互控制（悬浮按钮与通话状态联动）
// ============================================================================

static UIButton *g_floatingButton = nil;
static UIWindow *g_floatingWindow = nil;

static void UpdateFloatingButtonState(BOOL active) {
    if (!g_floatingButton) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (active) {
            [g_floatingButton setTitle:@"⏹ 停止注入" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.9f green:0.2f blue:0.2f alpha:0.85f];
        } else {
            [g_floatingButton setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.15f green:0.65f blue:0.35f alpha:0.85f];
        }
    });
}

static void OnFloatingButtonClicked(void) {
    notify_post(NOTIFY_TOGGLE);
}

static void SetupFloatingButtonUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_floatingWindow) return;

        CGRect frame = CGRectMake(20, 100, 110, 44);
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }

        if (scene) {
            g_floatingWindow = [[UIWindow alloc] initWithWindowScene:scene];
        } else {
            g_floatingWindow = [[UIWindow alloc] initWithFrame:frame];
        }

        g_floatingWindow.frame = frame;
        g_floatingWindow.windowLevel = UIWindowLevelAlert + 100;
        g_floatingWindow.backgroundColor = [UIColor clearColor];

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        g_floatingWindow.rootViewController = rootVC;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = rootVC.view.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        btn.layer.cornerRadius = 22.0;
        btn.layer.masksToBounds = YES;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [btn setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.15f green:0.65f blue:0.35f alpha:0.85f];
        [btn addTarget:rootVC action:@selector(toggleAudio) forControlEvents:UIControlEventTouchUpInside];

        // 拖动手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:rootVC action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];

        [rootVC.view addSubview:btn];
        g_floatingButton = btn;

        g_floatingWindow.hidden = NO;
    });
}

// 为 UIViewController 添加动态方法实现点击和拖拽
@interface UIViewController (CallAudioInjectorActions)
- (void)toggleAudio;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation UIViewController (CallAudioInjectorActions)
- (void)toggleAudio {
    OnFloatingButtonClicked();
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:g_floatingWindow];
    CGRect frame = g_floatingWindow.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    g_floatingWindow.frame = frame;
    [pan setTranslation:CGPointZero inView:g_floatingWindow];
}
@end

// ============================================================================
// PART 3: 构造入口与生命周期管理
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
        NSLog(@"[CallAudioInjector] 收到 PLAY 指令");
        notify_post(NOTIFY_STATE);
    } else if ([notifyName isEqualToString:@NOTIFY_STOP]) {
        g_isInjecting = NO;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] 收到 STOP 指令");
        notify_post(NOTIFY_STATE);
    } else if ([notifyName isEqualToString:@NOTIFY_TOGGLE]) {
        ReloadPreferences();
        g_isInjecting = !g_isInjecting;
        if (g_isInjecting) {
            g_pcmFrameOffset = 0;
        }
        NSLog(@"[CallAudioInjector] 收到 TOGGLE 指令, 当前状态: %d", g_isInjecting);
        notify_post(NOTIFY_STATE);
    }
}

static void HandleStateChangedNotification(CFNotificationCenterRef center,
                                           void *observer,
                                           CFStringRef name,
                                           const void *object,
                                           CFDictionaryRef userInfo) {
    // InCallService 收到 mediaserverd 广播的状态变更通知
    UpdateFloatingButtonState(g_isInjecting);
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        // 1. mediaserverd 进程：初始化音频引擎与底层 Hook
        if ([processName isEqualToString:@"mediaserverd"]) {
            NSLog(@"[CallAudioInjector] 成功载入 mediaserverd");
            ReloadPreferences();

            void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
            if (symbol) {
                MSHookFunction(symbol, (void *)my_AudioUnitRender, (void **)&orig_AudioUnitRender);
                NSLog(@"[CallAudioInjector] AudioUnitRender Hook 成功");
            } else {
                NSLog(@"[CallAudioInjector] 错误: 未能在 mediaserverd 中找到 AudioUnitRender 符号");
            }

            CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_PLAY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_STOP), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_TOGGLE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // 2. InCallService 进程：创建悬浮控制按钮并监听通话状态
        if ([bundleID isEqualToString:@"com.apple.InCallService"]) {
            NSLog(@"[CallAudioInjector] 成功载入 InCallService");

            // 监听状态改变更新 UI
            CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(darwin, NULL, HandleStateChangedNotification, CFSTR(NOTIFY_STATE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

            // 延时加载悬浮按钮
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREF_PATH];
                BOOL showButton = prefs[@"showFloatingButton"] ? [prefs[@"showFloatingButton"] boolValue] : YES;
                if (showButton) {
                    SetupFloatingButtonUI();
                }
            });

            // 监听通话接通 / 挂断通知
            [[NSNotificationCenter defaultCenter] addObserverForName:@"TUCallCenterCallStatusChangedNotification"
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREF_PATH];
                BOOL autoPlay = prefs[@"autoPlayOnCall"] ? [prefs[@"autoPlayOnCall"] boolValue] : NO;
                if (autoPlay) {
                    notify_post(NOTIFY_PLAY);
                    UpdateFloatingButtonState(YES);
                }
            }];
        }
    }
}
