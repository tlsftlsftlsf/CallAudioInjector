#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <substrate.h>

#define PREF_PATH @"/var/mobile/Library/Preferences/com.tlsf.callaudioinjector.plist"
#define NOTIFY_TOGGLE     "com.tlsf.callaudioinjector.toggle"
#define NOTIFY_STATE      "com.tlsf.callaudioinjector.state_changed"
#define NOTIFY_TOGGLE_UI  "com.tlsf.callaudioinjector.toggle_ui"

// ============================================================================
// 全局点击穿透窗口（仅胶囊自身响应事件，背景 100% 穿透给底层应用）
// ============================================================================

@interface CAIPassThroughWindow : UIWindow
@end

@implementation CAIPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // 点空白处穿透给系统/前台 App
    }
    return hitView; // 点在胶囊按钮上正常响应点击与拖拽
}
@end

static CAIPassThroughWindow *g_floatingWindow = nil;
static UIButton *g_floatingButton = nil;
static NSTimeInterval g_lastToggleTime = 0;

static void UpdateFloatingButtonUI(BOOL active) {
    if (!g_floatingButton) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (active) {
            [g_floatingButton setTitle:@"⏹ 停止注入" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.92 green:0.22 blue:0.22 alpha:0.95];
        } else {
            [g_floatingButton setTitle:@"🎙️ 注入音频" forState:UIControlStateNormal];
            g_floatingButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.72 blue:0.38 alpha:0.95];
        }
    });
}

static void OnFloatingButtonClicked(void) {
    NSLog(@"[CallAudioInjectorUI] 悬浮按钮被点击，广播 TOGGLE 指令");
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

    // 松手时弹簧阻尼吸附至左侧或右侧边缘
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat targetX = (newCenter.x < screenSize.width / 2.0) ? (halfW + 16) : (screenSize.width - halfW - 16);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:0 animations:^{
            btn.center = CGPointMake(targetX, btn.center.y);
        } completion:nil];
    }
}
@end

// 创建并直接显示悬浮窗口（安装/注销后直接显示）
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

        // 1. 获取有效 UIWindowScene
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
        g_floatingWindow.windowLevel = UIWindowLevelAlert + 9999.0f; // 保证在所有系统界面顶层
        g_floatingWindow.backgroundColor = [UIColor clearColor];

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.frame = screenBounds;
        g_floatingWindow.rootViewController = rootVC;

        // 2. 悬浮胶囊按钮
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

        [btn addTarget:rootVC action:@selector(toggleAudioAction) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:rootVC action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];

        [rootVC.view addSubview:btn];
        g_floatingButton = btn;

        // 3. 【核心要求】安装/加载完成后直接显示！
        [g_floatingWindow makeKeyAndVisible];
        g_floatingWindow.hidden = NO;
        g_floatingWindow.alpha = 1.0f;

        NSLog(@"[CallAudioInjectorUI] ★★★ 全局悬浮窗构建成功，已直接显示在屏幕顶层！★★★");
    });
}

// 切换显隐（长按音量下键触发）
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

// ============================================================================
// 按键捕获：长按音量下键切换悬浮窗显隐
// ============================================================================

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
            NSLog(@"[CallAudioInjectorUI] ★★★ 监听到长按音量下键达到 0.6s -> 切换悬浮窗 ★★★");
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
        return YES; // 消费按键，抑制默认音量减少
    }
    return NO;
}

// Hook SpringBoard 生命周期
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    NSLog(@"[CallAudioInjectorUI] SpringBoard applicationDidFinishLaunching -> 直接显示悬浮窗");
    CreateAndShowFloatingWindow();
}
%end

// Hook SBVolumeHardwareButtonActions (按住音量下键)
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

// Hook SBVolumeControl (长按期间防音量连续减少至静音)
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
    UpdateFloatingButtonUI(state == 1);
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

        // 确保安装与注销后直接弹出显示
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CreateAndShowFloatingWindow();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CreateAndShowFloatingWindow();
        });
    }
}
