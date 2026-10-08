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

static UInt8 *g_pcmBuffer = NULL;
static UInt32 g_pcmBufferBytes = 0;
static UInt32 g_pcmTotalFrames = 0;
static UInt32 g_pcmFrameOffset = 0;
static AudioStreamBasicDescription g_cachedASBD;
static BOOL g_hasCachedASBD = NO;

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

// 自动生成内置测试音频（如果用户尚未放入自定义音频文件）
static void EnsureDefaultAudioFileExists(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:DEFAULT_AUDIO_PATH]) {
        return;
    }

    NSString *parentDir = [DEFAULT_AUDIO_PATH stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parentDir]) {
        [fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 生成 3 秒清晰的 16kHz 16-bit 单声道测试提示音 (D5 -> A5 双音交替)
    UInt32 sampleRate = 16000;
    UInt16 channels = 1;
    UInt16 bitsPerSample = 16;
    UInt32 durationSec = 3;
    UInt32 totalSamples = sampleRate * durationSec;
    UInt32 dataBytes = totalSamples * (bitsPerSample / 8);

    NSMutableData *wavData = [NSMutableData dataWithCapacity:44 + dataBytes];

    // RIFF 标头
    [wavData appendBytes:"RIFF" length:4];
    UInt32 chunkSize = 36 + dataBytes;
    [wavData appendBytes:&chunkSize length:4];
    [wavData appendBytes:"WAVE" length:4];

    // fmt 块
    [wavData appendBytes:"fmt " length:4];
    UInt32 subchunk1Size = 16;
    [wavData appendBytes:&subchunk1Size length:4];
    UInt16 audioFormat = 1; // PCM
    [wavData appendBytes:&audioFormat length:2];
    [wavData appendBytes:&channels length:2];
    [wavData appendBytes:&sampleRate length:4];
    UInt32 byteRate = sampleRate * channels * (bitsPerSample / 8);
    [wavData appendBytes:&byteRate length:4];
    UInt16 blockAlign = channels * (bitsPerSample / 8);
    [wavData appendBytes:&blockAlign length:2];
    [wavData appendBytes:&bitsPerSample length:2];

    // data 块
    [wavData appendBytes:"data" length:4];
    [wavData appendBytes:&dataBytes length:4];

    for (UInt32 i = 0; i < totalSamples; i++) {
        double t = (double)i / (double)sampleRate;
        double tone = 0.0;
        double cycle = fmod(t, 1.0);
        if (cycle < 0.75) {
            double freq = (t < 1.5) ? 587.33 : 880.0; // 587Hz / 880Hz
            tone = sin(2.0 * M_PI * freq * t) * 0.65;
        }
        int16_t sample = (int16_t)(tone * 32767.0);
        [wavData appendBytes:&sample length:2];
    }

    if ([wavData writeToFile:DEFAULT_AUDIO_PATH atomically:YES]) {
        chmod([DEFAULT_AUDIO_PATH UTF8String], 0666);
        NSLog(@"[CallAudioInjector] 成功自动生成默认测试音频文件: %@", DEFAULT_AUDIO_PATH);
    }
}

static BOOL LoadAudioFileForFormat(const AudioStreamBasicDescription *targetASBD) {
    ReloadPreferences();
    FreePCMBuffer();
    EnsureDefaultAudioFileExists();

    if (![[NSFileManager defaultManager] fileExistsAtPath:g_audioFilePath]) {
        NSLog(@"[CallAudioInjector] 错误: 音频文件不存在: %@", g_audioFilePath);
        return NO;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:g_audioFilePath];
    ExtAudioFileRef audioFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
    if (status != noErr || !audioFile) {
        NSLog(@"[CallAudioInjector] 打开音频文件失败: %d (路径: %@)", (int)status, g_audioFilePath);
        return NO;
    }

    // 匹配底层采集的采样率与位深（Float32 或 SInt16），单声道以保证向多声道/单声道灵活混音
    BOOL isFloat = (targetASBD->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    AudioStreamBasicDescription clientASBD;
    memset(&clientASBD, 0, sizeof(clientASBD));
    clientASBD.mFormatID = kAudioFormatLinearPCM;
    clientASBD.mSampleRate = (targetASBD->mSampleRate > 0) ? targetASBD->mSampleRate : 16000.0;
    clientASBD.mChannelsPerFrame = 1;
    if (isFloat) {
        clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        clientASBD.mBitsPerChannel = 32;
    } else {
        clientASBD.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        clientASBD.mBitsPerChannel = 16;
    }
    clientASBD.mFramesPerPacket = 1;
    clientASBD.mBytesPerFrame = clientASBD.mBitsPerChannel / 8;
    clientASBD.mBytesPerPacket = clientASBD.mBytesPerFrame;

    status = ExtAudioFileSetProperty(audioFile,
                                     kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(AudioStreamBasicDescription),
                                     &clientASBD);
    if (status != noErr) {
        NSLog(@"[CallAudioInjector] 设置 ClientDataFormat 失败: %d", (int)status);
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);
    if (status != noErr || totalFrames <= 0) {
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    UInt32 totalBytes = (UInt32)(totalFrames * clientASBD.mBytesPerFrame);
    g_pcmBuffer = (UInt8 *)malloc(totalBytes);
    if (!g_pcmBuffer) {
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    AudioBufferList fillBufList;
    fillBufList.mNumberBuffers = 1;
    fillBufList.mBuffers[0].mNumberChannels = 1;
    fillBufList.mBuffers[0].mDataByteSize = totalBytes;
    fillBufList.mBuffers[0].mData = g_pcmBuffer;

    UInt32 framesToRead = (UInt32)(totalFrames);
    status = ExtAudioFileRead(audioFile, &framesToRead, &fillBufList);
    if (status != noErr) {
        NSLog(@"[CallAudioInjector] 读取解码音频失败: %d", (int)status);
        FreePCMBuffer();
        ExtAudioFileDispose(audioFile);
        return NO;
    }

    g_pcmBufferBytes = fillBufList.mBuffers[0].mDataByteSize;
    g_pcmTotalFrames = framesToRead;
    g_pcmFrameOffset = 0;
    g_cachedASBD = *targetASBD;
    g_hasCachedASBD = YES;

    NSLog(@"[CallAudioInjector] 音频解码就绪! 采样率: %.1f Hz, 类型: %@, 总帧数: %u",
          clientASBD.mSampleRate, isFloat ? @"Float32" : @"SInt16", (unsigned int)g_pcmTotalFrames);

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
                                           1, // Bus 1: Mic
                                           &currentASBD,
                                           &asbdSize);
    if (status != noErr) {
        // 尝试 Input scope
        status = AudioUnitGetProperty(inUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      1,
                                      &currentASBD,
                                      &asbdSize);
        if (status != noErr) return;
    }

    if (!g_hasCachedASBD || g_pcmBuffer == NULL ||
        g_cachedASBD.mSampleRate != currentASBD.mSampleRate ||
        ((g_cachedASBD.mFormatFlags & kAudioFormatFlagIsFloat) != (currentASBD.mFormatFlags & kAudioFormatFlagIsFloat))) {
        if (!LoadAudioFileForFormat(&currentASBD)) {
            g_isInjecting = NO;
            BroadcastInjectionState(NO);
            return;
        }
    }

    if (g_pcmTotalFrames == 0 || g_pcmBuffer == NULL) return;

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

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (buf->mData == NULL) continue;
        UInt32 chCount = buf->mNumberChannels;
        if (chCount == 0) chCount = 1;

        if (isFloat) {
            Float32 *mic = (Float32 *)buf->mData;
            Float32 *inj = (Float32 *)g_pcmBuffer + g_pcmFrameOffset;

            for (UInt32 f = 0; f < framesToMix; f++) {
                float injVal = inj[f] * g_gain;
                for (UInt32 c = 0; c < chCount; c++) {
                    UInt32 idx = f * chCount + c;
                    float base = g_muteMic ? 0.0f : mic[idx];
                    float sum = base + injVal;
                    if (sum > 1.0f) sum = 1.0f;
                    else if (sum < -1.0f) sum = -1.0f;
                    mic[idx] = sum;
                }
            }
        } else {
            SInt16 *mic = (SInt16 *)buf->mData;
            SInt16 *inj = (SInt16 *)g_pcmBuffer + g_pcmFrameOffset;

            for (UInt32 f = 0; f < framesToMix; f++) {
                int32_t injVal = (int32_t)(inj[f] * g_gain);
                for (UInt32 c = 0; c < chCount; c++) {
                    UInt32 idx = f * chCount + c;
                    int32_t base = g_muteMic ? 0 : (int32_t)mic[idx];
                    int32_t sum = base + injVal;
                    if (sum > 32767) sum = 32767;
                    else if (sum < -32768) sum = -32768;
                    mic[idx] = (SInt16)sum;
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
            InjectAudioIntoBufferList(inUnit, ioData, inNumberFrames);
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
        EnsureDefaultAudioFileExists();
        g_isInjecting = YES;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] mediaserverd 收到 PLAY -> 激活注入");
        BroadcastInjectionState(YES);
    } else if ([notifyName isEqualToString:@NOTIFY_STOP]) {
        g_isInjecting = NO;
        g_pcmFrameOffset = 0;
        NSLog(@"[CallAudioInjector] mediaserverd 收到 STOP -> 停止注入");
        BroadcastInjectionState(NO);
    } else if ([notifyName isEqualToString:@NOTIFY_TOGGLE]) {
        ReloadPreferences();
        EnsureDefaultAudioFileExists();
        g_isInjecting = !g_isInjecting;
        if (g_isInjecting) {
            g_pcmFrameOffset = 0;
        }
        NSLog(@"[CallAudioInjector] mediaserverd 收到 TOGGLE -> 当前状态: %d", g_isInjecting);
        BroadcastInjectionState(g_isInjecting);
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[CallAudioInjector] 注入 mediaserverd 成功！");
        ReloadPreferences();
        EnsureDefaultAudioFileExists();

        void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (!symbol) {
            dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW | RTLD_GLOBAL);
            symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        }
        if (!symbol) {
            symbol = (void *)AudioUnitRender;
        }

        if (symbol) {
            MSHookFunction(symbol, (void *)my_AudioUnitRender, (void **)&orig_AudioUnitRender);
            NSLog(@"[CallAudioInjector] Hook AudioUnitRender 成功！");
        } else {
            NSLog(@"[CallAudioInjector] 未找到 AudioUnitRender 符号");
        }

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_PLAY), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_STOP), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleDarwinNotifications, CFSTR(NOTIFY_TOGGLE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
