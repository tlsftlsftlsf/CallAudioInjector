#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>
#import <sys/stat.h>
#import <substrate.h>
#import "EmbeddedAudio.h"

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define YUNFEI_PATH @"/var/mobile/Library/Application Support/AudioLoop/运费.mp3"
#define TEMP_YUNFEI_PATH @"/tmp/运费.mp3"

#define NOTIFY_PLAY       "com.tlsf.callaudioinjector.play"
#define NOTIFY_STOP       "com.tlsf.callaudioinjector.stop"
#define NOTIFY_TOGGLE     "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE      "com.tlsf.callaudioinjector.state_changed"
#define NOTIFY_TOGGLE_UI  "com.tlsf.callaudioinjector.toggle_ui"

static BOOL g_isInjecting = NO;

static void CAILog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[CallAudioInjectorUI] %@", msg);

    NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
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

// ============================================================================
// 双引擎本机发声播放器（AVAudioPlayer + AudioServices 双重保障，100% 破除静音模式）
// ============================================================================

@interface CAILocalAudioPlayer : NSObject <AVAudioPlayerDelegate>
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, assign) SystemSoundID soundID;
+ (instancetype)sharedInstance;
- (void)startPlaying;
- (void)stopPlaying;
- (BOOL)isPlaying;
@end

static void CAISystemSoundCompletionCallback(SystemSoundID ssID, void *clientData) {
    if (g_isInjecting) {
        AudioServicesPlaySystemSound(ssID);
    }
}

@implementation CAILocalAudioPlayer

+ (instancetype)sharedInstance {
    static CAILocalAudioPlayer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CAILocalAudioPlayer alloc] init];
    });
    return instance;
}

- (void)ensureAudioFileExists {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [YUNFEI_PATH stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSData *embedData = [NSData dataWithBytes:g_yunfeiMp3Bytes length:g_yunfeiMp3Bytes_len];

    if (![fm fileExistsAtPath:YUNFEI_PATH]) {
        [embedData writeToFile:YUNFEI_PATH atomically:YES];
        chmod([YUNFEI_PATH UTF8String], 0666);
        CAILog(@"已释放运费.mp3到: %@", YUNFEI_PATH);
    }

    if (![fm fileExistsAtPath:TEMP_YUNFEI_PATH]) {
        [embedData writeToFile:TEMP_YUNFEI_PATH atomically:YES];
        chmod([TEMP_YUNFEI_PATH UTF8String], 0666);
        CAILog(@"已释放运费.mp3到: %@", TEMP_YUNFEI_PATH);
    }
}

- (void)startPlaying {
    // 同步停止上一次播放，避免异步竞争
    [self stopPlaying];

    CAILog(@"开始启动本机播放...");
    [self ensureAudioFileExists];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *playPath = YUNFEI_PATH;
    if (![fm fileExistsAtPath:playPath]) {
        playPath = TEMP_YUNFEI_PATH;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:playPath];

    // 引擎 1：AudioServices 系统级直接声道播放（系统铃声/按键音底层通道，绝不受 App 沙盒与静音模式限制）
    OSStatus soundStatus = AudioServicesCreateSystemSoundID((__bridge CFURLRef)fileURL, &_soundID);
    if (soundStatus == noErr && self.soundID != 0) {
        AudioServicesAddSystemSoundCompletion(self.soundID, NULL, NULL, CAISystemSoundCompletionCallback, NULL);
        // 使用 PlaySystemSoundDirectly 或 PlayAlertSound
        AudioServicesPlayAlertSound(self.soundID);
        CAILog(@"[引擎1] AudioServicesPlayAlertSound 触发成功, soundID=%u", (unsigned int)self.soundID);
    } else {
        CAILog(@"[引擎1] AudioServicesCreateSystemSoundID 失败: %d", (int)soundStatus);
    }

    // 引擎 2：AVAudioPlayer（设置 Playback 模式强行绕过侧边静音开关）
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *sessErr = nil;
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                             AVAudioSessionCategoryOptionDefaultToSpeaker |
                             AVAudioSessionCategoryOptionAllowBluetooth
                       error:&sessErr];
        if (sessErr) {
            CAILog(@"AVAudioSession setCategory 报错: %@", sessErr);
        }
    } @catch (NSException *e) {
        CAILog(@"AVAudioSession 捕获异常: %@", e);
    }

    NSError *playerErr = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&playerErr];
    if (!self.player) {
        NSData *embedData = [NSData dataWithBytes:g_yunfeiMp3Bytes length:g_yunfeiMp3Bytes_len];
        self.player = [[AVAudioPlayer alloc] initWithData:embedData fileTypeHint:AVFileTypeMPEGLayer3 error:&playerErr];
    }

    if (self.player) {
        self.player.delegate = self;
        self.player.numberOfLoops = -1; // 循环播放
        self.player.volume = 1.0f;      // 保持满音量
        [self.player prepareToPlay];
        BOOL ok = [self.player play];
        CAILog(@"[引擎2] AVAudioPlayer play 结果: %d, 时长: %.2f秒, 路径: %@", ok, self.player.duration, playPath);
    } else {
        CAILog(@"[引擎2] AVAudioPlayer 创建失败: %@", playerErr);
    }
}

- (void)stopPlaying {
    if (self.player) {
        [self.player stop];
        self.player = nil;
        CAILog(@"[引擎2] AVAudioPlayer 已停止");
    }

    if (self.soundID != 0) {
        AudioServicesRemoveSystemSoundCompletion(self.soundID);
        AudioServicesDisposeSystemSoundID(self.soundID);
        self.soundID = 0;
        CAILog(@"[引擎1] AudioServicesSystemSound 已注销停止");
    }
}

- (BOOL)isPlaying {
    return (self.player && self.player.isPlaying) || (self.soundID != 0);
}

@end

// ============================================================================
// 全局点击穿透窗口（精准命中按钮，背景 100% 穿透）
// ============================================================================

static UIButton *g_floatingButton = nil;
static NSTimeInterval g_lastTapActionTime = 0;
static NSTimeInterval g_lastToggleTime = 0;
static BOOL g_isDraggingButton = NO;

@interface CAIPassThroughWindow : UIWindow
@end

@implementation CAIPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (g_floatingButton && !g_floatingButton.hidden && g_floatingButton.alpha > 0.01) {
        CGPoint pInBtn = [self convertPoint:point toView:g_floatingButton];
        CGRect touchArea = CGRectInset(g_floatingButton.bounds, -12, -12);
        if (CGRectContainsPoint(touchArea, pInBtn)) {
            return g_floatingButton;
        }
    }
    return nil;
}
@end

static CAIPassThroughWindow *g_floatingWindow = nil;

static void UpdateFloatingButtonUI(BOOL active) {
    if (!g_floatingButton) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (active) {
            [g_floatingButton setTitle:@"⏹ 停止注入" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.92 green:0.20 blue:0.20 alpha:0.95];
        } else {
            [g_floatingButton setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.72 blue:0.38 alpha:0.95];
        }
    });
}

// 点击按钮响应动作（即时触觉 + 即时视觉 + 双引擎本机发声 + 跨进程通知）
static void OnFloatingButtonClicked(void) {
    g_isInjecting = !g_isInjecting;
    CAILog(@"★★★ 悬浮按钮点击！切换后状态: %d ★★★", g_isInjecting);

    // 1. 强力震动反馈
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurred];

    // 2. 立即更新界面颜色和文字
    UpdateFloatingButtonUI(g_isInjecting);

    // 3. 弹性缩放按压动画
    g_floatingButton.transform = CGAffineTransformMakeScale(0.88, 0.88);
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{
        g_floatingButton.transform = CGAffineTransformIdentity;
    } completion:nil];

    // 4. 双引擎启动本机发声并广播给服务端进程
    if (g_isInjecting) {
        [[CAILocalAudioPlayer sharedInstance] startPlaying];
        notify_post(NOTIFY_PLAY);
    } else {
        [[CAILocalAudioPlayer sharedInstance] stopPlaying];
        notify_post(NOTIFY_STOP);
    }
}

@interface UIViewController (CAIFloatingButtonActions)
- (void)handleButtonTap;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation UIViewController (CAIFloatingButtonActions)
- (void)handleButtonTap {
    if (g_isDraggingButton) return;

    NSTimeInterval now = CACurrentMediaTime();
    if (now - g_lastTapActionTime < 0.25) return;
    g_lastTapActionTime = now;

    OnFloatingButtonClicked();
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        g_isDraggingButton = YES;
    }

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
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                g_isDraggingButton = NO;
            });
        }];
    }
}
@end

static void CreateAndShowFloatingWindow(void) {
    if (g_floatingWindow) {
        g_floatingWindow.hidden = NO;
        g_floatingWindow.alpha = 1.0f;
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_floatingWindow) {
            g_floatingWindow.hidden = NO;
            g_floatingWindow.alpha = 1.0f;
            return;
        }

        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)scene;
                break;
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
        if (activeScene) {
            g_floatingWindow = [[CAIPassThroughWindow alloc] initWithWindowScene:activeScene];
        } else {
            g_floatingWindow = [[CAIPassThroughWindow alloc] initWithFrame:screenBounds];
        }

        g_floatingWindow.frame = screenBounds;
        g_floatingWindow.windowLevel = UIWindowLevelAlert + 9999.0f;
        g_floatingWindow.backgroundColor = [UIColor clearColor];

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.frame = screenBounds;
        g_floatingWindow.rootViewController = rootVC;

        // 胶囊按钮
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(screenBounds.size.width - 136 - 16, 140, 136, 48);
        btn.layer.cornerRadius = 24.0;
        btn.layer.masksToBounds = YES;
        btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
        btn.layer.borderWidth = 1.5;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [btn setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.12 green:0.72 blue:0.38 alpha:0.95];

        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 4);
        btn.layer.shadowOpacity = 0.45;
        btn.layer.shadowRadius = 8.0;

        // 1. 传统 Target-Action 绑定点击
        [btn addTarget:rootVC action:@selector(handleButtonTap) forControlEvents:UIControlEventTouchUpInside];

        // 2. 手势识别绑定点击（双重保障）
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:rootVC action:@selector(handleButtonTap)];

        // 3. 拖动手势（cancelsTouchesInView = NO 确保点击事件不被吞食）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:rootVC action:@selector(handlePan:)];
        pan.cancelsTouchesInView = NO;

        [tap requireGestureRecognizerToFail:pan];

        [btn addGestureRecognizer:tap];
        [btn addGestureRecognizer:pan];

        [rootVC.view addSubview:btn];
        g_floatingButton = btn;

        // 直接挂载并显示
        [g_floatingWindow makeKeyAndVisible];
        g_floatingWindow.hidden = NO;
        g_floatingWindow.alpha = 1.0f;

        CAILog(@"★★★ 全局悬浮窗已成功构建并显示在屏幕顶层！★★★");
    });
}

static void ToggleFloatingWindow(void) {
    NSTimeInterval now = CACurrentMediaTime();
    if (now - g_lastToggleTime < 0.5) return;
    g_lastToggleTime = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_floatingWindow) {
            CreateAndShowFloatingWindow();
            return;
        }

        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback prepare];
        [feedback impactOccurred];

        if (g_floatingWindow.hidden) {
            g_floatingWindow.hidden = NO;
            g_floatingButton.transform = CGAffineTransformMakeScale(0.7, 0.7);
            [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.8 options:0 animations:^{
                g_floatingButton.transform = CGAffineTransformIdentity;
            } completion:nil];
            CAILog(@"悬浮窗已展现");
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                g_floatingButton.transform = CGAffineTransformMakeScale(0.75, 0.75);
            } completion:^(BOOL finished) {
                g_floatingWindow.hidden = YES;
                g_floatingButton.transform = CGAffineTransformIdentity;
            }];
            CAILog(@"悬浮窗已收起隐藏");
        }
    });
}

// 长按音量下键捕获
static dispatch_source_t g_volumeDownTimer = nil;
static BOOL g_isVolumeDownHeld = NO;
static BOOL g_volumeDownLongPressTriggered = NO;

static void OnVolumeDownDown(void) {
    g_isVolumeDownHeld = YES;
    g_volumeDownLongPressTriggered = NO;

    if (g_volumeDownTimer) {
        dispatch_source_cancel(g_volumeDownTimer);
        g_volumeDownTimer = nil;
    }

    g_volumeDownTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_volumeDownTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(g_volumeDownTimer, ^{
        if (g_isVolumeDownHeld) {
            g_volumeDownLongPressTriggered = YES;
            CAILog(@"长按音量下键 0.6s -> 切换悬浮窗显隐");
            ToggleFloatingWindow();
        }
        if (g_volumeDownTimer) {
            dispatch_source_cancel(g_volumeDownTimer);
            g_volumeDownTimer = nil;
        }
    });
    dispatch_resume(g_volumeDownTimer);
}

static BOOL OnVolumeDownUp(void) {
    g_isVolumeDownHeld = NO;
    if (g_volumeDownTimer) {
        dispatch_source_cancel(g_volumeDownTimer);
        g_volumeDownTimer = nil;
    }

    if (g_volumeDownLongPressTriggered) {
        g_volumeDownLongPressTriggered = NO;
        return YES;
    }
    return NO;
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CreateAndShowFloatingWindow();
}
%end

%hook SBVolumeHardwareButtonActions
- (void)volumeDecreasePressDown {
    OnVolumeDownDown();
    %orig;
}
- (void)volumeDecreasePressUp {
    if (OnVolumeDownUp()) {
        return;
    }
    %orig;
}
%end

%hook SBVolumeControl
- (void)decreaseVolume {
    if (g_volumeDownLongPressTriggered) {
        return;
    }
    %orig;
}
%end

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
    g_isInjecting = (state == 1);
    UpdateFloatingButtonUI(g_isInjecting);
    if (!g_isInjecting) {
        [[CAILocalAudioPlayer sharedInstance] stopPlaying];
    }
}

static void HandleToggleUINotification(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    ToggleFloatingWindow();
}

%ctor {
    @autoreleasepool {
        CAILog(@"成功加载入 SpringBoard (PID: %d)", getpid());

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, HandleStateChangedNotification, CFSTR(NOTIFY_STATE), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, HandleToggleUINotification, CFSTR(NOTIFY_TOGGLE_UI), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CreateAndShowFloatingWindow();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CreateAndShowFloatingWindow();
        });
    }
}
