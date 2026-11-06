#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static const NSInteger kASOwnViewTag = 0x0A5C1F;
static const NSTimeInterval kASTickInterval = 0.25;
static const NSTimeInterval kASSessionDuration = 6.0;
static const NSTimeInterval kASActivationWindow = 12.0;
static const NSTimeInterval kASOCRStartDelay = 1.0;
static const NSTimeInterval kASOCRInterval = 1.5;
static const NSInteger kASOCRMaxRuns = 3;
static const NSTimeInterval kASCustomPointDelay = 1.2;
static const NSTimeInterval kASCornerFallbackDelay = 3.0;
static const NSInteger kASScanNodeBudget = 4000;
static char kASGestureInstalledKey;
static NSString *const kASPointsDefaultsKey = @"SplashAway.customPoints";
static NSString *const kASThreeFingerDefaultsKey = @"SplashAway.threeFingerEnabled";
static NSString *const kASEnabledDefaultsKey = @"SplashAway.enabled";
static NSString *const kASOCRDefaultsKey = @"SplashAway.ocrEnabled";
static NSString *const kASCornerDefaultsKey = @"SplashAway.cornerEnabled";
static NSString *const kASLaunchToastDefaultsKey = @"SplashAway.launchToastEnabled";
static NSString *const kASSkipCountDefaultsKey = @"SplashAway.skipCount";
static NSString *const kASLastMethodDefaultsKey = @"SplashAway.lastSkipMethod";
static NSString *const kASLastDateDefaultsKey = @"SplashAway.lastSkipDate";
static NSString *const kASPopupDefaultsKey = @"SplashAway.popupEnabled";
static NSString *const kASWatchDefaultsKey = @"SplashAway.watchEnabled";
static NSString *const kASPopupCountDefaultsKey = @"SplashAway.popupCount";
static const NSTimeInterval kASPassiveScanDelay = 0.45;
static const NSTimeInterval kASPopupCooldown = 1.2;
static const NSTimeInterval kASPopupStartDelay = 0.5;
static const NSInteger kASPopupNodeBudget = 2500;
static const NSTimeInterval kASPointWatchInterval = 1.0;
static const NSTimeInterval kASPointCooldown = 4.0;
static NSString *const kASVersion = @"0.0.3";

static UIColor *ASAccentColor(void) {
    return [UIColor colorWithRed:0.25 green:0.90 blue:0.62 alpha:1.0];
}

#pragma mark - 运行范围

static BOOL ASShouldRunInProcess(void) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleId = mainBundle.bundleIdentifier;
    if (bundleId.length == 0) return NO;
    if ([bundleId hasPrefix:@"com.apple."]) return NO;
    if (![mainBundle.bundlePath.pathExtension isEqualToString:@"app"]) return NO;
    return YES;
}

#pragma mark - 文本归一化与判定

static NSString *ASNormalizeText(NSString *raw) {
    if (raw.length == 0 || raw.length > 20) return nil;
    static NSRegularExpression *countdownRegex;
    static NSCharacterSet *stripSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        countdownRegex = [NSRegularExpression regularExpressionWithPattern:@"\\d+\\s*(秒后|秒|sec|s)?" options:0 error:nil];
        NSMutableCharacterSet *set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set addCharactersInString:@">»<«·*|:：()（）[]【】{}~!！?？,，.。-—_+•/\\'\"“”‘’"];
        stripSet = [set copy];
    });
    NSString *text = raw.lowercaseString;
    text = [countdownRegex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    text = [[text componentsSeparatedByCharactersInSet:stripSet] componentsJoinedByString:@""];
    return text;
}

static BOOL ASIsSkipText(NSString *raw, BOOL strict) {
    NSString *text = ASNormalizeText(raw);
    if (text.length == 0 || text.length > 8) return NO;

    static NSArray<NSString *> *excludeWords;
    static NSSet<NSString *> *exactWords;
    static NSSet<NSString *> *looseWords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excludeWords = @[@"新手", @"引导", @"教程", @"剧情", @"关卡", @"动画", @"片头", @"片尾", @"本集", @"intro",
                         @"会员", @"會員", @"开通", @"開通", @"vip"];
        exactWords = [NSSet setWithArray:@[@"跳过", @"跳过广告", @"跳广告", @"略过", @"关闭广告", @"广告关闭",
                                           @"跳過", @"跳過廣告", @"跳廣告", @"略過", @"關閉廣告", @"廣告關閉",
                                           @"skip", @"skipad", @"skipads", @"closead"]];
        looseWords = [NSSet setWithArray:@[@"关闭", @"關閉", @"close", @"x", @"×", @"✕", @"✖", @"╳"]];
    });

    for (NSString *word in excludeWords) {
        if ([text containsString:word]) return NO;
    }
    if ([exactWords containsObject:text]) return YES;
    if (!strict && [looseWords containsObject:text]) return YES;
    if ([text hasPrefix:@"跳过"] && text.length <= 6) return YES;
    if ([text hasPrefix:@"跳過"] && text.length <= 6) return YES;
    if ([text hasPrefix:@"skip"] && text.length <= 8) return YES;
    return NO;
}

static NSArray<NSString *> *ASRetentionPhrases(void);

typedef NS_ENUM(NSInteger, ASDismissLevel) {
    ASDismissNone = 0,
    ASDismissWeak = 1,
    ASDismissStrong = 2,
};

static ASDismissLevel ASDismissLevelForText(NSString *raw) {
    NSString *text = ASNormalizeText(raw);
    if (text.length == 0 || text.length > 10) return ASDismissNone;

    static NSSet<NSString *> *strongWords;
    static NSArray<NSString *> *strongPrefixes;
    static NSSet<NSString *> *weakWords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        strongWords = [NSSet setWithArray:@[@"以后再说", @"下次再说", @"稍后再说", @"暂不", @"暂不需要", @"暂不更新", @"暂不升级",
                                            @"暂不开启", @"暂不考虑", @"不了谢谢", @"不用了", @"不需要", @"我知道了", @"知道了",
                                            @"我再想想", @"残忍拒绝", @"狠心拒绝", @"忽略", @"忽略此版本", @"跳过此版本",
                                            @"以後再說", @"下次再說", @"稍後再說", @"暫不", @"暫不需要", @"暫不更新", @"暫不升級",
                                            @"不了謝謝", @"忽略此版本", @"跳過此版本",
                                            @"notnow", @"later", @"maybelater", @"remindmelater", @"nothanks", @"gotit",
                                            @"skipthisversion", @"dismiss"]];
        strongPrefixes = @[@"暂不", @"暫不", @"以后再", @"以後再", @"下次再", @"稍后再", @"稍後再"];
        weakWords = [NSSet setWithArray:@[@"取消", @"关闭", @"關閉", @"拒绝", @"拒絕", @"不允许", @"不允許", @"否",
                                          @"close", @"cancel", @"no", @"x", @"×", @"✕", @"✖", @"╳"]];
    });

    if ([strongWords containsObject:text]) return ASDismissStrong;
    if ([ASRetentionPhrases() containsObject:text]) return ASDismissStrong;
    if (text.length <= 6) {
        for (NSString *prefix in strongPrefixes) {
            if ([text hasPrefix:prefix]) return ASDismissStrong;
        }
    }
    if ([weakWords containsObject:text]) return ASDismissWeak;
    return ASDismissNone;
}

static BOOL ASTextContainsAny(NSString *text, NSArray<NSString *> *words) {
    if (text.length == 0) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *word in words) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *ASRetentionPhrases(void) {
    static NSArray<NSString *> *phrases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        phrases = @[@"坚持退出", @"堅持退出", @"残忍离开", @"殘忍離開", @"狠心离开", @"狠心離開", @"放弃奖励", @"放棄獎勵",
                    @"不要奖励", @"不要獎勵", @"直接退出", @"仍要退出", @"确认退出", @"確認退出", @"残忍退出", @"殘忍退出",
                    @"放弃福利", @"放棄福利", @"我不要了", @"不想要了"];
    });
    return phrases;
}

static BOOL ASPopupTextIsDangerous(NSString *text) {
    if (text.length > 0) {
        NSString *stripped = text;
        for (NSString *phrase in ASRetentionPhrases()) {
            stripped = [stripped stringByReplacingOccurrencesOfString:phrase withString:@""];
        }
        text = stripped;
    }
    static NSArray<NSString *> *words;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        words = @[@"支付", @"付款", @"购买", @"購買", @"充值", @"续费", @"續費", @"删除", @"刪除", @"注销", @"註銷",
                  @"退出登录", @"退出登錄", @"解绑", @"解綁", @"清空", @"转账", @"轉賬", @"提现", @"提現",
                  @"保存", @"草稿", @"放弃", @"放棄", @"离开", @"離開",
                  @"pay", @"purchase", @"delete", @"logout", @"log out", @"sign out", @"save", @"discard"];
    });
    return ASTextContainsAny(text, words);
}

static BOOL ASPopupTextIsNuisance(NSString *text) {
    static NSArray<NSString *> *words;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        words = @[@"新版本", @"版本更新", @"发现新", @"發現新", @"升级", @"升級", @"更新", @"通知", @"推送", @"消息提醒",
                  @"评分", @"評分", @"好评", @"好評", @"评价", @"評價", @"青少年", @"未成年", @"优惠券", @"優惠券",
                  @"红包", @"紅包", @"福利", @"领取", @"領取", @"限时", @"限時", @"签到", @"簽到", @"新人", @"礼包", @"禮包",
                  @"小组件", @"小組件", @"桌面", @"再看", @"看视频", @"看視頻", @"奖励", @"獎勵", @"无损", @"無損", @"update", @"new version", @"notification", @"rate", @"review", @"coupon"];
    });
    return ASTextContainsAny(text, words);
}

static BOOL ASIsDimBackdropView(UIView *view) {
    UIColor *color = view.backgroundColor;
    if (!color) return NO;
    CGFloat white = 1, alpha = 0;
    if (![color getWhite:&white alpha:&alpha]) {
        CGFloat red = 1, green = 1, blue = 1;
        if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return NO;
        white = MAX(red, MAX(green, blue));
    }
    CGFloat effective = alpha * view.alpha;
    return white < 0.25 && effective >= 0.15 && effective <= 0.88;
}

static BOOL ASViewIsTappable(UIView *view) {
    if ([view isKindOfClass:[UIControl class]]) return ((UIControl *)view).isEnabled;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]] && gesture.isEnabled) return YES;
    }
    return NO;
}

static BOOL ASLooksLikeCloseIcon(UIView *view, CGRect rect) {
    CGFloat width = rect.size.width, height = rect.size.height;
    if (width < 14 || height < 14 || width > 64 || height > 64) return NO;
    if (fabs(width - height) > MAX(width, height) * 0.35) return NO;
    if (!ASViewIsTappable(view)) return NO;
    NSString *hint = [[NSString stringWithFormat:@"%@ %@", NSStringFromClass([view class]), view.accessibilityIdentifier ?: @""] lowercaseString];
    if ([hint containsString:@"close"] || [hint containsString:@"dismiss"]) return YES;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        return button.currentImage != nil || button.currentBackgroundImage != nil;
    }
    return NO;
}

static NSString *ASTextOfView(UIView *view) {
    NSString *text = nil;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        text = button.currentTitle ?: button.currentAttributedTitle.string;
    } else if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        text = label.text ?: label.attributedText.string;
    }
    if (text.length == 0) text = view.accessibilityLabel;
    return text;
}

static void ASCollectShortTexts(UIView *view, NSInteger depth, NSInteger *budget, NSMutableString *out) {
    if (!view || view.isHidden || view.alpha < 0.05 || *budget <= 0 || depth > 3 || out.length >= 40) return;
    (*budget)--;
    NSString *text = ASNormalizeText(ASTextOfView(view));
    if (text.length > 0 && ![out containsString:text]) [out appendString:text];
    if ([view isKindOfClass:[UIButton class]] || [view isKindOfClass:[UILabel class]]) return;
    for (UIView *subview in view.subviews) {
        ASCollectShortTexts(subview, depth + 1, budget, out);
    }
}

static UIView *ASSignatureAnchorForHit(UIView *hit, UIWindow *window) {
    CGSize windowSize = window.bounds.size;
    UIView *current = hit;
    UIView *anchor = hit;
    for (NSInteger level = 0; level < 3 && current && current != window; level++) {
        CGRect rect = [current convertRect:current.bounds toView:window];
        if (rect.size.width > windowSize.width * 0.7 || rect.size.height > windowSize.height * 0.2) break;
        anchor = current;
        if ([current isKindOfClass:[UIControl class]] || ASTextOfView(current).length > 0) break;
        current = current.superview;
    }
    return anchor;
}

static NSString *ASSignatureTextOfView(UIView *anchor, UIWindow *window) {
    if (!anchor) return @"";
    CGRect rect = [anchor convertRect:anchor.bounds toView:window];
    if (rect.size.width > window.bounds.size.width * 0.7 || rect.size.height > window.bounds.size.height * 0.2) return @"";
    NSMutableString *out = [NSMutableString string];
    NSInteger budget = 40;
    ASCollectShortTexts(anchor, 0, &budget, out);
    return out.length > 40 ? [out substringToIndex:40] : [out copy];
}

static BOOL ASIsGenericViewClass(UIView *view) {
    if ([view isMemberOfClass:[UIView class]] || [view isKindOfClass:[UIWindow class]]) return YES;
    if ([view isKindOfClass:[UIScrollView class]] || ([view isKindOfClass:[UIImageView class]] && !ASViewIsTappable(view))) return YES;
    NSString *name = NSStringFromClass([view class]);
    return [name hasPrefix:@"WK"] || [name containsString:@"WebView"] || [name containsString:@"Transition"] ||
           [name containsString:@"DropShadow"] || [name containsString:@"LayoutContainer"];
}

static BOOL ASSignatureTextMatches(NSString *recorded, NSString *current) {
    if (recorded.length == 0 || current.length == 0) return NO;
    if ([recorded isEqualToString:current]) return YES;
    if (recorded.length < 2 || current.length < 2) return NO;
    return [current containsString:recorded] || [recorded containsString:current];
}

#pragma mark - 窗口

static BOOL ASIsSystemInputWindow(UIWindow *window) {
    NSString *name = NSStringFromClass([window class]);
    return [name containsString:@"Keyboard"] || [name containsString:@"TextEffects"];
}

@interface SplashAwayHUDWindow : UIWindow
@end

@interface SplashAwayHUDRootView : UIView
@end

@interface SplashAwayHUDController : UIViewController
@property (nonatomic, weak) UIWindow *hostWindow;
@end

static NSArray<UIWindow *> *ASVisibleWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        [all addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    if (all.count == 0) {
        [all addObjectsFromArray:app.windows];
    }

    NSMutableArray<UIWindow *> *visible = [NSMutableArray array];
    for (UIWindow *window in all.reverseObjectEnumerator) {
        if (window.isHidden || window.alpha < 0.05) continue;
        if (CGRectIsEmpty(window.bounds)) continue;
        if (ASIsSystemInputWindow(window)) continue;
        if ([window isKindOfClass:[SplashAwayHUDWindow class]]) continue;
        [visible addObject:window];
    }
    return [visible sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static UIViewController *ASTopViewController(UIWindow *window) {
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static id<UICoordinateSpace> ASScreenSpaceForView(UIView *view) {
    UIScreen *screen = view.window.screen ?: view.window.windowScene.screen ?: [UIScreen mainScreen];
    return screen.coordinateSpace;
}

static CGPoint ASScreenPointFromView(UIView *view, CGPoint point) {
    if (!view) return point;
    return [view convertPoint:point toCoordinateSpace:ASScreenSpaceForView(view)];
}

static CGPoint ASViewPointFromScreen(UIView *view, CGPoint screenPoint) {
    if (!view) return screenPoint;
    return [view convertPoint:screenPoint fromCoordinateSpace:ASScreenSpaceForView(view)];
}

static BOOL ASIsUsableScreenPoint(CGPoint point) {
    if (!isfinite(point.x) || !isfinite(point.y)) return NO;
    if (point.x < 1.0 && point.y < 1.0) return NO;
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat side = MAX(bounds.size.width, bounds.size.height);
    return point.x >= 0 && point.y >= 0 && point.x <= side && point.y <= side;
}

#pragma mark - 独立 HUD 窗口

@implementation SplashAwayHUDWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

@end

@implementation SplashAwayHUDRootView

- (void)didAddSubview:(UIView *)subview {
    [super didAddSubview:subview];
    self.window.hidden = NO;
}

- (void)willRemoveSubview:(UIView *)subview {
    [super willRemoveSubview:subview];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SplashAwayHUDRootView *strongSelf = weakSelf;
        if (strongSelf && strongSelf.subviews.count == 0) strongSelf.window.hidden = YES;
    });
}

@end

static UIViewController *ASStatusBarSource(UIWindow *host, BOOL forHidden) {
    UIViewController *controller = host ? ASTopViewController(host) : nil;
    for (NSInteger depth = 0; depth < 8 && controller; depth++) {
        UIViewController *child = forHidden ? controller.childViewControllerForStatusBarHidden : controller.childViewControllerForStatusBarStyle;
        if (!child) break;
        controller = child;
    }
    return controller;
}

@implementation SplashAwayHUDController

- (void)loadView {
    SplashAwayHUDRootView *root = [[SplashAwayHUDRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    UIViewController *source = ASStatusBarSource(self.hostWindow, NO);
    return source ? source.preferredStatusBarStyle : UIStatusBarStyleDefault;
}

- (BOOL)prefersStatusBarHidden {
    UIViewController *source = ASStatusBarSource(self.hostWindow, YES);
    return source ? source.prefersStatusBarHidden : NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *top = self.hostWindow ? ASTopViewController(self.hostWindow) : nil;
    return top ? top.supportedInterfaceOrientations : UIInterfaceOrientationMaskAll;
}

- (BOOL)shouldAutorotate {
    UIViewController *top = self.hostWindow ? ASTopViewController(self.hostWindow) : nil;
    return top ? top.shouldAutorotate : YES;
}

@end

#pragma mark - 手势目标直接派发

static BOOL ASFireTapGesture(UIGestureRecognizer *gesture) {
    BOOL fired = NO;
    @try {
        Ivar targetsIvar = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
        if (!targetsIvar) return NO;
        NSArray *targets = [object_getIvar(gesture, targetsIvar) copy];
        for (id entry in targets) {
            Ivar targetIvar = class_getInstanceVariable([entry class], "_target");
            Ivar actionIvar = class_getInstanceVariable([entry class], "_action");
            if (!targetIvar || !actionIvar) continue;
            id target = object_getIvar(entry, targetIvar);
            SEL action = *(SEL *)((uint8_t *)(__bridge void *)entry + ivar_getOffset(actionIvar));
            if (target && action && [target respondsToSelector:action]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, action, gesture);
                fired = YES;
            }
        }
    } @catch (NSException *exception) {
        return fired;
    }
    return fired;
}

#pragma mark - 合成触摸

typedef struct __IOHIDEvent *ASHIDEventRef;
typedef ASHIDEventRef (*ASHIDCreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                                double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef ASHIDEventRef (*ASHIDCreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                             double, double, double, double, double, double, double, double, double, double,
                                             Boolean, Boolean, uint32_t);
typedef void (*ASHIDAppendFn)(ASHIDEventRef, ASHIDEventRef, uint32_t);
typedef void (*ASHIDSetIntegerFn)(ASHIDEventRef, uint32_t, long);

static const uint32_t kASHIDTransducerHand = 3;
static const uint32_t kASHIDEventMaskTouch = 0x2;
static const uint32_t kASHIDEventMaskRangeTouch = 0x3;
static const uint32_t kASHIDFieldDisplayIntegrated = (11 << 16) | 25;

static ASHIDEventRef ASCreateHIDEvent(CGPoint point, BOOL touching) {
    static ASHIDCreateDigitizerFn createHand;
    static ASHIDCreateFingerFn createFinger;
    static ASHIDAppendFn appendEvent;
    static ASHIDSetIntegerFn setInteger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createHand = (ASHIDCreateDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        createFinger = (ASHIDCreateFingerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        appendEvent = (ASHIDAppendFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        setInteger = (ASHIDSetIntegerFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    });
    if (!createHand || !createFinger || !appendEvent || !setInteger) return NULL;

    uint64_t timestamp = mach_absolute_time();
    ASHIDEventRef hand = createHand(kCFAllocatorDefault, timestamp, kASHIDTransducerHand, 0, 0, kASHIDEventMaskTouch, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return NULL;
    setInteger(hand, kASHIDFieldDisplayIntegrated, 1);
    ASHIDEventRef finger = createFinger(kCFAllocatorDefault, timestamp, 1, 2, kASHIDEventMaskRangeTouch,
                                        point.x, point.y, 0, 0, 0, 5.0, 5.0, 1.0, 1.0, 1.0, touching, touching, 0);
    if (finger) {
        setInteger(finger, kASHIDFieldDisplayIntegrated, 1);
        appendEvent(hand, finger, 0);
        CFRelease(finger);
    }
    return hand;
}

static void ASSendBool(id target, NSString *selectorName, BOOL value) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([target respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
    }
}

static UITouch *ASMakeTouch(UIWindow *window, UIView *view, CGPoint point) {
    SEL setWindowSel = NSSelectorFromString(@"setWindow:");
    SEL setViewSel = NSSelectorFromString(@"setView:");
    SEL setLocationSel = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    SEL setPhaseSel = NSSelectorFromString(@"setPhase:");
    SEL setTimestampSel = NSSelectorFromString(@"setTimestamp:");
    SEL setTapCountSel = NSSelectorFromString(@"setTapCount:");
    SEL setGestureViewSel = NSSelectorFromString(@"setGestureView:");

    UITouch *touch = [[UITouch alloc] init];
    for (NSValue *required in @[[NSValue valueWithPointer:setWindowSel], [NSValue valueWithPointer:setViewSel],
                                [NSValue valueWithPointer:setLocationSel], [NSValue valueWithPointer:setPhaseSel],
                                [NSValue valueWithPointer:setTimestampSel]]) {
        if (![touch respondsToSelector:(SEL)required.pointerValue]) return nil;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(touch, setWindowSel, window);
    ((void (*)(id, SEL, id))objc_msgSend)(touch, setViewSel, view);
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, setLocationSel, point, YES);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, setPhaseSel, UITouchPhaseBegan);
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(touch, setTimestampSel, [NSProcessInfo processInfo].systemUptime);
    if ([touch respondsToSelector:setTapCountSel]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(touch, setTapCountSel, 1);
    }
    if ([touch respondsToSelector:setGestureViewSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(touch, setGestureViewSel, view);
    }
    ASSendBool(touch, @"_setIsFirstTouchForView:", YES);
    ASSendBool(touch, @"setIsTap:", YES);
    return touch;
}

static BOOL ASSendTouchEvent(UITouch *touch, ASHIDEventRef hidEvent) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL touchesEventSel = NSSelectorFromString(@"_touchesEvent");
    SEL clearSel = NSSelectorFromString(@"_clearTouches");
    SEL setHIDSel = NSSelectorFromString(@"_setHIDEvent:");
    SEL addTouchSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
    if (![app respondsToSelector:touchesEventSel]) return NO;

    UIEvent *event = ((UIEvent *(*)(id, SEL))objc_msgSend)(app, touchesEventSel);
    if (!event || ![event respondsToSelector:clearSel] || ![event respondsToSelector:addTouchSel]) return NO;

    ((void (*)(id, SEL))objc_msgSend)(event, clearSel);
    if (hidEvent && [event respondsToSelector:setHIDSel]) {
        ((void (*)(id, SEL, ASHIDEventRef))objc_msgSend)(event, setHIDSel, hidEvent);
    }
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addTouchSel, touch, NO);
    [app sendEvent:event];
    return YES;
}

static BOOL ASDispatchTouch(UITouch *touch, UIView *view, CGPoint point, UITouchPhase phase, BOOL *viaEvent) {
    BOOL ended = (phase == UITouchPhaseEnded);
    @try {
        if (ended) {
            ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, NSSelectorFromString(@"_setLocationInWindow:resetPrevious:"), point, NO);
        }
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setPhase:"), phase);
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(touch, NSSelectorFromString(@"setTimestamp:"), [NSProcessInfo processInfo].systemUptime);
    } @catch (NSException *exception) {
        return NO;
    }

    if (*viaEvent) {
        ASHIDEventRef hidEvent = ASCreateHIDEvent(point, !ended);
        BOOL sent = NO;
        @try {
            SEL touchHIDSel = NSSelectorFromString(@"_setHidEvent:");
            if (hidEvent && [touch respondsToSelector:touchHIDSel]) {
                ((void (*)(id, SEL, ASHIDEventRef))objc_msgSend)(touch, touchHIDSel, hidEvent);
            }
            sent = ASSendTouchEvent(touch, hidEvent);
        } @catch (NSException *exception) {
            sent = NO;
        }
        if (hidEvent) CFRelease(hidEvent);
        if (sent) return YES;
        *viaEvent = NO;
    }

    @try {
        NSSet<UITouch *> *touches = [NSSet setWithObject:touch];
        if (ended) {
            [view touchesEnded:touches withEvent:nil];
        } else {
            [view touchesBegan:touches withEvent:nil];
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return YES;
}

static BOOL ASSynthesizeTap(UIWindow *window, UIView *view, CGPoint point) {
    UITouch *touch = nil;
    @try {
        touch = ASMakeTouch(window, view, point);
    } @catch (NSException *exception) {
        touch = nil;
    }
    if (!touch) return NO;

    __block BOOL viaEvent = YES;
    if (!ASDispatchTouch(touch, view, point, UITouchPhaseBegan, &viaEvent)) return NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ASDispatchTouch(touch, view, point, UITouchPhaseEnded, &viaEvent);
    });
    return YES;
}

#pragma mark - 引擎

@interface SplashAwayEngine : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL isMonitoring;
@property (nonatomic, assign) BOOL hasTriggered;
@property (nonatomic, assign) BOOL ocrInFlight;
@property (nonatomic, assign) BOOL customPointsTried;
@property (nonatomic, assign) BOOL cornerTried;
@property (nonatomic, assign) NSInteger ocrRuns;
@property (nonatomic, assign) CFAbsoluteTime sessionStart;
@property (nonatomic, assign) CFAbsoluteTime lastActivation;
@property (nonatomic, assign) CFAbsoluteTime lastOCR;
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, strong) NSMutableArray<NSValue *> *customPoints;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *customSignatures;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *pointLastTap;
@property (nonatomic, strong) NSHashTable<UIView *> *pointTappedViews;
@property (nonatomic, strong) dispatch_source_t pointTimer;
@property (nonatomic, strong) NSHashTable<UIView *> *failedViews;
@property (nonatomic, strong) UIView *pickOverlay;
@property (nonatomic, strong) UIView *markerView;
@property (nonatomic, strong) SplashAwayHUDWindow *hud;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIStackView *panelStack;
@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, assign) BOOL clearArmed;
@property (nonatomic, assign) BOOL switchesExpanded;
@property (nonatomic, weak) UIView *switchGroup;
@property (nonatomic, weak) UIImageView *switchChevron;
@property (nonatomic, weak) UILabel *switchSummary;
@property (nonatomic, strong) NSHashTable<UIView *> *handledPopups;
@property (nonatomic, strong) NSHashTable<UIView *> *freshRoots;
@property (nonatomic, assign) CFAbsoluteTime lastPopupAction;
@property (nonatomic, assign) CFAbsoluteTime lastPassiveScan;
@property (nonatomic, assign) BOOL passiveScanPending;
@property (nonatomic, assign) BOOL enabledOn;
@property (nonatomic, assign) BOOL popupOn;
@property (nonatomic, assign) BOOL watchOn;
+ (instancetype)shared;
- (void)markActivationAndStart;
- (void)handleWindowBecameVisible:(UIWindow *)window;
- (void)scheduleLaunchToastAttempt:(NSInteger)attempt;
- (void)noteUIChange:(UIView *)root fresh:(BOOL)fresh;
@end

static BOOL gASWatchActive = NO;

@implementation SplashAwayEngine

+ (instancetype)shared {
    static SplashAwayEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SplashAwayEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _customPoints = [NSMutableArray array];
        _customSignatures = [NSMutableArray array];
        _pointLastTap = [NSMutableDictionary dictionary];
        _pointTappedViews = [NSHashTable weakObjectsHashTable];
        _failedViews = [NSHashTable weakObjectsHashTable];
        _handledPopups = [NSHashTable weakObjectsHashTable];
        _freshRoots = [NSHashTable weakObjectsHashTable];
        [self loadCustomPoints];
        [self refreshCachedSettings];
    }
    return self;
}

- (void)refreshCachedSettings {
    self.enabledOn = [self boolForKey:kASEnabledDefaultsKey];
    self.popupOn = [self boolForKey:kASPopupDefaultsKey];
    self.watchOn = [self boolForKey:kASWatchDefaultsKey];
    gASWatchActive = self.enabledOn && self.watchOn;
    [self updatePointWatcher];
}

#pragma mark 坐标持久化

- (NSString *)legacyCustomPointsFilePath {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [[cacheDir stringByAppendingPathComponent:@"AdSkip"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleId]];
}

- (void)loadCustomPoints {
    [self.customPoints removeAllObjects];
    [self.customSignatures removeAllObjects];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *rawPoints = [defaults arrayForKey:kASPointsDefaultsKey];
    if (!rawPoints) {
        NSString *legacyPath = [self legacyCustomPointsFilePath];
        rawPoints = [NSArray arrayWithContentsOfFile:legacyPath];
        if (rawPoints) {
            [defaults setObject:rawPoints forKey:kASPointsDefaultsKey];
            [[NSFileManager defaultManager] removeItemAtPath:legacyPath error:nil];
        }
    }
    for (id item in rawPoints) {
        if ([item isKindOfClass:[NSString class]]) {
            CGPoint point = CGPointFromString(item);
            if (ASIsUsableScreenPoint(point)) {
                [self.customPoints addObject:[NSValue valueWithCGPoint:point]];
                [self.customSignatures addObject:@{}];
            }
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = item;
            id rawPoint = dict[@"point"];
            if (![rawPoint isKindOfClass:[NSString class]]) continue;
            CGPoint point = CGPointFromString(rawPoint);
            if (!ASIsUsableScreenPoint(point)) continue;
            NSMutableDictionary *signature = [dict mutableCopy];
            [signature removeObjectForKey:@"point"];
            [self.customPoints addObject:[NSValue valueWithCGPoint:point]];
            [self.customSignatures addObject:[signature copy]];
        }
    }
}

- (void)persistCustomPoints {
    NSMutableArray *rawPoints = [NSMutableArray array];
    [self.customPoints enumerateObjectsUsingBlock:^(NSValue *value, NSUInteger index, BOOL *stop) {
        NSString *pointString = NSStringFromCGPoint(value.CGPointValue);
        NSDictionary *signature = index < self.customSignatures.count ? self.customSignatures[index] : nil;
        if (signature.count == 0) {
            [rawPoints addObject:pointString];
        } else {
            NSMutableDictionary *dict = [signature mutableCopy];
            dict[@"point"] = pointString;
            [rawPoints addObject:dict];
        }
    }];
    [[NSUserDefaults standardUserDefaults] setObject:rawPoints forKey:kASPointsDefaultsKey];
    [self.pointLastTap removeAllObjects];
    [self updatePointWatcher];
}

#pragma mark 坐标随时匹配

- (BOOL)hasSignedPoints {
    for (NSDictionary *signature in self.customSignatures) {
        if (signature.count > 0) return YES;
    }
    return NO;
}

- (NSArray<NSValue *> *)blindPoints {
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    [self.customPoints enumerateObjectsUsingBlock:^(NSValue *value, NSUInteger index, BOOL *stop) {
        NSDictionary *signature = index < self.customSignatures.count ? self.customSignatures[index] : nil;
        if (signature.count == 0) [points addObject:value];
    }];
    return points;
}

- (NSDictionary *)signatureAtScreenPoint:(CGPoint)screenPoint {
    for (UIWindow *window in ASVisibleWindows()) {
        CGPoint point = ASViewPointFromScreen(window, screenPoint);
        if (!CGRectContainsPoint(window.bounds, point)) continue;
        UIView *hit = [window hitTest:point withEvent:nil];
        if (!hit || hit == window || hit.tag == kASOwnViewTag) continue;
        UIView *anchor = ASSignatureAnchorForHit(hit, window);
        NSString *text = ASSignatureTextOfView(anchor, window);
        CGRect rect = [anchor convertRect:anchor.bounds toView:window];
        NSMutableDictionary *signature = [NSMutableDictionary dictionary];
        signature[@"cls"] = NSStringFromClass([anchor class]) ?: @"";
        signature[@"size"] = NSStringFromCGSize(rect.size);
        if (text.length > 0) signature[@"text"] = text;
        if (text.length == 0 && ASIsGenericViewClass(anchor)) return @{};
        return signature;
    }
    return @{};
}

- (void)updatePointWatcher {
    BOOL want = self.enabledOn && [self hasSignedPoints];
    if (want && !self.pointTimer) {
        self.pointTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(self.pointTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(kASPointWatchInterval * NSEC_PER_SEC),
                                  (uint64_t)(0.2 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.pointTimer, ^{
            [weakSelf watchSignedPoints];
        });
        dispatch_resume(self.pointTimer);
    } else if (!want && self.pointTimer) {
        dispatch_source_cancel(self.pointTimer);
        self.pointTimer = nil;
    }
}

- (BOOL)view:(UIView *)anchor inWindow:(UIWindow *)window matchesSignature:(NSDictionary *)signature {
    NSString *recordedText = [signature[@"text"] isKindOfClass:[NSString class]] ? signature[@"text"] : @"";
    if (recordedText.length > 0) {
        return ASSignatureTextMatches(recordedText, ASSignatureTextOfView(anchor, window));
    }
    NSString *recordedClass = [signature[@"cls"] isKindOfClass:[NSString class]] ? signature[@"cls"] : @"";
    if (recordedClass.length == 0 || ![recordedClass isEqualToString:NSStringFromClass([anchor class])]) return NO;
    if (ASIsGenericViewClass(anchor)) return NO;
    if ([signature[@"size"] isKindOfClass:[NSString class]]) {
        CGSize recordedSize = CGSizeFromString(signature[@"size"]);
        CGSize size = [anchor convertRect:anchor.bounds toView:window].size;
        if (fabs(size.width - recordedSize.width) > MAX(8, recordedSize.width * 0.2) ||
            fabs(size.height - recordedSize.height) > MAX(8, recordedSize.height * 0.2)) return NO;
    }
    return YES;
}

- (void)watchSignedPoints {
    if (!self.enabledOn || self.pickOverlay || self.panelView) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || app.applicationState != UIApplicationStateActive) return;
    NSArray<UIWindow *> *windows = ASVisibleWindows();
    if (windows.count == 0) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSArray<NSValue *> *points = [self.customPoints copy];
    NSArray<NSDictionary *> *signatures = [self.customSignatures copy];
    for (NSUInteger index = 0; index < points.count && index < signatures.count; index++) {
        NSDictionary *signature = signatures[index];
        if (signature.count == 0) continue;
        NSNumber *last = self.pointLastTap[@(index)];
        if (last && now - last.doubleValue < kASPointCooldown) continue;
        CGPoint screenPoint = points[index].CGPointValue;
        for (UIWindow *window in windows) {
            CGPoint point = ASViewPointFromScreen(window, screenPoint);
            if (!CGRectContainsPoint(window.bounds, point)) continue;
            UIView *hit = [window hitTest:point withEvent:nil];
            if (!hit || hit == window || hit.tag == kASOwnViewTag) break;
            UIView *anchor = ASSignatureAnchorForHit(hit, window);
            if ([self.pointTappedViews containsObject:anchor]) break;
            if (![self view:anchor inWindow:window matchesSignature:signature]) break;
            self.pointLastTap[@(index)] = @(now);
            [self.pointTappedViews addObject:anchor];
            if ([self activateView:hit inWindow:window] || ASSynthesizeTap(window, hit, point)) {
                [self recordSkipWithMethod:@"自定义坐标"];
                [self showTapFeedbackAtPoint:point inWindow:window];
            }
            return;
        }
    }
}

#pragma mark 会话调度

- (void)markActivationAndStart {
    self.lastActivation = CFAbsoluteTimeGetCurrent();
    for (UIWindow *window in ASVisibleWindows()) {
        [self installSettingsGestureOnWindow:window];
    }
    [self startSession];
}

- (void)handleWindowBecameVisible:(UIWindow *)window {
    if ([window isKindOfClass:[SplashAwayHUDWindow class]]) return;
    [self installSettingsGestureOnWindow:window];
    if (!ASIsSystemInputWindow(window)) [self noteUIChange:window fresh:YES];
    if (self.hasTriggered || self.isMonitoring || self.pickOverlay || self.panelView) return;
    if (CFAbsoluteTimeGetCurrent() - self.lastActivation > kASActivationWindow) return;
    [self startSession];
}

- (void)startSession {
    [self stopSession];
    if (![self boolForKey:kASEnabledDefaultsKey]) return;
    self.hasTriggered = NO;
    self.ocrInFlight = NO;
    self.customPointsTried = NO;
    self.cornerTried = NO;
    self.ocrRuns = 0;
    self.lastOCR = 0;
    [self.failedViews removeAllObjects];
    self.sessionStart = CFAbsoluteTimeGetCurrent();
    self.isMonitoring = YES;

    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                              (uint64_t)(kASTickInterval * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf tick];
    });
    dispatch_resume(self.scanTimer);
}

- (void)stopSession {
    self.isMonitoring = NO;
    if (self.scanTimer) {
        dispatch_source_cancel(self.scanTimer);
        self.scanTimer = nil;
    }
}

- (void)tick {
    if (!self.isMonitoring) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval elapsed = now - self.sessionStart;
    if (self.hasTriggered || self.pickOverlay || self.panelView || elapsed > kASSessionDuration) {
        [self stopSession];
        return;
    }

    NSArray<UIWindow *> *windows = ASVisibleWindows();
    if (windows.count == 0) return;
    for (UIWindow *window in windows) {
        [self installSettingsGestureOnWindow:window];
    }

    if ([self scanNativeHierarchyInWindows:windows]) return;

    if (self.popupOn && elapsed >= kASPopupStartDelay && [self dismissPopupsInWindows:windows]) return;

    if (!self.customPointsTried && [self blindPoints].count > 0 && elapsed >= kASCustomPointDelay) {
        self.customPointsTried = YES;
        [self tapCustomPoints];
        return;
    }

    BOOL ocrEnabled = [self boolForKey:kASOCRDefaultsKey];
    if (ocrEnabled && !self.ocrInFlight && self.ocrRuns < kASOCRMaxRuns &&
        elapsed >= kASOCRStartDelay && now - self.lastOCR >= kASOCRInterval) {
        [self runOCROnWindow:windows.firstObject];
        return;
    }

    BOOL ocrExhausted = ocrEnabled ? (!self.ocrInFlight && self.ocrRuns >= kASOCRMaxRuns) : elapsed >= kASCornerFallbackDelay;
    if (!self.cornerTried && ocrExhausted && [self boolForKey:kASCornerDefaultsKey]) {
        self.cornerTried = YES;
        [self tapTopRightCornerInWindow:windows.firstObject];
    }
}

#pragma mark 第四级：右上角兜底

- (void)tapTopRightCornerInWindow:(UIWindow *)window {
    if (!window) return;
    UIEdgeInsets insets = window.safeAreaInsets;
    CGPoint point = CGPointMake(window.bounds.size.width - 30.0 - insets.right, insets.top + 30.0);
    UIView *hit = [window hitTest:point withEvent:nil];
    for (UIView *current = hit; current; current = current.superview) {
        if ([current isKindOfClass:[UINavigationBar class]] || [current isKindOfClass:[UITabBar class]] ||
            [current isKindOfClass:[UIToolbar class]] || [current isKindOfClass:[UISearchBar class]]) {
            return;
        }
    }
    if ([self activateScreenPoint:ASScreenPointFromView(window, point)]) {
        [self finishWithFeedbackAtPoint:point inWindow:window method:@"右上角兜底"];
    }
}

#pragma mark 第一级：视图树扫描

- (BOOL)scanNativeHierarchyInWindows:(NSArray<UIWindow *> *)windows {
    for (UIWindow *window in windows) {
        NSInteger budget = kASScanNodeBudget;
        UIView *candidate = [self findSkipViewIn:window window:window depth:0 budget:&budget strict:NO];
        if (!candidate) continue;

        CGRect rect = [candidate convertRect:candidate.bounds toView:window];
        CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
        if ([self activateView:candidate inWindow:window] ||
            [self activateScreenPoint:ASScreenPointFromView(window, center)]) {
            [self finishWithFeedbackAtPoint:center inWindow:window method:@"按钮识别"];
            return YES;
        }
        [self.failedViews addObject:candidate];
    }
    return NO;
}

- (UIView *)findSkipViewIn:(UIView *)view window:(UIWindow *)window depth:(NSInteger)depth budget:(NSInteger *)budget strict:(BOOL)strict {
    if (!view || depth > 30 || *budget <= 0) return nil;
    (*budget)--;
    if (view.isHidden || view.alpha < 0.05 || view.tag == kASOwnViewTag) return nil;

    CGRect rect = (view == window) ? window.bounds : [view convertRect:view.bounds toView:window];
    if (!CGRectIntersectsRect(rect, window.bounds)) return nil;

    if (view != window && ![self.failedViews containsObject:view] && [self isButtonSizedRect:rect inWindow:window]) {
        NSString *text = ASTextOfView(view);
        if (text.length > 0 && ASIsSkipText(text, strict)) return view;
    }

    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        UIView *found = [self findSkipViewIn:subview window:window depth:depth + 1 budget:budget strict:strict];
        if (found) return found;
    }
    return nil;
}

- (BOOL)isButtonSizedRect:(CGRect)rect inWindow:(UIWindow *)window {
    CGSize windowSize = window.bounds.size;
    if (rect.size.width < 12 || rect.size.height < 12) return NO;
    if (rect.size.width > windowSize.width * 0.6) return NO;
    if (rect.size.height > MIN(100.0, windowSize.height * 0.25)) return NO;
    return YES;
}

#pragma mark 弹窗清理

- (BOOL)dismissPopupsInWindows:(NSArray<UIWindow *> *)windows {
    if (CFAbsoluteTimeGetCurrent() - self.lastPopupAction < kASPopupCooldown) return NO;
    for (UIWindow *window in windows) {
        BOOL hasAlert = NO;
        if ([self dismissAlertInWindow:window hasAlert:&hasAlert]) return YES;
        if (hasAlert) continue;
        if ([self dismissOverlayPopupInWindow:window]) return YES;
    }
    return NO;
}

- (BOOL)dismissAlertInWindow:(UIWindow *)window hasAlert:(BOOL *)hasAlert {
    UIViewController *controller = window.rootViewController;
    while (controller && ![controller isKindOfClass:[UIAlertController class]]) {
        UIViewController *next = controller.presentedViewController;
        if (!next || next.isBeingDismissed) return NO;
        controller = next;
    }
    if (!controller) return NO;
    *hasAlert = YES;
    if (controller.isBeingDismissed || controller.isBeingPresented) return NO;

    UIAlertController *alert = (UIAlertController *)controller;
    if (alert.preferredStyle != UIAlertControllerStyleAlert || alert.textFields.count > 0) return NO;
    if ([self.handledPopups containsObject:alert.view]) return NO;
    NSString *context = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""];
    if (ASPopupTextIsDangerous(context)) return NO;
    BOOL nuisance = ASPopupTextIsNuisance(context);

    UIAlertAction *strongAction = nil, *weakAction = nil;
    for (UIAlertAction *action in alert.actions) {
        if (ASPopupTextIsDangerous(action.title)) return NO;
        if (!action.isEnabled || action.style == UIAlertActionStyleDestructive) continue;
        ASDismissLevel level = ASDismissLevelForText(action.title);
        if (level == ASDismissStrong && !strongAction) strongAction = action;
        else if ((level == ASDismissWeak || action.style == UIAlertActionStyleCancel) && !weakAction) weakAction = action;
    }
    UIAlertAction *chosen = strongAction ?: (nuisance ? weakAction : nil);
    if (!chosen) return NO;

    void (^handler)(UIAlertAction *) = nil;
    @try {
        handler = [chosen valueForKey:@"handler"];
    } @catch (NSException *exception) {
        handler = nil;
    }
    [self.handledPopups addObject:alert.view];
    CGRect rect = [alert.view convertRect:alert.view.bounds toView:window];
    UIViewController *presenter = alert.presentingViewController ?: alert;
    [presenter dismissViewControllerAnimated:YES completion:^{
        if (!handler) return;
        @try {
            handler(chosen);
        } @catch (NSException *exception) {
        }
    }];
    [self didDismissPopupAtPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect) - 22) inWindow:window];
    return YES;
}

- (BOOL)isNearlyFullRect:(CGRect)rect inWindow:(UIWindow *)window {
    CGSize size = window.bounds.size;
    return rect.size.width >= size.width * 0.9 && rect.size.height >= size.height * 0.85;
}

- (UIView *)findBackdropIn:(UIView *)view window:(UIWindow *)window depth:(NSInteger)depth budget:(NSInteger *)budget {
    if (!view || depth > 14 || *budget <= 0) return nil;
    (*budget)--;
    if (view.isHidden || view.alpha < 0.05 || view.tag == kASOwnViewTag) return nil;
    if ([view isKindOfClass:[UIScrollView class]]) return nil;
    CGRect rect = (view == window) ? window.bounds : [view convertRect:view.bounds toView:window];
    if (![self isNearlyFullRect:rect inWindow:window]) return nil;
    if (view != window && ASIsDimBackdropView(view)) return view;
    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        UIView *found = [self findBackdropIn:subview window:window depth:depth + 1 budget:budget];
        if (found) return found;
    }
    return nil;
}

- (void)collectPopupItemsIn:(UIView *)view window:(UIWindow *)window depth:(NSInteger)depth budget:(NSInteger *)budget
                      texts:(NSMutableString *)texts candidates:(NSMutableArray<UIView *> *)candidates {
    if (!view || depth > 25 || *budget <= 0) return;
    (*budget)--;
    if (view.isHidden || view.alpha < 0.05 || view.tag == kASOwnViewTag) return;
    CGRect rect = [view convertRect:view.bounds toView:window];
    if (!CGRectIntersectsRect(rect, window.bounds)) return;

    NSString *text = ASTextOfView(view);
    if (text.length > 0 && text.length <= 200) {
        [texts appendString:text];
        [texts appendString:@" "];
    }
    CGSize size = window.bounds.size;
    if (rect.size.width >= 12 && rect.size.height >= 12 && rect.size.width <= size.width * 0.95 && rect.size.height <= 90) {
        [candidates addObject:view];
    }
    for (UIView *subview in view.subviews) {
        [self collectPopupItemsIn:subview window:window depth:depth + 1 budget:budget texts:texts candidates:candidates];
    }
}

- (BOOL)dismissOverlayPopupInWindow:(UIWindow *)window {
    NSInteger budget = kASPopupNodeBudget;
    UIView *backdrop = [self findBackdropIn:window window:window depth:0 budget:&budget];
    if (!backdrop || [self.handledPopups containsObject:backdrop]) return NO;

    NSMutableArray<UIView *> *roots = [NSMutableArray arrayWithObject:backdrop];
    UIView *parent = backdrop.superview;
    if (parent) {
        NSUInteger index = [parent.subviews indexOfObjectIdenticalTo:backdrop];
        for (NSUInteger i = index + 1; index != NSNotFound && i < parent.subviews.count; i++) {
            [roots addObject:parent.subviews[i]];
        }
    }

    NSMutableString *texts = [NSMutableString string];
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    NSInteger itemBudget = kASPopupNodeBudget;
    for (UIView *root in roots) {
        [self collectPopupItemsIn:root window:window depth:0 budget:&itemBudget texts:texts candidates:candidates];
    }
    if (ASPopupTextIsDangerous(texts)) {
        [self.handledPopups addObject:backdrop];
        return NO;
    }
    BOOL nuisance = ASPopupTextIsNuisance(texts);
    NSString *trimmed = [texts stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL imageOnly = trimmed.length <= 4;

    UIView *strongView = nil, *weakView = nil, *iconView = nil;
    for (UIView *view in candidates) {
        NSString *text = ASTextOfView(view);
        CGRect rect = [view convertRect:view.bounds toView:window];
        if (text.length > 0) {
            ASDismissLevel level = ASDismissLevelForText(text);
            if (level == ASDismissStrong && !strongView) strongView = view;
            else if (level == ASDismissWeak && !weakView) weakView = view;
        } else if (!iconView && ASLooksLikeCloseIcon(view, rect)) {
            iconView = view;
        }
    }
    UIView *chosen = strongView;
    if (!chosen && nuisance) chosen = weakView;
    if (!chosen && (nuisance || imageOnly)) chosen = iconView;
    if (!chosen) return NO;

    CGRect rect = [chosen convertRect:chosen.bounds toView:window];
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    [self.handledPopups addObject:backdrop];
    if (![self activateView:chosen inWindow:window] && ![self activateScreenPoint:ASScreenPointFromView(window, center)]) {
        return NO;
    }
    [self didDismissPopupAtPoint:center inWindow:window];
    return YES;
}

- (void)didDismissPopupAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    self.lastPopupAction = CFAbsoluteTimeGetCurrent();
    [self recordPopupWithMethod:@"弹窗清理"];
    [self showTapFeedbackAtPoint:point inWindow:window];
    if (self.watchOn) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kASPopupCooldown + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf noteUIChange:nil fresh:NO];
        });
    }
}

#pragma mark 全程监听

- (void)noteUIChange:(UIView *)root fresh:(BOOL)fresh {
    if (!self.enabledOn || !self.watchOn) return;
    if (root && fresh) [self.freshRoots addObject:root];
    if (self.passiveScanPending) return;
    self.passiveScanPending = YES;
    NSTimeInterval sinceLast = CFAbsoluteTimeGetCurrent() - self.lastPassiveScan;
    NSTimeInterval delay = MAX(kASPassiveScanDelay, 1.0 - sinceLast);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf passiveScan];
    });
}

- (void)passiveScan {
    self.passiveScanPending = NO;
    if (!self.enabledOn || !self.watchOn) return;
    if (self.isMonitoring || self.pickOverlay || self.panelView) {
        [self.freshRoots removeAllObjects];
        return;
    }
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    self.lastPassiveScan = CFAbsoluteTimeGetCurrent();

    NSArray<UIView *> *roots = self.freshRoots.allObjects;
    [self.freshRoots removeAllObjects];
    NSArray<UIWindow *> *windows = ASVisibleWindows();
    if (windows.count == 0) return;

    if (self.popupOn && [self dismissPopupsInWindows:windows]) return;

    for (UIView *root in roots) {
        UIWindow *window = [root isKindOfClass:[UIWindow class]] ? (UIWindow *)root : root.window;
        if (!window || ![windows containsObject:window]) continue;
        if (root.isHidden || root.alpha < 0.05) continue;
        CGRect rect = (root == window) ? window.bounds : [root convertRect:root.bounds toView:window];
        CGRect overlap = CGRectIntersection(rect, window.bounds);
        CGFloat area = window.bounds.size.width * window.bounds.size.height;
        if (area <= 0 || overlap.size.width * overlap.size.height < area * 0.8) continue;

        NSInteger budget = kASScanNodeBudget;
        UIView *candidate = [self findSkipViewIn:root window:window depth:0 budget:&budget strict:YES];
        if (!candidate) continue;
        CGRect candidateRect = [candidate convertRect:candidate.bounds toView:window];
        CGPoint center = CGPointMake(CGRectGetMidX(candidateRect), CGRectGetMidY(candidateRect));
        if ([self activateView:candidate inWindow:window] ||
            [self activateScreenPoint:ASScreenPointFromView(window, center)]) {
            [self recordSkipWithMethod:@"插屏跳过"];
            [self showTapFeedbackAtPoint:center inWindow:window];
        } else {
            [self.failedViews addObject:candidate];
        }
        return;
    }
}

#pragma mark 点击派发

- (BOOL)activateView:(UIView *)view inWindow:(UIWindow *)window {
    CGSize windowSize = window.bounds.size;
    UIView *current = view;
    for (NSInteger level = 0; level < 4 && current && current != window; level++) {
        CGRect rect = [current convertRect:current.bounds toView:window];
        if (rect.size.width > windowSize.width * 0.6 || rect.size.height > windowSize.height * 0.3) break;

        if ([current isKindOfClass:[UIControl class]] && ((UIControl *)current).isEnabled) {
            [(UIControl *)current sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        for (UIGestureRecognizer *gesture in current.gestureRecognizers) {
            if ([gesture isKindOfClass:[UITapGestureRecognizer class]] && gesture.isEnabled && ASFireTapGesture(gesture)) {
                return YES;
            }
        }
        current = current.superview;
    }
    return NO;
}

- (BOOL)activateScreenPoint:(CGPoint)screenPoint {
    for (UIWindow *window in ASVisibleWindows()) {
        CGPoint point = ASViewPointFromScreen(window, screenPoint);
        if (!CGRectContainsPoint(window.bounds, point)) continue;
        UIView *hit = [window hitTest:point withEvent:nil];
        if (!hit || hit == window || hit.tag == kASOwnViewTag) continue;
        if ([self activateView:hit inWindow:window]) return YES;
        return ASSynthesizeTap(window, hit, point);
    }
    return NO;
}

#pragma mark 第二级：录制坐标

- (void)tapCustomPoints {
    NSArray<NSValue *> *points = [self blindPoints];
    self.hasTriggered = YES;
    [self stopSession];
    __block BOOL recorded = NO;
    for (NSUInteger index = 0; index < points.count; index++) {
        CGPoint screenPoint = points[index].CGPointValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(index * 0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.pickOverlay || self.panelView) return;
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
            if ([self activateScreenPoint:screenPoint]) {
                if (!recorded) {
                    recorded = YES;
                    [self recordSkipWithMethod:@"自定义坐标"];
                }
                UIWindow *window = ASVisibleWindows().firstObject;
                [self showTapFeedbackAtPoint:ASViewPointFromScreen(window, screenPoint) inWindow:window];
            }
        });
    }
}

#pragma mark 第三级：Vision OCR

- (void)runOCROnWindow:(UIWindow *)window {
    if (!window) return;
    self.ocrInFlight = YES;
    self.ocrRuns++;
    self.lastOCR = CFAbsoluteTimeGetCurrent();

    CGSize size = window.bounds.size;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    if (!snapshot.CGImage) {
        self.ocrInFlight = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    __weak UIWindow *weakWindow = window;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSValue *hitValue = nil;
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *error) {
            for (VNRecognizedTextObservation *observation in req.results) {
                CGRect box = observation.boundingBox;
                if (box.size.width > 0.4 || box.size.height > 0.08) continue;
                VNRecognizedText *top = [[observation topCandidates:1] firstObject];
                if (top && ASIsSkipText(top.string, YES)) {
                    CGFloat x = CGRectGetMidX(box) * size.width;
                    CGFloat y = (1.0 - CGRectGetMidY(box)) * size.height;
                    hitValue = [NSValue valueWithCGPoint:CGPointMake(x, y)];
                    break;
                }
            }
        }];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
        request.usesLanguageCorrection = NO;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:snapshot.CGImage options:@{}];
        [handler performRequests:@[request] error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            UIWindow *strongWindow = weakWindow;
            if (!strongSelf) return;
            strongSelf.ocrInFlight = NO;
            if (!hitValue || !strongWindow || !strongSelf.isMonitoring || strongSelf.hasTriggered) return;
            CGPoint point = hitValue.CGPointValue;
            if ([strongSelf activateScreenPoint:ASScreenPointFromView(strongWindow, point)]) {
                [strongSelf finishWithFeedbackAtPoint:point inWindow:strongWindow method:@"文字识别"];
            }
        });
    });
}

#pragma mark 偏好与统计

- (BOOL)boolForKey:(NSString *)key {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ? [value boolValue] : YES;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
}

- (BOOL)threeFingerEnabled {
    return [self boolForKey:kASThreeFingerDefaultsKey];
}

- (void)recordSkipWithMethod:(NSString *)method {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:[defaults integerForKey:kASSkipCountDefaultsKey] + 1 forKey:kASSkipCountDefaultsKey];
    [defaults setObject:method ?: @"" forKey:kASLastMethodDefaultsKey];
    [defaults setObject:[NSDate date] forKey:kASLastDateDefaultsKey];
}

- (void)recordPopupWithMethod:(NSString *)method {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:[defaults integerForKey:kASPopupCountDefaultsKey] + 1 forKey:kASPopupCountDefaultsKey];
    [defaults setObject:method ?: @"" forKey:kASLastMethodDefaultsKey];
    [defaults setObject:[NSDate date] forKey:kASLastDateDefaultsKey];
}

- (NSString *)lastSkipDescription {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *date = [defaults objectForKey:kASLastDateDefaultsKey];
    NSString *method = [defaults stringForKey:kASLastMethodDefaultsKey];
    if (![date isKindOfClass:[NSDate class]] || method.length == 0) return @"还没有跳过记录";
    NSTimeInterval seconds = MAX(0, -[date timeIntervalSinceNow]);
    NSString *ago;
    if (seconds < 60) ago = @"刚刚";
    else if (seconds < 3600) ago = [NSString stringWithFormat:@"%d 分钟前", (int)(seconds / 60)];
    else if (seconds < 86400) ago = [NSString stringWithFormat:@"%d 小时前", (int)(seconds / 3600)];
    else ago = [NSString stringWithFormat:@"%d 天前", (int)(seconds / 86400)];
    return [NSString stringWithFormat:@"最近：%@ · %@", method, ago];
}

- (NSString *)hostAppName {
    NSDictionary *info = [NSBundle mainBundle].localizedInfoDictionary ?: @{};
    NSDictionary *baseInfo = [NSBundle mainBundle].infoDictionary ?: @{};
    NSString *name = info[@"CFBundleDisplayName"] ?: baseInfo[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: baseInfo[@"CFBundleName"];
    return name.length > 0 ? name : ([NSBundle mainBundle].bundleIdentifier ?: @"当前应用");
}

#pragma mark HUD

- (UIWindow *)resolveHostWindow:(UIWindow *)window {
    if (window && ![window isKindOfClass:[SplashAwayHUDWindow class]]) return window;
    return ASVisibleWindows().firstObject;
}

- (UIWindowScene *)activeScene {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (SplashAwayHUDWindow *)hudForWindow:(UIWindow *)window {
    UIWindow *host = [self resolveHostWindow:window];
    UIWindowScene *scene = host.windowScene ?: [self activeScene];
    if (!self.hud || (scene && self.hud.windowScene != scene)) {
        SplashAwayHUDWindow *hud = scene ? [[SplashAwayHUDWindow alloc] initWithWindowScene:scene]
                                     : [[SplashAwayHUDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        hud.windowLevel = UIWindowLevelAlert + 100;
        hud.backgroundColor = [UIColor clearColor];
        hud.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        hud.rootViewController = [[SplashAwayHUDController alloc] init];
        hud.hidden = YES;
        [self.hud.rootViewController.view.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        self.hud = hud;
    }
    ((SplashAwayHUDController *)self.hud.rootViewController).hostWindow = host;
    return self.hud;
}

- (UIView *)hudRootForWindow:(UIWindow *)window {
    SplashAwayHUDWindow *hud = [self hudForWindow:window];
    hud.hidden = NO;
    UIView *root = hud.rootViewController.view;
    root.frame = hud.bounds;
    return root;
}

- (CGPoint)hudPointForScreenPoint:(CGPoint)screenPoint {
    return self.hud ? ASViewPointFromScreen(self.hud, screenPoint) : screenPoint;
}

#pragma mark 反馈

- (void)finishWithFeedbackAtPoint:(CGPoint)point inWindow:(UIWindow *)window method:(NSString *)method {
    self.hasTriggered = YES;
    [self stopSession];
    [self recordSkipWithMethod:method];
    [self showTapFeedbackAtPoint:point inWindow:window];
}

- (void)showTapFeedbackAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (!window) return;
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator impactOccurred];

    CGPoint screenPoint = ASScreenPointFromView(window, point);
    UIView *root = [self hudRootForWindow:window];
    CGPoint center = [self hudPointForScreenPoint:screenPoint];
    UIColor *accent = ASAccentColor();

    UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    ring.center = center;
    ring.userInteractionEnabled = NO;
    ring.layer.cornerRadius = 20;
    ring.layer.borderWidth = 2.0;
    ring.layer.borderColor = accent.CGColor;
    ring.backgroundColor = [accent colorWithAlphaComponent:0.18];

    UIView *core = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 12)];
    core.center = center;
    core.userInteractionEnabled = NO;
    core.layer.cornerRadius = 6;
    core.backgroundColor = accent;
    core.layer.shadowColor = accent.CGColor;
    core.layer.shadowOpacity = 0.9;
    core.layer.shadowRadius = 6;
    core.layer.shadowOffset = CGSizeZero;

    [root addSubview:ring];
    [root addSubview:core];
    ring.transform = CGAffineTransformMakeScale(0.4, 0.4);
    [UIView animateWithDuration:0.55 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        ring.transform = CGAffineTransformMakeScale(1.8, 1.8);
        ring.alpha = 0;
    } completion:^(BOOL finished) {
        [ring removeFromSuperview];
    }];
    [UIView animateWithDuration:0.3 delay:0.35 options:0 animations:^{
        core.alpha = 0;
        core.transform = CGAffineTransformMakeScale(0.3, 0.3);
    } completion:^(BOOL finished) {
        [core removeFromSuperview];
    }];
}

- (UIView *)makePillWithTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol inWindow:(UIWindow *)window {
    if (!window) return nil;
    [self dismissPill:self.toastView];
    UIView *root = [self hudRootForWindow:window];

    UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.userInteractionEnabled = NO;
    pill.clipsToBounds = YES;
    pill.layer.cornerRadius = 22;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.borderWidth = 0.5;
    pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol ?: @"bolt.fill"]];
    icon.tintColor = ASAccentColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.numberOfLines = 0;
    titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor whiteColor];

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 1;
    if (detail.length > 0) {
        UILabel *detailLabel = [[UILabel alloc] init];
        detailLabel.text = detail;
        detailLabel.numberOfLines = 0;
        detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        detailLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        [texts addArrangedSubview:detailLabel];
    }

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [pill.contentView addSubview:row];

    [root addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor constant:-18],
        [row.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:11],
        [row.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-11],
        [pill.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [pill.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor constant:-48],
        [pill.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-48],
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];

    pill.alpha = 0;
    pill.transform = CGAffineTransformMakeTranslation(0, 16);
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.4 options:0 animations:^{
        pill.alpha = 1;
        pill.transform = CGAffineTransformIdentity;
    } completion:nil];
    self.toastView = pill;
    return pill;
}

- (void)dismissPill:(UIView *)pill {
    if (!pill) return;
    if (self.toastView == pill) self.toastView = nil;
    [UIView animateWithDuration:0.25 animations:^{
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, 12);
    } completion:^(BOOL finished) {
        [pill removeFromSuperview];
    }];
}

- (void)dismissPill:(UIView *)pill after:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    __weak UIView *weakPill = pill;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongPill = weakPill;
        if (strongPill) [weakSelf dismissPill:strongPill];
    });
}

- (void)showToast:(NSString *)message symbol:(NSString *)symbol inWindow:(UIWindow *)window {
    UIView *pill = [self makePillWithTitle:message detail:nil symbol:symbol inWindow:window];
    [self dismissPill:pill after:1.8];
}

- (void)showToast:(NSString *)message inWindow:(UIWindow *)window {
    [self showToast:message symbol:@"checkmark.circle.fill" inWindow:window];
}

#pragma mark 坐标标记

- (UIView *)makeMarkersViewWithFrame:(CGRect)frame {
    UIView *container = [[UIView alloc] initWithFrame:frame];
    container.userInteractionEnabled = NO;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.customPoints enumerateObjectsUsingBlock:^(NSValue *value, NSUInteger index, BOOL *stop) {
        CGPoint point = [self hudPointForScreenPoint:value.CGPointValue];
        UIView *halo = [[UIView alloc] initWithFrame:CGRectMake(point.x - 22, point.y - 22, 44, 44)];
        halo.layer.cornerRadius = 22;
        halo.layer.borderWidth = 1;
        halo.layer.borderColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.20 alpha:0.6].CGColor;
        halo.backgroundColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.20 alpha:0.12];
        [container addSubview:halo];

        UILabel *marker = [[UILabel alloc] initWithFrame:CGRectMake(point.x - 13, point.y - 13, 26, 26)];
        marker.text = [NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)];
        marker.textAlignment = NSTextAlignmentCenter;
        marker.textColor = [UIColor whiteColor];
        marker.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
        marker.layer.backgroundColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.10 alpha:0.95].CGColor;
        marker.layer.cornerRadius = 13;
        marker.layer.borderColor = [UIColor whiteColor].CGColor;
        marker.layer.borderWidth = 1.5;
        marker.layer.shadowColor = [UIColor blackColor].CGColor;
        marker.layer.shadowOpacity = 0.35;
        marker.layer.shadowRadius = 4;
        marker.layer.shadowOffset = CGSizeMake(0, 1);
        [container addSubview:marker];
    }];
    return container;
}

- (void)showPointMarkersInWindow:(UIWindow *)window duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    [self.markerView removeFromSuperview];
    self.markerView = nil;
    if (!window || self.customPoints.count == 0 || duration <= 0) {
        if (completion) completion();
        return;
    }
    UIView *root = [self hudRootForWindow:window];
    UIView *container = [self makeMarkersViewWithFrame:root.bounds];
    [root addSubview:container];
    self.markerView = container;

    __weak typeof(self) weakSelf = self;
    __weak UIView *weakContainer = container;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongContainer = weakContainer;
        if (!strongContainer) {
            if (completion) completion();
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{
            strongContainer.alpha = 0;
        } completion:^(BOOL finished) {
            [strongContainer removeFromSuperview];
            if (weakSelf.markerView == strongContainer) weakSelf.markerView = nil;
            if (completion) completion();
        }];
    });
}

- (void)showPointMarkersInWindow:(UIWindow *)window duration:(NSTimeInterval)duration {
    [self showPointMarkersInWindow:window duration:duration completion:nil];
}

#pragma mark 设置入口：启动提示与三指长按

- (void)refreshSettingsGestures {
    for (UIWindow *window in ASVisibleWindows()) {
        [self installSettingsGestureOnWindow:window];
    }
}

- (void)scheduleLaunchToastAttempt:(NSInteger)attempt {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive || ASVisibleWindows().count == 0) {
            if (attempt < 4) [self scheduleLaunchToastAttempt:attempt + 1];
            return;
        }
        [self showLaunchToast];
    });
}

- (void)showLaunchToast {
    if (![self boolForKey:kASLaunchToastDefaultsKey] || self.panelView || self.pickOverlay) return;
    BOOL enabled = [self boolForKey:kASEnabledDefaultsKey];
    NSString *title = enabled ? @"开屏广告走开 · 已就绪" : @"开屏广告走开 · 已暂停";
    UIView *pill = [self makePillWithTitle:title detail:@"点此打开设置"
                                    symbol:enabled ? @"bolt.fill" : @"pause.circle.fill"
                                  inWindow:ASVisibleWindows().firstObject];
    if (!pill) return;
    pill.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onLaunchToastTap:)];
    [pill addGestureRecognizer:tap];
    [self dismissPill:pill after:3.0];
}

- (void)onLaunchToastTap:(UITapGestureRecognizer *)tap {
    [self dismissPill:tap.view];
    [self presentSettingsInWindow:nil];
}

- (void)installSettingsGestureOnWindow:(UIWindow *)window {
    if (!window || ASIsSystemInputWindow(window) || [window isKindOfClass:[SplashAwayHUDWindow class]]) return;
    BOOL enabled = [self threeFingerEnabled];
    UIGestureRecognizer *existing = objc_getAssociatedObject(window, &kASGestureInstalledKey);
    if (existing) {
        existing.enabled = enabled;
        return;
    }
    if (!enabled) return;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onSettingsGesture:)];
    gesture.numberOfTouchesRequired = 3;
    gesture.minimumPressDuration = 0.6;
    gesture.cancelsTouchesInView = NO;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, &kASGestureInstalledKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)onSettingsGesture:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIWindow *window = gesture.view.window ?: (UIWindow *)gesture.view;
    [self presentSettingsInWindow:window];
}

#pragma mark 设置面板

- (void)presentSettingsInWindow:(UIWindow *)window {
    if (self.pickOverlay) return;
    if (self.panelView) {
        [self rebuildPanel];
        return;
    }
    UIWindow *host = [self resolveHostWindow:window];
    if (!host) return;
    [self stopSession];
    [self dismissPill:self.toastView];
    self.clearArmed = NO;
    self.switchesExpanded = NO;

    UIView *root = [self hudRootForWindow:host];
    UIView *panel = [[UIView alloc] initWithFrame:root.bounds];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIControl *backdrop = [[UIControl alloc] initWithFrame:panel.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [backdrop addTarget:self action:@selector(onPanelClose) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:backdrop];

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.clipsToBounds = YES;
    card.layer.cornerRadius = 26;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    [panel addSubview:card];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [card.contentView addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    NSLayoutConstraint *fitHeight = [scroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:36];
    fitHeight.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *preferredWidth = [card.widthAnchor constraintEqualToAnchor:panel.widthAnchor constant:-32];
    preferredWidth.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:panel.safeAreaLayoutGuide.centerYAnchor],
        preferredWidth,
        [card.widthAnchor constraintLessThanOrEqualToConstant:380],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:panel.safeAreaLayoutGuide.heightAnchor constant:-24],
        [scroll.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        fitHeight,
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-18],
    ]];

    self.panelView = panel;
    self.panelStack = stack;
    [self rebuildPanel];
    [root addSubview:panel];

    backdrop.alpha = 0;
    card.alpha = 0;
    card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:0 animations:^{
        backdrop.alpha = 1;
        card.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismissPanelThen:(void (^)(void))completion {
    UIView *panel = self.panelView;
    self.panelView = nil;
    self.panelStack = nil;
    self.clearArmed = NO;
    if (!panel) {
        if (completion) completion();
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{
        panel.alpha = 0;
    } completion:^(BOOL finished) {
        [panel removeFromSuperview];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    }];
}

- (void)onPanelClose {
    [self dismissPanelThen:nil];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    return label;
}

- (UIView *)groupWithRows:(NSArray<UIView *> *)rows {
    UIStackView *group = [[UIStackView alloc] init];
    group.axis = UILayoutConstraintAxisVertical;
    group.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    group.layer.cornerRadius = 16;
    group.layer.cornerCurve = kCACornerCurveContinuous;
    group.clipsToBounds = YES;
    [rows enumerateObjectsUsingBlock:^(UIView *row, NSUInteger index, BOOL *stop) {
        if (index > 0) {
            UIView *line = [[UIView alloc] init];
            line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
            [group addArrangedSubview:line];
        }
        [group addArrangedSubview:row];
    }];
    return group;
}

- (UIView *)switchRowWithTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol key:(NSString *)key tag:(NSInteger)tag {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = ASAccentColor();
    icon.contentMode = UIViewContentModeCenter;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self labelWithText:title size:15 weight:UIFontWeightMedium alpha:0.95],
        [self labelWithText:detail size:12 weight:UIFontWeightRegular alpha:0.5],
    ]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.onTintColor = ASAccentColor();
    toggle.on = [self boolForKey:key];
    toggle.tag = tag;
    [toggle addTarget:self action:@selector(onPanelSwitch:) forControlEvents:UIControlEventValueChanged];
    [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.layoutMarginsRelativeArrangement = YES;
    row.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(11, 12, 11, 12);
    return row;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action enabled:(BOOL)enabled destructive:(BOOL)destructive {
    UIColor *tint = destructive ? [UIColor colorWithRed:1.0 green:0.42 blue:0.40 alpha:1.0] : ASAccentColor();
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.tintColor = tint;
    button.enabled = enabled;
    button.alpha = enabled ? 1.0 : 0.35;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = tint;
    icon.contentMode = UIViewContentModeCenter;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    UILabel *label = [self labelWithText:title size:12 weight:UIFontWeightMedium alpha:0.9];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label]];
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 5;
    content.userInteractionEnabled = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:button.leadingAnchor constant:4],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-4],
        [button.heightAnchor constraintEqualToConstant:62],
    ]];
    return button;
}

- (void)rebuildPanel {
    UIStackView *stack = self.panelStack;
    if (!stack) return;
    for (UIView *view in stack.arrangedSubviews) {
        [stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    BOOL enabled = [self boolForKey:kASEnabledDefaultsKey];

    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.fill"]];
    logo.tintColor = [UIColor blackColor];
    logo.contentMode = UIViewContentModeCenter;
    logo.backgroundColor = enabled ? ASAccentColor() : [UIColor colorWithWhite:0.6 alpha:1];
    logo.layer.cornerRadius = 12;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    logo.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
    [logo.widthAnchor constraintEqualToConstant:42].active = YES;
    [logo.heightAnchor constraintEqualToConstant:42].active = YES;

    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self labelWithText:@"开屏广告走开" size:18 weight:UIFontWeightBold alpha:1.0],
        [self labelWithText:[NSString stringWithFormat:@"%@ · %@", [self hostAppName], enabled ? @"运行中" : @"已暂停"] size:12 weight:UIFontWeightRegular alpha:0.55],
    ]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 2;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    close.layer.cornerRadius = 15;
    [close addTarget:self action:@selector(onPanelClose) forControlEvents:UIControlEventTouchUpInside];
    [close.widthAnchor constraintEqualToConstant:30].active = YES;
    [close.heightAnchor constraintEqualToConstant:30].active = YES;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[logo, titles, close]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;
    [stack addArrangedSubview:header];

    NSInteger count = [[NSUserDefaults standardUserDefaults] integerForKey:kASSkipCountDefaultsKey];
    UILabel *countLabel = [self labelWithText:[NSString stringWithFormat:@"%ld", (long)count] size:28 weight:UIFontWeightHeavy alpha:1.0];
    countLabel.font = [UIFont monospacedDigitSystemFontOfSize:28 weight:UIFontWeightHeavy];
    countLabel.textColor = ASAccentColor();
    [countLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *statTexts = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self labelWithText:@"已为你跳过的广告" size:13 weight:UIFontWeightMedium alpha:0.85],
        [self labelWithText:[self lastSkipDescription] size:12 weight:UIFontWeightRegular alpha:0.5],
    ]];
    NSInteger popupCount = [[NSUserDefaults standardUserDefaults] integerForKey:kASPopupCountDefaultsKey];
    if (popupCount > 0) {
        [statTexts addArrangedSubview:[self labelWithText:[NSString stringWithFormat:@"另关掉 %ld 个弹窗", (long)popupCount] size:12 weight:UIFontWeightRegular alpha:0.5]];
    }
    statTexts.axis = UILayoutConstraintAxisVertical;
    statTexts.spacing = 2;
    UIStackView *stats = [[UIStackView alloc] initWithArrangedSubviews:@[countLabel, statTexts]];
    stats.axis = UILayoutConstraintAxisHorizontal;
    stats.alignment = UIStackViewAlignmentCenter;
    stats.spacing = 14;
    stats.layoutMarginsRelativeArrangement = YES;
    stats.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    stats.backgroundColor = [ASAccentColor() colorWithAlphaComponent:0.10];
    stats.layer.cornerRadius = 16;
    stats.layer.cornerCurve = kCACornerCurveContinuous;
    stats.layer.borderWidth = 0.5;
    stats.layer.borderColor = [ASAccentColor() colorWithAlphaComponent:0.35].CGColor;
    [stack addArrangedSubview:stats];

    UIImageView *switchIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3"]];
    switchIcon.tintColor = ASAccentColor();
    switchIcon.contentMode = UIViewContentModeCenter;
    switchIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [switchIcon.widthAnchor constraintEqualToConstant:24].active = YES;
    UILabel *switchTitle = [self labelWithText:@"功能开关" size:15 weight:UIFontWeightMedium alpha:0.95];
    [switchTitle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [switchTitle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *summary = [self labelWithText:[self switchSummaryText] size:12 weight:UIFontWeightRegular alpha:0.5];
    summary.numberOfLines = 1;
    summary.textAlignment = NSTextAlignmentRight;
    summary.lineBreakMode = NSLineBreakByTruncatingTail;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    chevron.contentMode = UIViewContentModeCenter;
    chevron.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    [chevron.widthAnchor constraintEqualToConstant:18].active = YES;
    chevron.transform = self.switchesExpanded ? CGAffineTransformIdentity : CGAffineTransformMakeRotation(-M_PI_2);
    UIStackView *switchHeaderContent = [[UIStackView alloc] initWithArrangedSubviews:@[switchIcon, switchTitle, summary, chevron]];
    switchHeaderContent.axis = UILayoutConstraintAxisHorizontal;
    switchHeaderContent.alignment = UIStackViewAlignmentCenter;
    switchHeaderContent.spacing = 12;
    switchHeaderContent.userInteractionEnabled = NO;
    switchHeaderContent.translatesAutoresizingMaskIntoConstraints = NO;
    UIControl *switchHeader = [[UIControl alloc] init];
    switchHeader.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    switchHeader.layer.cornerRadius = 16;
    switchHeader.layer.cornerCurve = kCACornerCurveContinuous;
    [switchHeader addTarget:self action:@selector(onSwitchHeaderTap) forControlEvents:UIControlEventTouchUpInside];
    [switchHeader addSubview:switchHeaderContent];
    [NSLayoutConstraint activateConstraints:@[
        [switchHeaderContent.topAnchor constraintEqualToAnchor:switchHeader.topAnchor constant:13],
        [switchHeaderContent.bottomAnchor constraintEqualToAnchor:switchHeader.bottomAnchor constant:-13],
        [switchHeaderContent.leadingAnchor constraintEqualToAnchor:switchHeader.leadingAnchor constant:12],
        [switchHeaderContent.trailingAnchor constraintEqualToAnchor:switchHeader.trailingAnchor constant:-12],
    ]];
    [stack addArrangedSubview:switchHeader];
    [stack setCustomSpacing:8 afterView:switchHeader];

    UIView *switchGroup = [self groupWithRows:@[
        [self switchRowWithTitle:@"在本应用启用" detail:@"关闭后不再自动跳过" symbol:@"power" key:kASEnabledDefaultsKey tag:1],
        [self switchRowWithTitle:@"文字识别" detail:@"截图识别“跳过”文字" symbol:@"text.viewfinder" key:kASOCRDefaultsKey tag:2],
        [self switchRowWithTitle:@"右上角兜底" detail:@"都没找到时点一次右上角" symbol:@"arrow.up.right.circle" key:kASCornerDefaultsKey tag:3],
        [self switchRowWithTitle:@"弹窗清理" detail:@"关掉更新、通知、评分等弹窗" symbol:@"xmark.rectangle" key:kASPopupDefaultsKey tag:6],
        [self switchRowWithTitle:@"全程监听" detail:@"使用中出现的广告和弹窗也处理" symbol:@"eye" key:kASWatchDefaultsKey tag:7],
        [self switchRowWithTitle:@"启动提示" detail:@"启动时显示入口提示" symbol:@"bell" key:kASLaunchToastDefaultsKey tag:4],
        [self switchRowWithTitle:@"三指长按" detail:@"随时三指长按打开设置" symbol:@"hand.raised" key:kASThreeFingerDefaultsKey tag:5],
    ]];
    switchGroup.hidden = !self.switchesExpanded;
    switchGroup.alpha = self.switchesExpanded ? 1 : 0;
    [stack addArrangedSubview:switchGroup];
    self.switchGroup = switchGroup;
    self.switchChevron = chevron;
    self.switchSummary = summary;

    NSUInteger points = self.customPoints.count;
    UILabel *pointsTitle = [self labelWithText:points > 0 ? [NSString stringWithFormat:@"自定义坐标 · %lu 个", (unsigned long)points] : @"自定义坐标 · 未录制"
                                          size:13 weight:UIFontWeightSemibold alpha:0.6];
    [stack addArrangedSubview:pointsTitle];
    [stack setCustomSpacing:8 afterView:pointsTitle];

    BOOL hasPoints = points > 0;
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self actionButtonWithTitle:@"录制" symbol:@"plus.viewfinder" action:@selector(onPanelRecord) enabled:YES destructive:NO],
        [self actionButtonWithTitle:@"查看" symbol:@"eye" action:@selector(onPanelShowMarkers) enabled:hasPoints destructive:NO],
        [self actionButtonWithTitle:@"撤销" symbol:@"arrow.uturn.left" action:@selector(onPanelUndo) enabled:hasPoints destructive:NO],
        [self actionButtonWithTitle:self.clearArmed ? @"确认清除" : @"清除" symbol:@"trash" action:@selector(onPanelClear) enabled:hasPoints destructive:YES],
    ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 8;
    [stack addArrangedSubview:actions];

    UILabel *footer = [self labelWithText:[NSString stringWithFormat:@"v%@ · 设置只对当前应用生效", kASVersion] size:11 weight:UIFontWeightRegular alpha:0.35];
    footer.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:footer];
}

- (NSString *)switchSummaryText {
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"启用", kASEnabledDefaultsKey], @[@"文字识别", kASOCRDefaultsKey], @[@"右上角兜底", kASCornerDefaultsKey],
        @[@"弹窗清理", kASPopupDefaultsKey], @[@"全程监听", kASWatchDefaultsKey], @[@"启动提示", kASLaunchToastDefaultsKey],
        @[@"三指长按", kASThreeFingerDefaultsKey],
    ];
    NSMutableArray<NSString *> *off = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        if (![self boolForKey:item[1]]) [off addObject:item[0]];
    }
    if (off.count == 0) return [NSString stringWithFormat:@"已开 %lu/%lu", (unsigned long)items.count, (unsigned long)items.count];
    return [NSString stringWithFormat:@"已关 %@", [off componentsJoinedByString:@"、"]];
}

- (void)onSwitchHeaderTap {
    UIView *group = self.switchGroup;
    if (!group) return;
    BOOL expand = !self.switchesExpanded;
    self.switchesExpanded = expand;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    UIView *panel = self.panelView;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        group.hidden = !expand;
        group.alpha = expand ? 1 : 0;
        self.switchChevron.transform = expand ? CGAffineTransformIdentity : CGAffineTransformMakeRotation(-M_PI_2);
        [panel layoutIfNeeded];
    } completion:nil];
}

- (void)onPanelSwitch:(UISwitch *)toggle {
    NSArray<NSString *> *keys = @[@"", kASEnabledDefaultsKey, kASOCRDefaultsKey, kASCornerDefaultsKey, kASLaunchToastDefaultsKey, kASThreeFingerDefaultsKey,
                                  kASPopupDefaultsKey, kASWatchDefaultsKey];
    if (toggle.tag <= 0 || toggle.tag >= (NSInteger)keys.count) return;
    NSString *key = keys[toggle.tag];
    UIWindow *host = [self resolveHostWindow:nil];

    if (!toggle.on && (toggle.tag == 4 || toggle.tag == 5)) {
        NSString *otherKey = toggle.tag == 4 ? kASThreeFingerDefaultsKey : kASLaunchToastDefaultsKey;
        if (![self boolForKey:otherKey]) {
            [toggle setOn:YES animated:YES];
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeWarning];
            [self showToast:@"启动提示和三指长按至少保留一个" symbol:@"exclamationmark.triangle.fill" inWindow:host];
            return;
        }
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self setBool:toggle.on forKey:key];
    [self refreshCachedSettings];
    self.switchSummary.text = [self switchSummaryText];
    if (toggle.tag == 5) [self refreshSettingsGestures];
    if (toggle.tag == 1) [self rebuildPanel];
}

- (void)onPanelRecord {
    UIWindow *host = [self resolveHostWindow:nil];
    [self dismissPanelThen:^{
        [self beginPickingInWindow:host];
    }];
}

- (void)onPanelShowMarkers {
    UIWindow *host = [self resolveHostWindow:nil];
    [self dismissPanelThen:^{
        [self showPointMarkersInWindow:host duration:2.5 completion:^{
            [self presentSettingsInWindow:host];
        }];
    }];
}

- (void)onPanelUndo {
    if (self.customPoints.count == 0) return;
    NSUInteger removedNumber = self.customPoints.count;
    [self.customPoints removeLastObject];
    if (self.customSignatures.count > 0) [self.customSignatures removeLastObject];
    [self persistCustomPoints];
    self.clearArmed = NO;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self rebuildPanel];
    [self showToast:[NSString stringWithFormat:@"已删除第 %lu 个坐标", (unsigned long)removedNumber] symbol:@"arrow.uturn.left.circle.fill" inWindow:[self resolveHostWindow:nil]];
}

- (void)onPanelClear {
    if (self.customPoints.count == 0) return;
    if (!self.clearArmed) {
        self.clearArmed = YES;
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        [self rebuildPanel];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!weakSelf.clearArmed) return;
            weakSelf.clearArmed = NO;
            [weakSelf rebuildPanel];
        });
        return;
    }
    self.clearArmed = NO;
    [self.customPoints removeAllObjects];
    [self.customSignatures removeAllObjects];
    [self persistCustomPoints];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self rebuildPanel];
    [self showToast:@"已清除当前应用的坐标" symbol:@"trash.circle.fill" inWindow:[self resolveHostWindow:nil]];
}

#pragma mark 录制坐标

- (void)beginPickingInWindow:(UIWindow *)window {
    UIWindow *host = [self resolveHostWindow:window];
    if (!host || self.pickOverlay) return;
    [self stopSession];
    [self dismissPill:self.toastView];
    [self.markerView removeFromSuperview];
    self.markerView = nil;

    UIView *root = [self hudRootForWindow:host];
    UIView *overlay = [[UIView alloc] initWithFrame:root.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
    [overlay addSubview:[self makeMarkersViewWithFrame:overlay.bounds]];

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.clipsToBounds = YES;
    card.layer.cornerRadius = 20;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    [overlay addSubview:card];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hand.tap.fill"]];
    icon.tintColor = ASAccentColor();
    icon.contentMode = UIViewContentModeCenter;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *title = [self labelWithText:@"轻点要自动点的位置 · 可拖动" size:13 weight:UIFontWeightSemibold alpha:1.0];
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    cancel.tintColor = [UIColor whiteColor];
    cancel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    cancel.layer.cornerRadius = 13;
    [cancel addTarget:self action:@selector(onOverlayCancel) forControlEvents:UIControlEventTouchUpInside];
    [cancel.widthAnchor constraintEqualToConstant:52].active = YES;
    [cancel.heightAnchor constraintEqualToConstant:26].active = YES;
    [cancel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, cancel]];
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 8;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:overlay.widthAnchor constant:-32],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:7],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-7],
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-7],
    ]];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPickPillPan:)];
    [card addGestureRecognizer:drag];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onOverlayTap:)];
    tap.delegate = self;
    [overlay addGestureRecognizer:tap];

    [root addSubview:overlay];
    self.pickOverlay = overlay;
    overlay.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 1;
    }];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer.view != self.pickOverlay) return YES;
    return touch.view == self.pickOverlay;
}

- (void)onOverlayTap:(UITapGestureRecognizer *)tap {
    UIView *overlay = self.pickOverlay;
    UIWindow *hudWindow = overlay.window;
    if (!overlay || !hudWindow) return;
    CGPoint screenPoint = ASScreenPointFromView(overlay, [tap locationInView:overlay]);
    if (!ASIsUsableScreenPoint(screenPoint)) {
        [self showToast:@"坐标无效，请重新点一下" symbol:@"exclamationmark.circle.fill" inWindow:[self resolveHostWindow:nil]];
        return;
    }
    NSDictionary *signature = [self signatureAtScreenPoint:screenPoint];
    while (self.customSignatures.count < self.customPoints.count) [self.customSignatures addObject:@{}];
    [self.customPoints addObject:[NSValue valueWithCGPoint:screenPoint]];
    [self.customSignatures addObject:signature];
    [self persistCustomPoints];
    [overlay removeFromSuperview];
    self.pickOverlay = nil;

    UIWindow *host = [self resolveHostWindow:nil];
    if (host) [self showTapFeedbackAtPoint:ASViewPointFromScreen(host, screenPoint) inWindow:host];
    NSString *captured = signature[@"text"];
    NSString *message = captured.length > 0
        ? [NSString stringWithFormat:@"已保存第 %lu 个 · 认出“%@”", (unsigned long)self.customPoints.count, captured]
        : (signature.count > 0 ? [NSString stringWithFormat:@"已保存第 %lu 个 · 认出按钮", (unsigned long)self.customPoints.count]
                               : [NSString stringWithFormat:@"已保存第 %lu 个 · 仅启动时点", (unsigned long)self.customPoints.count]);
    [self showToast:message inWindow:host];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self presentSettingsInWindow:host];
    });
}

- (void)onPickPillPan:(UIPanGestureRecognizer *)pan {
    UIView *pill = pan.view;
    UIView *container = pill.superview;
    if (!pill || !container) return;
    CGPoint delta = [pan translationInView:container];
    [pan setTranslation:CGPointZero inView:container];
    CGAffineTransform moved = CGAffineTransformTranslate(pill.transform, delta.x, delta.y);
    CGRect base = CGRectOffset(pill.frame, -pill.transform.tx, -pill.transform.ty);
    UIEdgeInsets safe = container.safeAreaInsets;
    CGFloat minX = safe.left + 8 - CGRectGetMinX(base);
    CGFloat maxX = CGRectGetWidth(container.bounds) - safe.right - 8 - CGRectGetMaxX(base);
    CGFloat minY = safe.top + 8 - CGRectGetMinY(base);
    CGFloat maxY = CGRectGetHeight(container.bounds) - safe.bottom - 8 - CGRectGetMaxY(base);
    moved.tx = MAX(minX, MIN(maxX, moved.tx));
    moved.ty = MAX(minY, MIN(maxY, moved.ty));
    pill.transform = moved;
}

- (void)onOverlayCancel {
    UIView *overlay = self.pickOverlay;
    self.pickOverlay = nil;
    [overlay removeFromSuperview];
    UIWindow *host = [self resolveHostWindow:nil];
    [self showToast:@"已取消录制" symbol:@"xmark.circle.fill" inWindow:host];
    [self presentSettingsInWindow:host];
}

@end

#pragma mark - 入口

static void ASInstallUIHooks(void) {
    Method appear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (appear) {
        __block void (*originalAppear)(id, SEL, BOOL) = NULL;
        IMP appearImp = imp_implementationWithBlock(^(UIViewController *controller, BOOL animated) {
            if (originalAppear) originalAppear(controller, @selector(viewDidAppear:), animated);
            if (!gASWatchActive || ![NSThread isMainThread]) return;
            if ([controller isKindOfClass:[SplashAwayHUDController class]]) return;
            UIView *view = controller.viewIfLoaded;
            UIWindow *window = view.window;
            if (!window || [window isKindOfClass:[SplashAwayHUDWindow class]]) return;
            BOOL fresh = ![controller isKindOfClass:[UIAlertController class]];
            [[SplashAwayEngine shared] noteUIChange:view fresh:fresh];
        });
        originalAppear = (void (*)(id, SEL, BOOL))method_setImplementation(appear, appearImp);
    }

    Method add = class_getInstanceMethod([UIView class], @selector(addSubview:));
    if (add) {
        __block void (*originalAdd)(id, SEL, UIView *) = NULL;
        IMP addImp = imp_implementationWithBlock(^(UIView *view, UIView *subview) {
            if (originalAdd) originalAdd(view, @selector(addSubview:), subview);
            if (!gASWatchActive || !subview || ![NSThread isMainThread]) return;
            if ([view isKindOfClass:[UIScrollView class]]) return;
            UIWindow *window = view.window;
            if (!window || [window isKindOfClass:[SplashAwayHUDWindow class]]) return;
            CGSize windowSize = window.bounds.size;
            CGSize parentSize = view.bounds.size;
            if (parentSize.width < windowSize.width * 0.9 || parentSize.height < windowSize.height * 0.85) return;
            CGSize childSize = subview.bounds.size;
            BOOL fresh = childSize.width >= windowSize.width * 0.9 && childSize.height >= windowSize.height * 0.8;
            [[SplashAwayEngine shared] noteUIChange:subview fresh:fresh];
        });
        originalAdd = (void (*)(id, SEL, UIView *))method_setImplementation(add, addImp);
    }
}

static void ASMigrateLegacyDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary<NSString *, id> *all = [defaults dictionaryRepresentation];
    for (NSString *key in all) {
        if (![key hasPrefix:@"AdSkip."]) continue;
        NSString *newKey = [@"SplashAway." stringByAppendingString:[key substringFromIndex:7]];
        if (![defaults objectForKey:newKey]) [defaults setObject:all[key] forKey:newKey];
        [defaults removeObjectForKey:key];
    }
}

%ctor {
    @autoreleasepool {
        if (!ASShouldRunInProcess()) return;
        ASMigrateLegacyDefaults();
        [SplashAwayEngine shared];
        ASInstallUIHooks();
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];

        [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            [[SplashAwayEngine shared] markActivationAndStart];
            [[SplashAwayEngine shared] scheduleLaunchToastAttempt:0];
        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            [[SplashAwayEngine shared] markActivationAndStart];
        }];
        [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[UIWindow class]]) {
                [[SplashAwayEngine shared] handleWindowBecameVisible:note.object];
            }
        }];
    }
}
