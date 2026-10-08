#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <notify.h>
#import <dlfcn.h>
#import <math.h>
#import <sys/stat.h>
#import <substrate.h>

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define DEFAULT_AUDIO_PATH @"/var/mobile/Media/inject_audio.wav"

#define NOTIFY_PLAY   "com.tlsf.callaudioinjector.play"
#define NOTIFY_STOP   "com.tlsf.callaudioinjector.stop"
#define NOTIFY_TOGGLE "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE  "com.tlsf.callaudioinjector.state_changed"

static BOOL g_isInjecting = NO;
static BOOL g_loopPlayback = YES;
static BOOL g_muteMic = NO;
static float g_gain = 1.0f;
static NSString *g_audioFilePath = DEFAULT_AUDIO_PATH;

// 双格式内存音频缓冲区（零文件依赖，零实时开销）
static SInt16 *g_pcmBufferS16 = NULL;
static Float32 *g_pcmBufferF32 = NULL;
static UInt32 g_pcmTotalFrames = 0;
static UInt32 g_pcmFrameOffset = 0;

static OSStatus (*orig_AudioUnitRender)(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inOutputBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData);

static OSStatus (*orig_AudioUnitProcess)(AudioUnit inUnit,
                                         AudioUnitRenderActionFlags *ioActionFlags,
                                         const AudioTimeStamp *inTimeStamp,
                                         UInt32 inNumberFrames,
                                         AudioBufferList *ioData);

static void BroadcastInjectionState(BOOL active) {
    int token = 0;
    notify_register_check(NOTIFY_STATE, &token);
    notify_set_state(token, active ? 1 : 0);
    notify_post(NOTIFY_STATE);
}

// 内存直接合成默认测试音频（48kHz，单声道，4秒悦耳和弦音，绝无沙盒或权限问题）
static void SynthesizeDefaultMemoryAudio(void) {
    UInt32 sampleRate = 48000;
    UInt32 durationSec = 4;
    UInt32 totalFrames = sampleRate * durationSec;

    SInt16 *buf16 = (SInt16 *)malloc(totalFrames * sizeof(SInt16));
    Float32 *buf32 = (Float32 *)malloc(totalFrames * sizeof(Float32));

    if (!buf16 || !buf32) {
        if (buf16) free(buf16);
        if (buf32) free(buf32);
        return;
    }

    for (UInt32 i = 0; i < totalFrames; i++) {
        double t = (double)i / (double)sampleRate;
        double cycle = fmod(t, 1.0);
        double sampleVal = 0.0;

        // 每秒节奏：0.75秒发声，0.25秒停顿
        if (cycle < 0.75) {
            // 前两秒 587.33Hz (D5)，后两秒 880Hz (A5)
            double baseFreq = (t < 2.0) ? 587.33 : 880.0;
            double s1 = sin(2.0 * M_PI * baseFreq * t) * 0.55;
            double s2 = sin(2.0 * M_PI * (baseFreq * 1.5) * t) * 0.25; // 五度泛音增添饱满度
            sampleVal = s1 + s2;
        }

        buf32[i] = (Float32)sampleVal;
        int32_t s16 = (int32_t)(sampleVal * 32767.0);
        if (s16 > 32767) s16 = 32767;
        else if (s16 < -32768) s16 = -32768;
        buf16[i] = (SInt16)s16;
    }

    if (g_pcmBufferS16) free(g_pcmBufferS16);
    if (g_pcmBufferF32) free(g_pcmBufferF32);

    g_pcmBufferS16 = buf16;
    g_pcmBufferF32 = buf32;
    g_pcmTotalFrames = totalFrames;
    g_pcmFrameOffset = 0;

    NSLog(@"[CallAudioInjector] [%s] 内存音频合成完毕: %u 帧 (48kHz)", getprogname(), (unsigned int)totalFrames);
}

// 尝试从文件解码用户自定义音频（支持 wav/mp3/m4a，失败时自动保持内存音频）
static void TryLoadCustomAudioFile(void) {
    NSArray *candidates = @[
        g_audioFilePath ?: DEFAULT_AUDIO_PATH,
        @"/var/mobile/Media/inject_audio.wav",
        @"/var/mobile/Media/inject_audio.mp3",
        @"/var/mobile/Media/inject_audio.m4a",
        @"/tmp/inject_audio.wav",
        @"/var/jb/var/mobile/Media/inject_audio.wav"
    ];

    NSString *validPath = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm fileExistsAtPath:path]) {
            validPath = path;
            break;
        }
    }

    if (!validPath) {
        return; // 保留预先合成的内存音频
    }

    NSURL *fileURL = [NSURL fileURLWithPath:validPath];
    ExtAudioFileRef audioFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
    if (status != noErr || !audioFile) {
        return;
    }

    AudioStreamBasicDescription clientASBD;
    memset(&clientASBD, 0, sizeof(clientASBD));
    clientASBD.mFormatID = kAudioFormatLinearPCM;
    clientASBD.mSampleRate = 48000.0;
    clientASBD.mChannelsPerFrame = 1;
    clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    clientASBD.mBitsPerChannel = 32;
    clientASBD.mFramesPerPacket = 1;
    clientASBD.mBytesPerFrame = 4;
    clientASBD.mBytesPerPacket = 4;

    status = ExtAudioFileSetProperty(audioFile,
                                     kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription),
                                     &clientASBD);
    if (status != noErr) {
        ExtAudioFileDispose(audioFile);
        return;
    }

    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);
    if (status != noErr || totalFrames <= 0) {
        ExtAudioFileDispose(audioFile);
        return;
    }

    UInt32 allocFrames = (UInt32)totalFrames;
    Float32 *buf32 = (Float32 *)malloc(allocFrames * sizeof(Float32));
    SInt16 *buf16 = (SInt16 *)malloc(allocFrames * sizeof(SInt16));
    if (!buf32 || !buf16) {
        if (buf32) free(buf32);
        if (buf16) free(buf16);
        ExtAudioFileDispose(audioFile);
        return;
    }

    AudioBufferList fillBufList;
    fillBufList.mNumberBuffers = 1;
    fillBufList.mBuffers[0].mNumberChannels = 1;
    fillBufList.mBuffers[0].mDataByteSize = allocFrames * sizeof(Float32);
    fillBufList.mBuffers[0].mData = buf32;

    UInt32 framesToRead = allocFrames;
    status = ExtAudioFileRead(audioFile, &framesToRead, &fillBufList);
    ExtAudioFileDispose(audioFile);

    if (status != noErr || framesToRead == 0) {
        free(buf32);
        free(buf16);
        return;
    }

    // 同步生成 SInt16 缓冲区
    for (UInt32 i = 0; i < framesToRead; i++) {
        float f = buf32[i];
        int32_t s = (int32_t)(f * 32767.0f);
        if (s > 32767) s = 32767;
        else if (s < -32768) s = -32768;
        buf16[i] = (SInt16)s;
    }

    if (g_pcmBufferS16) free(g_pcmBufferS16);
    if (g_pcmBufferF32) free(g_pcmBufferF32);

    g_pcmBufferS16 = buf16;
    g_pcmBufferF32 = buf32;
    g_pcmTotalFrames = framesToRead;
    g_pcmFrameOffset = 0;

    NSLog(@"[CallAudioInjector] [%s] 成功载入外部音频文件: %@ (%u 帧)", getprogname(), validPath, (unsigned int)framesToRead);
}

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

// 核心实时混音函数（零内存分配，零文件IO，耗时 < 2 微秒）
static void MixAudioIntoBufferList(AudioBufferList *ioData, UInt32 inNumberFrames, float gain, BOOL muteMic) {
    if (!g_isInjecting || ioData == NULL || inNumberFrames == 0 || g_pcmTotalFrames == 0) {
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

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (buf->mData == NULL || buf->mDataByteSize == 0) continue;

        UInt32 chCount = (buf->mNumberChannels > 0) ? buf->mNumberChannels : 1;
        UInt32 bytesPerFrame = buf->mDataByteSize / inNumberFrames;
        if (bytesPerFrame == 0) continue;
        UInt32 bytesPerSample = bytesPerFrame / chCount;

        if (bytesPerSample == 4 && g_pcmBufferF32 != NULL) {
            // Float32 混音
            Float32 *target = (Float32 *)buf->mData;
            Float32 *inj = g_pcmBufferF32 + g_pcmFrameOffset;

            for (UInt32 f = 0; f < framesToMix; f++) {
                float injVal = inj[f] * gain;
                for (UInt32 c = 0; c < chCount; c++) {
                    UInt32 idx = f * chCount + c;
                    float base = muteMic ? 0.0f : target[idx];
                    float sum = base + injVal;
                    if (sum > 1.0f) sum = 1.0f;
                    else if (sum < -1.0f) sum = -1.0f;
                    target[idx] = sum;
                }
            }
        } else if (bytesPerSample == 2 && g_pcmBufferS16 != NULL) {
            // SInt16 混音
            SInt16 *target = (SInt16 *)buf->mData;
            SInt16 *inj = g_pcmBufferS16 + g_pcmFrameOffset;

            for (UInt32 f = 0; f < framesToMix; f++) {
                int32_t injVal = (int32_t)(inj[f] * gain);
                for (UInt32 c = 0; c < chCount; c++) {
                    UInt32 idx = f * chCount + c;
                    int32_t base = muteMic ? 0 : (int32_t)target[idx];
                    int32_t sum = base + injVal;
                    if (sum > 32767) sum = 32767;
                    else if (sum < -32768) sum = -32768;
                    target[idx] = (SInt16)sum;
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

static OSStatus my_AudioUnitRender(AudioUnit inUnit,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inOutputBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);

    if (status == noErr && g_isInjecting && ioData != NULL && inNumberFrames > 0) {
        if (inOutputBusNumber == 1) {
            // Bus 1 (麦克风上行链路): 注入指定音频，对方清晰听到
            MixAudioIntoBufferList(ioData, inNumberFrames, g_gain, g_muteMic);
        } else if (inOutputBusNumber == 0) {
            // Bus 0 (听筒/扬声器下行链路): 同步注入，让本机通话者也能实时听到声音确认注入中
            MixAudioIntoBufferList(ioData, inNumberFrames, g_gain * 0.75f, NO);
        }
    }

    return status;
}

static OSStatus my_AudioUnitProcess(AudioUnit inUnit,
                                    AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp,
                                    UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitProcess(inUnit, ioActionFlags, inTimeStamp, inNumberFrames, ioData);

    if (status == noErr && g_isInjecting && ioData != NULL && inNumberFrames > 0) {
        MixAudioIntoBufferList(ioData, inNumberFrames, g_gain, NO);
    }

    return status;
}

static void HandleDarwinNotifications(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    NSString *notifyName = (__bridge NSString *)name;
    if ([notifyName isEqualToString:@NOTIFY_PLAY]) {
        ReloadPreferences();
        TryLoadCustomAudioFile();
        g_isInjecting = YES;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] [%s] 收到 PLAY -> 激活音频注入 (总帧数: %u)", getprogname(), g_pcmTotalFrames);
        BroadcastInjectionState(YES);
    } else if ([notifyName isEqualToString:@NOTIFY_STOP]) {
        g_isInjecting = NO;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] [%s] 收到 STOP -> 停止音频注入", getprogname());
        BroadcastInjectionState(NO);
    } else if ([notifyName isEqualToString:@NOTIFY_TOGGLE]) {
        ReloadPreferences();
        g_isInjecting = !g_isInjecting;
        if (g_isInjecting) {
            TryLoadCustomAudioFile();
            g_pcmFrameOffset = 0;
        }
        NSLog(@"[CallAudioInjector] [%s] 收到 TOGGLE -> 状态: %d", getprogname(), g_isInjecting);
        BroadcastInjectionState(g_isInjecting);
    }
}

%ctor {
    @autoreleasepool {
        const char *prog = getprogname();
        NSLog(@"[CallAudioInjector] ★★★ 正在注入进程: %s (PID: %d) ★★★", prog, getpid());

        ReloadPreferences();
        // 1. 立即初始化双格式内存音频缓冲区，确保无论磁盘/沙盒状态如何都有音频可播
        SynthesizeDefaultMemoryAudio();
        // 2. 尝试读取自定义音频
        TryLoadCustomAudioFile();

        // 3. Hook AudioUnitRender
        void *renderSym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (!renderSym) {
            dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW | RTLD_GLOBAL);
            renderSym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        }
        if (!renderSym) {
            renderSym = (void *)AudioUnitRender;
        }

        if (renderSym) {
            MSHookFunction(renderSym, (void *)my_AudioUnitRender, (void **)&orig_AudioUnitRender);
            NSLog(@"[CallAudioInjector] [%s] Hook AudioUnitRender 成功！", prog);
        }

        // 4. Hook AudioUnitProcess
        void *processSym = dlsym(RTLD_DEFAULT, "AudioUnitProcess");
        if (processSym) {
            MSHookFunction(processSym, (void *)my_AudioUnitProcess, (void **)&orig_AudioUnitProcess);
            NSLog(@"[CallAudioInjector] [%s] Hook AudioUnitProcess 成功！", prog);
        }

        // 5. 注册 Darwin 跨进程广播
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_PLAY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_STOP), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_TOGGLE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
