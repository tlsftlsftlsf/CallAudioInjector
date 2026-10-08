#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <substrate.h>

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define NOTIFY_PLAY       "com.tlsf.callaudioinjector.play"
#define NOTIFY_STOP       "com.tlsf.callaudioinjector.stop"
#define NOTIFY_TOGGLE     "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE      "com.tlsf.callaudioinjector.state_changed"
#define NOTIFY_TOGGLE_UI  "com.tlsf.callaudioinjector.toggle_ui"

// ============================================================================
// 全局点击穿透窗口（精准命中按钮，背景 100% 穿透）
// ============================================================================

static UIButton *g_floatingButton = nil;
static BOOL g_isInjecting = NO;
static NSTimeInterval g_lastTapActionTime = 0;
static NSTimeInterval g_lastToggleTime = 0;
static BOOL g_isDraggingButton = NO;

@interface CAIPassThroughWindow : UIWindow
@end

@implementation CAIPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (g_floatingButton && !g_floatingButton.hidden && g_floatingButton.alpha > 0.01) {
        CGPoint pInBtn = [self convertPoint:point toView:g_floatingButton];
        // 扩展 12pt 触摸热区，手指即使轻微偏离也能灵敏响应
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

// 点击按钮响应动作（即时触觉 + 即时视觉 + 跨进程通知）
static void OnFloatingButtonClicked(void) {
    g_isInjecting = !g_isInjecting;
    NSLog(@"[CallAudioInjectorUI] ★★★ 悬浮按钮点击生效！当前注入状态: %d ★★★", g_isInjecting);

    // 1. 强力震动反馈
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurred];

    // 2. 立即更新界面颜色和文字（零延迟，无需等待 mediaserverd 跨进程确认）
    UpdateFloatingButtonUI(g_isInjecting);

    // 3. 弹性缩放按压动画
    g_floatingButton.transform = CGAffineTransformMakeScale(0.88, 0.88);
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{
        g_floatingButton.transform = CGAffineTransformIdentity;
    } completion:nil];

    // 4. 广播指令给 mediaserverd
    if (g_isInjecting) {
        notify_post(NOTIFY_PLAY);
    } else {
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

        NSLog(@"[CallAudioInjectorUI] ★★★ 全局悬浮窗构建成功，已直接显示在屏幕顶层！★★★");
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
            NSLog(@"[CallAudioInjectorUI] 悬浮窗已展现");
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                g_floatingButton.transform = CGAffineTransformMakeScale(0.75, 0.75);
            } completion:^(BOOL finished) {
                g_floatingWindow.hidden = YES;
                g_floatingButton.transform = CGAffineTransformIdentity;
            }];
            NSLog(@"[CallAudioInjectorUI] 悬浮窗已收起隐藏");
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
            NSLog(@"[CallAudioInjectorUI] 长按音量下键 0.6s -> 切换悬浮窗显隐");
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
        NSLog(@"[CallAudioInjectorUI] 成功加载入 SpringBoard！");

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
