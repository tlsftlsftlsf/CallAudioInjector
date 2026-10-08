#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <dlfcn.h>
#import <math.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <substrate.h>
#import "EmbeddedAudio.h"

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define YUNFEI_PATH @"/var/mobile/Library/Application Support/AudioLoop/运费.mp3"
#define TEMP_YUNFEI_PATH @"/tmp/运费.mp3"
#define FLAG_FILE_PATH "/tmp/cai_active.flag"

#define NOTIFY_PLAY   "com.tlsf.callaudioinjector.play"
#define NOTIFY_STOP   "com.tlsf.callaudioinjector.stop"
#define NOTIFY_TOGGLE "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE  "com.tlsf.callaudioinjector.state_changed"

static BOOL g_isInjecting = NO;
static BOOL g_loopPlayback = YES;
static BOOL g_muteMic = NO;
static float g_gain = 1.0f;

// 高精度时间戳基准（解决多总线/多 AudioUnit 并发渲染时的跳帧与快进问题）
static mach_timebase_info_data_t g_timebaseInfo;
static double g_machTimeToSec = 0.0;
static uint64_t g_injectionStartMachTime = 0;

static void InitMachTime(void) {
    if (g_machTimeToSec == 0.0) {
        mach_timebase_info(&g_timebaseInfo);
        g_machTimeToSec = ((double)g_timebaseInfo.numer / (double)g_timebaseInfo.denom) * 1e-9;
    }
}

// 48kHz 解码后的 PCM 缓冲区
static Float32 *g_pcmBufferF32 = NULL;
static SInt16 *g_pcmBufferS16 = NULL;
static UInt32 g_pcmTotalFrames = 0;

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

static OSStatus (*orig_AudioUnitProcessMultiple)(AudioUnit inUnit,
                                                AudioUnitRenderActionFlags *ioActionFlags,
                                                const AudioTimeStamp *inTimeStamp,
                                                UInt32 inNumberFrames,
                                                UInt32 inNumberInputBufferLists,
                                                const AudioBufferList **ibls,
                                                UInt32 inNumberOutputBufferLists,
                                                AudioBufferList **obls);

static void CAIServerLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[CallAudioInjectorServer] %@", msg);

    NSString *logLine = [NSString stringWithFormat:@"[%@] [%s:%d] %@\n", [NSDate date], getprogname(), getpid(), msg];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/cai_debug.log"];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/cai_debug.log" contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/cai_debug.log"];
    }
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
        chmod("/tmp/cai_debug.log", 0666);
    }
}

static void BroadcastInjectionState(BOOL active) {
    int token = 0;
    notify_register_check(NOTIFY_STATE, &token);
    notify_set_state(token, active ? 1 : 0);
    notify_post(NOTIFY_STATE);
    notify_cancel(token);
}

// 内存直接合成备用音频 (48kHz)
static void SynthesizeDefaultMemoryAudio(void) {
    if (g_pcmBufferS16 && g_pcmTotalFrames > 0) return;

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
        if (cycle < 0.75) {
            double baseFreq = (t < 2.0) ? 587.33 : 880.0;
            double s1 = sin(2.0 * M_PI * baseFreq * t) * 0.55;
            double s2 = sin(2.0 * M_PI * (baseFreq * 1.5) * t) * 0.25;
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
}

// 加载并解码「运费.mp3」至 48kHz
static void LoadYunfeiAudio(void) {
    if (g_pcmBufferF32 != NULL && g_pcmTotalFrames > 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sourcePath = nil;

    NSArray *paths = @[
        YUNFEI_PATH,
        @"/Library/Application Support/AudioLoop/运费.mp3",
        @"/var/jb/Library/Application Support/AudioLoop/运费.mp3",
        TEMP_YUNFEI_PATH
    ];

    for (NSString *p in paths) {
        if ([fm fileExistsAtPath:p]) {
            sourcePath = p;
            break;
        }
    }

    // 若均不存在，自动释放内置二进制到 /tmp
    if (!sourcePath) {
        NSData *embedData = [NSData dataWithBytes:g_yunfeiMp3Bytes length:g_yunfeiMp3Bytes_len];
        [embedData writeToFile:TEMP_YUNFEI_PATH atomically:YES];
        chmod([TEMP_YUNFEI_PATH UTF8String], 0666);
        sourcePath = TEMP_YUNFEI_PATH;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:sourcePath];
    ExtAudioFileRef audioFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
    if (status != noErr || !audioFile) {
        SynthesizeDefaultMemoryAudio();
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
        SynthesizeDefaultMemoryAudio();
        return;
    }

    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);
    if (status != noErr || totalFrames <= 0) {
        ExtAudioFileDispose(audioFile);
        SynthesizeDefaultMemoryAudio();
        return;
    }

    UInt32 allocFrames = (UInt32)totalFrames;
    Float32 *buf32 = (Float32 *)malloc(allocFrames * sizeof(Float32));
    SInt16 *buf16 = (SInt16 *)malloc(allocFrames * sizeof(SInt16));
    if (!buf32 || !buf16) {
        if (buf32) free(buf32);
        if (buf16) free(buf16);
        ExtAudioFileDispose(audioFile);
        SynthesizeDefaultMemoryAudio();
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
        SynthesizeDefaultMemoryAudio();
        return;
    }

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

    CAIServerLog(@"成功载入解码「运费.mp3」: %u 帧 (48kHz)", (unsigned int)framesToRead);
}

static void ReloadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREF_PATH];
    if (prefs) {
        g_loopPlayback = prefs[@"loopPlayback"] ? [prefs[@"loopPlayback"] boolValue] : YES;
        g_muteMic = prefs[@"muteMic"] ? [prefs[@"muteMic"] boolValue] : NO;
        g_gain = prefs[@"gain"] ? [prefs[@"gain"] floatValue] : 1.0f;
    }
}

// 检查 POSIX 标志文件（跨进程零延迟最高可靠度保证）
static inline BOOL IsInjectionFlagPresent(void) {
    return (access(FLAG_FILE_PATH, F_OK) == 0);
}

// 检查 Darwin 注册内核状态
static inline BOOL CheckDarwinNotifyState(void) {
    int token = 0;
    if (notify_register_check(NOTIFY_STATE, &token) == NOTIFY_STATUS_OK) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        notify_cancel(token);
        return (state == 1);
    }
    return NO;
}

// 动态检测与同步注入状态（免通知依赖、自动重连）
static inline BOOL CheckAndUpdateInjectionState(void) {
    BOOL shouldBeActive = IsInjectionFlagPresent() || CheckDarwinNotifyState();
    if (shouldBeActive != g_isInjecting) {
        g_isInjecting = shouldBeActive;
        if (g_isInjecting) {
            InitMachTime();
            g_injectionStartMachTime = mach_absolute_time();
            if (g_pcmTotalFrames == 0) {
                LoadYunfeiAudio();
            }
            CAIServerLog(@"[IPC同步] 激活「运费.mp3」注入 (总帧数: %u, PID: %d, 进程: %s)",
                         (unsigned int)g_pcmTotalFrames, getpid(), getprogname());
        } else {
            CAIServerLog(@"[IPC同步] 停止「运费.mp3」注入 (PID: %d, 进程: %s)", getpid(), getprogname());
        }
    }
    return g_isInjecting;
}

// 核心实时混音函数（支持动态采样率线性插值重采样 + 全总线精确注入 + 时间基准同步）
static NSTimeInterval g_lastRenderLogTime = 0;

static void MixAudioIntoBufferList(AudioUnit inUnit,
                                   UInt32 inOutputBusNumber,
                                   AudioBufferList *ioData,
                                   UInt32 inNumberFrames,
                                   float gain,
                                   BOOL muteMic) {
    if (!g_isInjecting || ioData == NULL || inNumberFrames == 0 || g_pcmTotalFrames == 0) {
        return;
    }

    // 1. 获取目标 AudioUnit 该总线的真实采样率
    Float64 targetSampleRate = 48000.0;
    AudioStreamBasicDescription asbd;
    UInt32 asbdSize = sizeof(asbd);
    if (inUnit != NULL) {
        if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inOutputBusNumber, &asbd, &asbdSize) == noErr && asbd.mSampleRate > 1000.0) {
            targetSampleRate = asbd.mSampleRate;
        } else if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inOutputBusNumber, &asbd, &asbdSize) == noErr && asbd.mSampleRate > 1000.0) {
            targetSampleRate = asbd.mSampleRate;
        }
    }

    // 2. 基于精确时间基准计算当前播放帧位置（绝对避免多 AudioUnit / 多总线并发引起的快进/跳帧）
    InitMachTime();
    uint64_t now = mach_absolute_time();
    double elapsedSec = 0.0;
    if (g_injectionStartMachTime > 0 && now >= g_injectionStartMachTime) {
        elapsedSec = (double)(now - g_injectionStartMachTime) * g_machTimeToSec;
    }
    double totalFileDuration = (double)g_pcmTotalFrames / 48000.0;

    if (!g_loopPlayback && elapsedSec >= totalFileDuration) {
        g_isInjecting = NO;
        unlink(FLAG_FILE_PATH);
        BroadcastInjectionState(NO);
        return;
    }

    // 周期采样日志（每 2 秒记录一次，确保可见性但绝不卡顿 I/O）
    NSTimeInterval nowUnix = [[NSDate date] timeIntervalSince1970];
    if (nowUnix - g_lastRenderLogTime > 2.0) {
        g_lastRenderLogTime = nowUnix;
        CAIServerLog(@"[实时注入中] 进程: %s (PID: %d), Bus: %u, 帧数: %u, 目标采样率: %.0fHz, 已播: %.2f秒",
                     getprogname(), getpid(), (unsigned int)inOutputBusNumber, (unsigned int)inNumberFrames, targetSampleRate, elapsedSec);
    }

    // 计算当前起始播放点（在 48kHz 源缓冲区中的帧位置）
    double currentSourceFrame = fmod(elapsedSec * 48000.0, (double)g_pcmTotalFrames);
    if (currentSourceFrame < 0) currentSourceFrame = 0;

    // 源采样率(48000)与目标采样率的重采样步长
    double step = 48000.0 / targetSampleRate;

    // 3. 遍历所有缓冲区进行混音
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (buf->mData == NULL || buf->mDataByteSize == 0) continue;

        UInt32 chCount = (buf->mNumberChannels > 0) ? buf->mNumberChannels : 1;
        UInt32 bytesPerFrame = buf->mDataByteSize / inNumberFrames;
        if (bytesPerFrame == 0) continue;
        UInt32 bytesPerSample = bytesPerFrame / chCount;

        // 仅在明确是麦克风上行采集总线 (Bus 1) 时才静音真实麦克风；下行或单总线决不静音！
        BOOL shouldMute = (inOutputBusNumber == 1) ? muteMic : NO;

        if (bytesPerSample == 4 && g_pcmBufferF32 != NULL) {
            Float32 *target = (Float32 *)buf->mData;
            for (UInt32 f = 0; f < inNumberFrames; f++) {
                double srcPos = currentSourceFrame + (double)f * step;
                while (srcPos >= (double)g_pcmTotalFrames) {
                    if (g_loopPlayback) {
                        srcPos -= (double)g_pcmTotalFrames;
                    } else {
                        break;
                    }
                }
                float injVal = 0.0f;
                if (srcPos < (double)g_pcmTotalFrames) {
                    UInt32 idx0 = (UInt32)srcPos;
                    UInt32 idx1 = (idx0 + 1) % g_pcmTotalFrames;
                    float frac = (float)(srcPos - (double)idx0);
                    injVal = (g_pcmBufferF32[idx0] * (1.0f - frac) + g_pcmBufferF32[idx1] * frac) * gain;
                }

                for (UInt32 c = 0; c < chCount; c++) {
                    UInt32 idx = f * chCount + c;
                    float base = shouldMute ? 0.0f : target[idx];
                    float sum = base + injVal;
                    if (sum > 1.0f) sum = 1.0f;
                    else if (sum < -1.0f) sum = -1.0f;
                    target[idx] = sum;
                }
            }
        } else if (bytesPerSample == 2 && g_pcmBufferS16 != NULL) {
            SInt16 *target = (SInt16 *)buf->mData;
            for (UInt32 f = 0; f < inNumberFrames; f++) {
                double srcPos = currentSourceFrame + (double)f * step;
                while (srcPos >= (double)g_pcmTotalFrames) {
                    if (g_loopPlayback) {
                        srcPos -= (double)g_pcmTotalFrames;
                    } else {
                        break;
                    }
                }
                float injValF = 0.0f;
                if (srcPos < (double)g_pcmTotalFrames) {
                    UInt32 idx0 = (UInt32)srcPos;
                    UInt32 idx1 = (idx0 + 1) % g_pcmTotalFrames;
                    float frac = (float)(srcPos - (double)idx0);
                    injValF = (g_pcmBufferF32[idx0] * (1.0f - frac) + g_pcmBufferF32[idx1] * frac) * gain;
                }
                int32_t injValS16 = (int32_t)(injValF * 32767.0f);

                for (UInt32 c = 0; c < chCount; c++) {
                    UInt32 idx = f * chCount + c;
                    int32_t base = shouldMute ? 0 : (int32_t)target[idx];
                    int32_t sum = base + injValS16;
                    if (sum > 32767) sum = 32767;
                    else if (sum < -32768) sum = -32768;
                    target[idx] = (SInt16)sum;
                }
            }
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

    if (status == noErr && ioData != NULL && inNumberFrames > 0) {
        if (CheckAndUpdateInjectionState()) {
            if (ioActionFlags != NULL) {
                *ioActionFlags &= ~kAudioUnitRenderAction_OutputIsSilence;
            }
            // 无论是 Bus 1 (典型麦克风采集) 还是 Bus 0 (单总线单元/处理输出节点)
            // 均执行精准混音注入
            MixAudioIntoBufferList(inUnit, inOutputBusNumber, ioData, inNumberFrames, g_gain, g_muteMic);
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

    if (status == noErr && ioData != NULL && inNumberFrames > 0) {
        if (CheckAndUpdateInjectionState()) {
            if (ioActionFlags != NULL) {
                *ioActionFlags &= ~kAudioUnitRenderAction_OutputIsSilence;
            }
            MixAudioIntoBufferList(inUnit, 0, ioData, inNumberFrames, g_gain, NO);
        }
    }

    return status;
}

static OSStatus my_AudioUnitProcessMultiple(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inNumberFrames,
                                            UInt32 inNumberInputBufferLists,
                                            const AudioBufferList **ibls,
                                            UInt32 inNumberOutputBufferLists,
                                            AudioBufferList **obls) {
    OSStatus status = orig_AudioUnitProcessMultiple(inUnit, ioActionFlags, inTimeStamp, inNumberFrames, inNumberInputBufferLists, ibls, inNumberOutputBufferLists, obls);

    if (status == noErr && obls != NULL && inNumberFrames > 0) {
        if (CheckAndUpdateInjectionState()) {
            if (ioActionFlags != NULL) {
                *ioActionFlags &= ~kAudioUnitRenderAction_OutputIsSilence;
            }
            for (UInt32 i = 0; i < inNumberOutputBufferLists; i++) {
                if (obls[i] != NULL) {
                    MixAudioIntoBufferList(inUnit, i, obls[i], inNumberFrames, g_gain, NO);
                }
            }
        }
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
        LoadYunfeiAudio();
        g_isInjecting = YES;
        InitMachTime();
        g_injectionStartMachTime = mach_absolute_time();
        CAIServerLog(@"收到 PLAY -> 激活「运费.mp3」注入 (总帧数: %u)", g_pcmTotalFrames);
        BroadcastInjectionState(YES);
    } else if ([notifyName isEqualToString:@NOTIFY_STOP]) {
        g_isInjecting = NO;
        CAIServerLog(@"收到 STOP -> 停止注入");
        BroadcastInjectionState(NO);
    } else if ([notifyName isEqualToString:@NOTIFY_TOGGLE]) {
        ReloadPreferences();
        g_isInjecting = !g_isInjecting;
        if (g_isInjecting) {
            LoadYunfeiAudio();
            InitMachTime();
            g_injectionStartMachTime = mach_absolute_time();
        }
        CAIServerLog(@"收到 TOGGLE -> 状态: %d", g_isInjecting);
        BroadcastInjectionState(g_isInjecting);
    }
}

%ctor {
    @autoreleasepool {
        CAIServerLog(@"成功加载注入模块 (PID: %d, 进程: %s)", getpid(), getprogname());

        InitMachTime();
        ReloadPreferences();
        LoadYunfeiAudio();

        // 1. Hook AudioUnitRender
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
            CAIServerLog(@"Hook AudioUnitRender 成功！");
        }

        // 2. Hook AudioUnitProcess
        void *processSym = dlsym(RTLD_DEFAULT, "AudioUnitProcess");
        if (processSym) {
            MSHookFunction(processSym, (void *)my_AudioUnitProcess, (void **)&orig_AudioUnitProcess);
            CAIServerLog(@"Hook AudioUnitProcess 成功！");
        }

        // 3. Hook AudioUnitProcessMultiple
        void *processMultiSym = dlsym(RTLD_DEFAULT, "AudioUnitProcessMultiple");
        if (processMultiSym) {
            MSHookFunction(processMultiSym, (void *)my_AudioUnitProcessMultiple, (void **)&orig_AudioUnitProcessMultiple);
            CAIServerLog(@"Hook AudioUnitProcessMultiple 成功！");
        }

        // 4. GCD 异步通道通知注册（适用于现代无 CFRunLoop 的守护进程如 audiomxd）
        int playToken = 0;
        notify_register_dispatch(NOTIFY_PLAY, &playToken, dispatch_get_main_queue(), ^(int token) {
            ReloadPreferences();
            LoadYunfeiAudio();
            g_isInjecting = YES;
            InitMachTime();
            g_injectionStartMachTime = mach_absolute_time();
            CAIServerLog(@"[GCD通知] 收到 PLAY -> 激活注入");
        });

        int stopToken = 0;
        notify_register_dispatch(NOTIFY_STOP, &stopToken, dispatch_get_main_queue(), ^(int token) {
            g_isInjecting = NO;
            CAIServerLog(@"[GCD通知] 收到 STOP -> 停止注入");
        });

        int toggleToken = 0;
        notify_register_dispatch(NOTIFY_TOGGLE, &toggleToken, dispatch_get_main_queue(), ^(int token) {
            ReloadPreferences();
            g_isInjecting = !g_isInjecting;
            if (g_isInjecting) {
                LoadYunfeiAudio();
                InitMachTime();
                g_injectionStartMachTime = mach_absolute_time();
            }
            CAIServerLog(@"[GCD通知] 收到 TOGGLE -> 状态: %d", g_isInjecting);
            BroadcastInjectionState(g_isInjecting);
        });

        // 5. 传统 Darwin CFRunLoop 通知注册（双重保障）
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_PLAY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_STOP), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_TOGGLE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 6. 初始检查是否存在活跃的标志文件
        CheckAndUpdateInjectionState();
    }
}
