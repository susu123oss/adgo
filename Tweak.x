#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

/*
 * 开屏广告走开的核心实现说明
 *
 * 这个文件运行在被注入应用自己的进程中，因此所有工作都必须在主线程
 * 上安全地观察和操作 UIKit 对象。开屏跳过优先使用用户明确保存的节点
 * 特征；启动短窗口内也允许严格识别“跳过”原生文字，但不使用 OCR、
 * 模糊业务词或固定坐标盲点，避免普通页面被误点击。
 *
 * 插件自己的设置面板、提示和坐标标记全部放在独立的 HUD 窗口中。HUD
 * 会被扫描逻辑主动排除，避免插件自己的文字被误识别成“跳过”按钮；
 * 同时 HUD 的根视图默认不拦截触摸，只有面板和录制遮罩中的控件会接收
 * 事件。
 *
 * 用户录制的点会同时保存屏幕坐标和可用的控件特征。后台监听只会在
 * 节点特征匹配后点击，避免固定坐标误触宿主应用的其他按钮。
 */

// 视图树扫描和弹窗扫描都设置节点预算，防止复杂应用的层级过深导致卡顿。
static const NSInteger kASOwnViewTag = 0x0A5C1F;
static const NSTimeInterval kASSessionDuration = 12.0;
static const NSInteger kASScanNodeBudget = 4000;
static char kASGestureInstalledKey;
static NSString *const kASPointsDefaultsKey = @"SplashAway.customPoints";
static NSString *const kASSkipCountDefaultsKey = @"SplashAway.skipCount";
static NSString *const kASLastMethodDefaultsKey = @"SplashAway.lastSkipMethod";
static NSString *const kASLastDateDefaultsKey = @"SplashAway.lastSkipDate";
static NSString *const kASPopupDefaultsKey = @"SplashAway.popupEnabled";
static NSString *const kASWatchDefaultsKey = @"SplashAway.watchEnabled";
static NSString *const kASPopupCountDefaultsKey = @"SplashAway.popupCount";
static const NSTimeInterval kASPopupCooldown = 1.2;
static const NSInteger kASPopupNodeBudget = 2500;
static const NSTimeInterval kASPointWatchInterval = 0.5;
static const NSTimeInterval kASWatchBurstDuration = 6.0;
static const NSTimeInterval kASStartupSkipInitialDelay = 1.0;
static const NSTimeInterval kASStartupSkipInterval = 0.5;
static const NSTimeInterval kASPointCooldown = 4.0;
static const CGFloat kASTemplateMinimumSize = 24.0;
static const CGFloat kASTemplateMaximumFraction = 0.45;
static const CGFloat kASTemplateSearchRadius = 120.0;
static const CGFloat kASTemplateMatchThreshold = 0.58;
static NSString *const kASVersion = @"0.0.5";
// 在线更新只读取 GitHub Tag，不下载或替换当前已经加载的动态库。
static NSString *const kASUpdateCheckDateDefaultsKey = @"SplashAway.updateCheckDate";
static NSString *const kASUpdateLatestTagDefaultsKey = @"SplashAway.updateLatestTag";
static NSString *const kASUpdateTagsURLString = @"https://api.github.com/repos/susu123oss/adgo/tags?per_page=20";
static const NSTimeInterval kASUpdateCheckInterval = 86400.0;

typedef NS_ENUM(NSInteger, ASUpdateStatus) {
    ASUpdateStatusIdle = 0,
    ASUpdateStatusChecking,
    ASUpdateStatusLatest,
    ASUpdateStatusAvailable,
    ASUpdateStatusFailed,
};

// Tag 必须是稳定的三段式版本，例如 v0.0.4；预发布标签不参与比较。
static BOOL ASParseTagVersion(NSString *tag, NSInteger *major, NSInteger *minor, NSInteger *patch) {
    if (tag.length == 0) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" options:0 error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match) return NO;
    if (major) *major = [[tag substringWithRange:[match rangeAtIndex:1]] integerValue];
    if (minor) *minor = [[tag substringWithRange:[match rangeAtIndex:2]] integerValue];
    if (patch) *patch = [[tag substringWithRange:[match rangeAtIndex:3]] integerValue];
    return YES;
}

static NSComparisonResult ASCompareTagVersions(NSString *left, NSString *right) {
    NSInteger leftMajor = 0;
    NSInteger leftMinor = 0;
    NSInteger leftPatch = 0;
    NSInteger rightMajor = 0;
    NSInteger rightMinor = 0;
    NSInteger rightPatch = 0;
    if (!ASParseTagVersion(left, &leftMajor, &leftMinor, &leftPatch)) return NSOrderedAscending;
    if (!ASParseTagVersion(right, &rightMajor, &rightMinor, &rightPatch)) return NSOrderedDescending;
    if (leftMajor != rightMajor) return leftMajor > rightMajor ? NSOrderedDescending : NSOrderedAscending;
    if (leftMinor != rightMinor) return leftMinor > rightMinor ? NSOrderedDescending : NSOrderedAscending;
    if (leftPatch != rightPatch) return leftPatch > rightPatch ? NSOrderedDescending : NSOrderedAscending;
    return NSOrderedSame;
}

// 统一的强调色用于点击反馈、录制标记和自定义设置面板。
static UIColor *ASAccentColor(void) {
    return [UIColor colorWithRed:0.25 green:0.90 blue:0.62 alpha:1.0];
}

#pragma mark - 运行范围

static BOOL ASShouldRunInProcess(void) {
    // 不处理系统应用、扩展或没有正常 App bundle 的进程，降低注入范围
    // 和宿主应用启动阶段发生冲突的概率。
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleId = mainBundle.bundleIdentifier;
    if (bundleId.length == 0) return NO;
    if ([bundleId hasPrefix:@"com.apple."]) return NO;
    if (![mainBundle.bundlePath.pathExtension isEqualToString:@"app"]) return NO;
    return YES;
}

#pragma mark - 文本归一化与判定

static NSString *ASNormalizeText(NSString *raw) {
    // 广告按钮经常包含倒计时、空格或装饰符号。先归一化，再交给后续
    // 的严格/宽松规则判断，可以减少同一按钮的规则重复。
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

static NSArray<NSString *> *ASRetentionPhrases(void);

static BOOL ASIsStartupSkipText(NSString *raw) {
    NSString *text = ASNormalizeText(raw);
    if (text.length == 0 || text.length > 8) return NO;
    if ([ASRetentionPhrases() containsObject:text]) return NO;
    static NSSet<NSString *> *skipWords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skipWords = [NSSet setWithArray:@[
            @"跳过", @"跳过广告", @"跳广告", @"略过",
            @"跳過", @"跳過廣告", @"跳廣告", @"略過",
            @"skip", @"skipad", @"skipads"
        ]];
    });
    return [skipWords containsObject:text];
}

typedef NS_ENUM(NSInteger, ASDismissLevel) {
    ASDismissNone = 0,
    ASDismissWeak = 1,
    ASDismissStrong = 2,
};

static ASDismissLevel ASDismissLevelForText(NSString *raw) {
    // 弹窗按钮按“明确拒绝打扰”“可能关闭”“不可自动处理”分级。
    // 只有前两类在安全条件满足时才会被自动触发。
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
    // 只要弹窗上下文出现支付、删除、退出登录等高风险语义，就放弃
    // 整个弹窗，宁可漏点也不替用户做不可逆操作。
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
    // 这些词用于判断普通关闭按钮是否属于打扰性弹窗，而不是业务页面。
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
    // 非系统 UIAlertController 的弹窗通常有一层覆盖全屏的半透明背景；
    // 通过颜色和透明度特征寻找这层背景，再在其上方收集候选按钮。
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
    // 录制控件特征时，优先把 UIControl 和带点击手势的视图当作可操作节点。
    if ([view isKindOfClass:[UIControl class]]) return ((UIControl *)view).isEnabled;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]] && gesture.isEnabled) return YES;
    }
    return NO;
}

static NSString *ASStringValueFromObject(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSAttributedString class]]) return [value string];
    return nil;
}

static NSString *ASReadViewStringProperty(UIView *view, NSString *propertyName) {
    if (!view || propertyName.length == 0) return nil;
    SEL selector = NSSelectorFromString(propertyName);
    if (![view respondsToSelector:selector]) return nil;
    @try {
        return ASStringValueFromObject([view valueForKey:propertyName]);
    } @catch (__unused NSException *exception) {
        return nil;
    }
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
    // 尽量从常见 UIKit 控件读取文字；对未知类只读取公开的 text/title
    // 相关属性，避免强行调用宿主自定义对象的方法。
    NSString *text = nil;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        text = button.currentTitle ?: button.currentAttributedTitle.string;
    } else if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        text = label.text ?: label.attributedText.string;
    }
    if (text.length == 0) {
        for (NSString *propertyName in @[@"text", @"title", @"string", @"attributedText", @"attributedString"]) {
            text = ASReadViewStringProperty(view, propertyName);
            if (text.length > 0) break;
        }
    }
    if (text.length == 0) text = view.accessibilityLabel;
    if (text.length == 0) text = view.accessibilityValue;
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
    // hitTest 返回的可能是文字标签或装饰子视图。向上最多找三层，
    // 把一次点击归并到更稳定的按钮/容器节点上。
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

static UIView *ASNearestTappableAncestor(UIView *view, UIWindow *window) {
    UIView *current = view;
    for (NSInteger level = 0; level < 6 && current && current != window; level++) {
        if (ASViewIsTappable(current)) return current;
        current = current.superview;
    }
    return nil;
}

static NSString *ASSignatureTextOfView(UIView *anchor, UIWindow *window) {
    // 录制和回放使用同一套文字收集逻辑，避免“录制时能识别、回放时
    // 识别不到”的不一致。
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
    // 文案可能因为倒计时或前后缀变化而略有不同，因此允许包含关系，
    // 但不接受过短的单字符特征。
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
    // iOS 13 以后窗口属于 UIWindowScene；为了兼容旧宿主和部分注入场景，
    // 先枚举前台 scene，枚举不到时再回退到 UIApplication.windows。
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
    // 所有持久化坐标统一保存为屏幕坐标，不保存某个窗口或子视图的局部坐标。
    // 这样可以跨越窗口层级变化，并避免 HUD 窗口导致坐标落到左上角。
    if (!view) return point;
    return [view convertPoint:point toCoordinateSpace:ASScreenSpaceForView(view)];
}

static CGPoint ASViewPointFromScreen(UIView *view, CGPoint screenPoint) {
    // 点击宿主视图前，把持久化的屏幕坐标转换回目标窗口坐标。
    if (!view) return screenPoint;
    return [view convertPoint:screenPoint fromCoordinateSpace:ASScreenSpaceForView(view)];
}

static BOOL ASIsUsableScreenPoint(CGPoint point) {
    // 过滤未初始化的 (0,0)、NaN 和明显越界值，避免把坏坐标直接发送给宿主。
    if (!isfinite(point.x) || !isfinite(point.y)) return NO;
    if (point.x < 1.0 && point.y < 1.0) return NO;
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat side = MAX(bounds.size.width, bounds.size.height);
    return point.x >= 0 && point.y >= 0 && point.x <= side && point.y <= side;
}

static uint8_t *ASRGBABytesForImage(CGImageRef image, size_t *width, size_t *height) {
    if (!image) return NULL;
    size_t imageWidth = CGImageGetWidth(image);
    size_t imageHeight = CGImageGetHeight(image);
    if (imageWidth == 0 || imageHeight == 0) return NULL;
    size_t bytesPerRow = imageWidth * 4;
    uint8_t *bytes = calloc(imageHeight, bytesPerRow);
    if (!bytes) return NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes,
                                                   imageWidth,
                                                   imageHeight,
                                                   8,
                                                   bytesPerRow,
                                                   colorSpace,
                                                   kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(bytes);
        return NULL;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, imageWidth, imageHeight), image);
    CGContextRelease(context);
    if (width) *width = imageWidth;
    if (height) *height = imageHeight;
    return bytes;
}

static BOOL ASImageHasVisiblePixels(UIImage *image) {
    if (!image.CGImage) return NO;
    size_t width = 0;
    size_t height = 0;
    uint8_t *bytes = ASRGBABytesForImage(image.CGImage, &width, &height);
    if (!bytes) return NO;
    BOOL visible = NO;
    size_t total = width * height;
    for (size_t index = 0; index < total; index++) {
        const uint8_t *pixel = bytes + index * 4;
        if (pixel[3] > 3 || pixel[0] > 3 || pixel[1] > 3 || pixel[2] > 3) {
            visible = YES;
            break;
        }
    }
    free(bytes);
    return visible;
}

#pragma mark - 独立 HUD 窗口

@implementation SplashAwayHUDWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // HUD 只显示反馈时不能挡住宿主触摸；只有真正命中的面板、按钮或
    // 录制遮罩子视图才允许接收事件。
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
    // 根视图有内容时显示 HUD 窗口；所有反馈移除后再隐藏窗口，减少
    // 对宿主窗口枚举和后续扫描的干扰。
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
    // HUD 复制宿主顶部控制器的状态栏和旋转策略，避免弹出设置时出现
    // 状态栏样式或横竖屏方向突然变化。
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
    // 有些广告按钮只挂了 UITapGestureRecognizer，没有 UIControl action。
    // 这里读取手势内部 target/action 直接派发，失败时仍会回退到合成触摸。
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
    // 通过运行时查找 IOHIDEvent 符号，避免在编译期增加固定私有库依赖。
    // 符号不可用时调用方会自动回退到 UITouch/touchesBegan 路径。
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
    // 构造一次最小的 UITouch 生命周期：窗口、目标视图、位置、按下阶段
    // 和点击标记。所有私有 selector 都先检查是否可用。
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
    // 优先把触摸交给 UIApplication 的事件分发链，让 WebView、游戏引擎
    // 等不响应普通 sendActions 的目标也有机会收到点击。
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
    // 先尝试系统事件链；事件链不可用或抛异常时，只对目标视图直接发送
    // touchesBegan/touchesEnded，保证失败不会把异常传播到宿主。
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
    // 合成点击必须拆成“按下”和“抬起”两个阶段，并留出一个很短的
    // 主线程间隔，模拟真实触摸的时序。
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
// 会话状态：启动/回前台后只在有限时长内进行高频扫描。
@property (nonatomic, assign) BOOL isMonitoring;
@property (nonatomic, assign) BOOL hasTriggered;
@property (nonatomic, assign) CFAbsoluteTime sessionStart;
@property (nonatomic, assign) CFAbsoluteTime lastActivation;
@property (nonatomic, strong) dispatch_source_t scanTimer;
// 自定义坐标和对应控件特征按相同下标配对保存。
@property (nonatomic, strong) NSMutableArray<NSValue *> *customPoints;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *customSignatures;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *pointLastTap;
@property (nonatomic, strong) NSHashTable<UIView *> *pointTappedViews;
@property (nonatomic, strong) dispatch_source_t pointTimer;
@property (nonatomic, strong) NSHashTable<UIView *> *failedViews;
// 下面这些视图属于插件自己的 UI 或已处理对象，扫描时必须跳过。
@property (nonatomic, strong) UIView *pickOverlay;
@property (nonatomic, strong) UIView *pickDimView;
@property (nonatomic, strong) UIView *pickSelectionBox;
@property (nonatomic, strong) NSMutableArray<UIView *> *pickSelectionHandles;
@property (nonatomic, weak) UIWindow *pickHostWindow;
@property (nonatomic, assign) CGRect pickSelectionRect;
@property (nonatomic, weak) UILabel *pickSizeLabel;
// 节点选择模式使用独立的候选节点数组，避免和截图选框共用临时状态。
@property (nonatomic, weak) UIWindow *nodeHostWindow;
@property (nonatomic, strong) NSMutableArray<UIView *> *nodeCandidateViews;
@property (nonatomic, strong) NSMutableArray<UIButton *> *nodeCandidateButtons;
@property (nonatomic, strong) UIImage *pendingCaptureImage;
@property (nonatomic, assign) CGRect pendingCaptureHostRect;
@property (nonatomic, assign) CGRect pendingCaptureScreenRect;
@property (nonatomic, strong) UIView *markerView;
@property (nonatomic, strong) NSMutableIndexSet *selectedPointIndexes;
@property (nonatomic, strong) NSMutableArray<UIButton *> *pointMarkerButtons;
@property (nonatomic, weak) UILabel *pointSelectionLabel;
@property (nonatomic, weak) UIButton *pointTestButton;
@property (nonatomic, weak) UIButton *pointDeleteButton;
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
@property (nonatomic, assign) CFAbsoluteTime watchBurstDeadline;
// 更新状态保存在引擎中，面板重建时可以稳定恢复显示，不依赖某个旧的 UI 实例。
@property (nonatomic, copy) NSString *latestTagName;
@property (nonatomic, strong) NSURL *latestTagURL;
@property (nonatomic, assign) ASUpdateStatus updateStatus;
@property (nonatomic, assign) BOOL updateCheckInFlight;
@property (nonatomic, weak) UILabel *updateTitleLabel;
@property (nonatomic, weak) UILabel *updateDetailLabel;
+ (instancetype)shared;
- (void)appendTemplateDebugLog:(NSString *)message;
- (void)markActivationAndStart;
- (void)handleWindowBecameVisible:(UIWindow *)window;
- (void)scheduleLaunchToastAttempt:(NSInteger)attempt;
- (void)noteUIChange:(UIView *)root fresh:(BOOL)fresh;
- (void)stopPointWatcher;
- (void)wakeWatchBurstWithDuration:(NSTimeInterval)duration;
- (void)scanStartupSkip;
- (UIView *)findStartupSkipInView:(UIView *)view
                         inWindow:(UIWindow *)window
                            depth:(NSInteger)depth
                           budget:(NSInteger *)budget;
- (void)finishWithFeedbackAtPoint:(CGPoint)point
                         inWindow:(UIWindow *)window
                           method:(NSString *)method;
- (void)checkForUpdatesIfNeeded:(BOOL)force;
- (void)onUpdateRowTap;
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
        // 这是单例引擎的唯一初始化位置；坐标、弱引用表和用户设置都在
        // 主流程开始前准备好，避免首次触发时边扫描边创建状态。
        _customPoints = [NSMutableArray array];
        _customSignatures = [NSMutableArray array];
        _pickSelectionHandles = [NSMutableArray array];
        _nodeCandidateViews = [NSMutableArray array];
        _nodeCandidateButtons = [NSMutableArray array];
        _selectedPointIndexes = [NSMutableIndexSet indexSet];
        _pointMarkerButtons = [NSMutableArray array];
        _pointLastTap = [NSMutableDictionary dictionary];
        _pointTappedViews = [NSHashTable weakObjectsHashTable];
        _failedViews = [NSHashTable weakObjectsHashTable];
        _handledPopups = [NSHashTable weakObjectsHashTable];
        _freshRoots = [NSHashTable weakObjectsHashTable];
        [self loadCustomPoints];
        [self refreshCachedSettings];
        [self loadUpdateCache];
    }
    return self;
}

- (void)refreshCachedSettings {
    // 高频路径读取缓存字段而不是每个 tick 都反复访问 NSUserDefaults；
    // 设置面板修改开关后会再次调用这里立即生效。
    // 插件对当前注入的应用固定启用，不再提供“在本应用启用”开关。
    self.enabledOn = YES;
    self.popupOn = [self boolForKey:kASPopupDefaultsKey];
    self.watchOn = [self boolForKey:kASWatchDefaultsKey];
    gASWatchActive = self.enabledOn && self.watchOn;
    [self updatePointWatcher];
    if (self.watchOn) {
        [self wakeWatchBurstWithDuration:2.0];
    }
}

#pragma mark 在线更新

- (void)loadUpdateCache {
    // 只缓存最近一次识别到的 Tag 和检查时间。缓存过期后仍先显示旧状态，
    // 随后由面板或启动后的延迟任务发起新请求，避免网络抖动时界面空白。
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *cachedTag = [defaults stringForKey:kASUpdateLatestTagDefaultsKey];
    if (ASParseTagVersion(cachedTag, NULL, NULL, NULL)) {
        self.latestTagName = cachedTag;
        self.latestTagURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/susu123oss/adgo/releases/tag/%@", cachedTag]];
        self.updateStatus = ASCompareTagVersions(cachedTag, [@"v" stringByAppendingString:kASVersion]) == NSOrderedDescending
            ? ASUpdateStatusAvailable
            : ASUpdateStatusLatest;
    } else {
        self.updateStatus = ASUpdateStatusIdle;
    }
}

- (NSString *)updateDetailText {
    switch (self.updateStatus) {
        case ASUpdateStatusChecking:
            return @"正在检查 GitHub Tag…";
        case ASUpdateStatusLatest:
            return [NSString stringWithFormat:@"已是最新 v%@ · 点击重新检查", kASVersion];
        case ASUpdateStatusAvailable:
            return [NSString stringWithFormat:@"发现新版本 %@ · 点击查看", self.latestTagName ?: @"新版本"];
        case ASUpdateStatusFailed:
            return @"检查失败 · 点击重试";
        case ASUpdateStatusIdle:
        default:
            return @"点击检查 GitHub Tag";
    }
}

- (void)refreshUpdateLabels {
    // 面板打开期间请求可能异步返回；保留这一层更新方法，避免直接操作
    // 已被重建的旧控件，也让请求结果可以无感地刷新当前行。
    self.updateTitleLabel.text = @"在线更新";
    self.updateDetailLabel.text = [self updateDetailText];
    self.updateDetailLabel.textColor = [UIColor colorWithWhite:1 alpha:self.updateStatus == ASUpdateStatusAvailable ? 0.9 : 0.5];
}

- (void)checkForUpdatesIfNeeded:(BOOL)force {
    if (self.updateCheckInFlight) return;
    // 自动检查更新固定开启；旧版本保存过的关闭值不再影响更新检测。
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *lastCheck = [defaults objectForKey:kASUpdateCheckDateDefaultsKey];
    BOOL cacheFresh = lastCheck && [[NSDate date] timeIntervalSinceDate:lastCheck] < kASUpdateCheckInterval;
    if (!force && cacheFresh && self.latestTagName.length > 0) {
        [self refreshUpdateLabels];
        return;
    }

    NSURL *url = [NSURL URLWithString:kASUpdateTagsURLString];
    if (!url) {
        self.updateStatus = ASUpdateStatusFailed;
        [self refreshUpdateLabels];
        return;
    }
    self.updateCheckInFlight = YES;
    self.updateStatus = ASUpdateStatusChecking;
    [self refreshUpdateLabels];

    // GitHub API 是公开只读接口，不需要用户令牌；明确设置 User-Agent，
    // 也不把宿主应用的 Cookie 或其他认证信息带给更新服务。
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:15.0];
    [request setValue:@"SplashAway-UpdateChecker/1" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SplashAwayEngine *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.updateCheckInFlight = NO;
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kASUpdateCheckDateDefaultsKey];

            NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 || data.length == 0) {
                strongSelf.updateStatus = ASUpdateStatusFailed;
                [strongSelf refreshUpdateLabels];
                return;
            }

            NSError *jsonError = nil;
            id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError || ![payload isKindOfClass:[NSArray class]]) {
                strongSelf.updateStatus = ASUpdateStatusFailed;
                [strongSelf refreshUpdateLabels];
                return;
            }

            NSString *currentTag = [@"v" stringByAppendingString:kASVersion];
            NSString *bestTag = nil;
            for (id item in (NSArray *)payload) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *tag = [(NSDictionary *)item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
                if (!ASParseTagVersion(tag, NULL, NULL, NULL)) continue;
                if (!bestTag || ASCompareTagVersions(tag, bestTag) == NSOrderedDescending) bestTag = tag;
            }
            if (!bestTag) {
                strongSelf.updateStatus = ASUpdateStatusFailed;
                [strongSelf refreshUpdateLabels];
                return;
            }

            strongSelf.latestTagName = bestTag;
            strongSelf.latestTagURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/susu123oss/adgo/releases/tag/%@", bestTag]];
            [[NSUserDefaults standardUserDefaults] setObject:bestTag forKey:kASUpdateLatestTagDefaultsKey];
            strongSelf.updateStatus = ASCompareTagVersions(bestTag, currentTag) == NSOrderedDescending
                ? ASUpdateStatusAvailable
                : ASUpdateStatusLatest;
            [strongSelf refreshUpdateLabels];
        });
    }];
    [task resume];
}

- (void)onUpdateRowTap {
    if (self.updateStatus == ASUpdateStatusAvailable && self.latestTagURL) {
        // 只打开发布页，不在宿主进程内下载、解压或替换 dylib。
        [[UIApplication sharedApplication] openURL:self.latestTagURL options:@{} completionHandler:nil];
        return;
    }
    [self checkForUpdatesIfNeeded:YES];
}

#pragma mark 坐标持久化

- (NSString *)legacyCustomPointsFilePath {
    // 早期版本把坐标放在 Caches/AdSkip 下。这里仅用于一次性迁移，
    // 新数据统一写入 NSUserDefaults，避免系统清理缓存导致配置丢失。
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [[cacheDir stringByAppendingPathComponent:@"AdSkip"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleId]];
}

- (void)loadCustomPoints {
    // 兼容两种存储格式：旧版本的 CGPoint 字符串，以及带 point/签名
    // 字段的新字典。读取时同时过滤非法坐标，防止历史坏数据再次触发。
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
    // 坐标和签名必须保持下标对齐；没有可靠签名的点只存字符串，
    // 让旧坐标继续作为启动阶段的盲点使用。
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

- (NSString *)templateDirectoryPath {
    NSString *applicationSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    return [applicationSupport stringByAppendingPathComponent:@"SplashAway/templates"];
}

- (NSString *)templateLogPath {
    NSString *applicationSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    if (applicationSupport.length == 0) return nil;
    return [applicationSupport stringByAppendingPathComponent:@"SplashAway/matcher.log"];
}

- (void)appendTemplateDebugLog:(NSString *)message {
    if (message.length == 0) return;
    NSString *applicationSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    if (applicationSupport.length == 0) return;
    NSString *directory = [applicationSupport stringByAppendingPathComponent:@"SplashAway"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *path = [self templateLogPath];
    if (path.length == 0) return;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes fileSize];
    if (size > 256 * 1024) {
        NSString *header = [NSString stringWithFormat:@"[%@] 日志超过 256 KB，已重新开始\n",
                            [NSDate date]];
        [header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        [handle closeFile];
    }
}

- (NSString *)templatePathForFileName:(NSString *)fileName {
    if (![fileName isKindOfClass:[NSString class]] || fileName.length == 0) return nil;
    NSString *directory = [self templateDirectoryPath];
    if (directory.length == 0) return nil;
    return [directory stringByAppendingPathComponent:fileName.lastPathComponent];
}

- (BOOL)templateFileExistsForSignature:(NSDictionary *)signature {
    NSString *path = [self templatePathForFileName:signature[@"templateFile"]];
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (void)removeTemplateForSignature:(NSDictionary *)signature {
    NSString *fileName = signature[@"templateFile"];
    NSString *path = [self templatePathForFileName:fileName];
    if (path.length > 0) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

#pragma mark 坐标随时匹配

- (BOOL)hasSignedPoints {
    for (NSDictionary *signature in self.customSignatures) {
        if (signature.count > 0) return YES;
    }
    return NO;
}

- (NSDictionary *)signatureAtScreenPoint:(CGPoint)screenPoint {
    // 录制时从当前命中的宿主视图提取稳定特征：类名、尺寸和短文本。
    // 这些信息只用于确认“这里还是同一个按钮”，不会改变宿主视图。
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

- (NSDictionary *)signatureForNode:(UIView *)node inWindow:(UIWindow *)window {
    // 节点录制直接使用用户点选的候选视图，避免再次通过 HUD 的坐标
    // hitTest 反推目标；保存的坐标只作为节点搜索的距离参考。
    if (!node || !window || node == window) return @{};
    UIView *tappableAncestor = ASNearestTappableAncestor(node, window);
    UIView *signatureNode = tappableAncestor ?: node;
    CGRect rect = [signatureNode convertRect:signatureNode.bounds toView:window];
    if (CGRectIsEmpty(rect)) return @{};

    NSMutableDictionary *signature = [NSMutableDictionary dictionary];
    signature[@"type"] = @"viewNode";
    signature[@"cls"] = NSStringFromClass([signatureNode class]) ?: @"";
    signature[@"size"] = NSStringFromCGSize(rect.size);
    NSString *text = ASTextOfView(node);
    if (text.length == 0) text = ASSignatureTextOfView(signatureNode, window);
    if (text.length > 0) signature[@"text"] = text;
    NSString *accessibility = signatureNode.accessibilityIdentifier.length > 0
        ? signatureNode.accessibilityIdentifier : node.accessibilityIdentifier;
    if (accessibility.length > 0) {
        signature[@"accessibility"] = accessibility;
    }
    if (signatureNode != node) {
        signature[@"sourceClass"] = NSStringFromClass([node class]) ?: @"";
        NSString *sourceText = ASTextOfView(node);
        if (sourceText.length > 0) signature[@"sourceText"] = sourceText;
    }
    return signature;
}

- (void)collectNodeCandidatesFromView:(UIView *)view
                            inWindow:(UIWindow *)window
                               depth:(NSInteger)depth
                              budget:(NSInteger *)budget
                             results:(NSMutableArray<UIView *> *)results {
    // 只收集有文字、可点击控件或点击手势的节点；普通布局容器不显示
    // 绿色框，避免候选数量过多。子视图仍继续遍历，以便找到真正的按钮。
    if (!view || !window || depth > 32 || !budget || *budget <= 0) return;
    (*budget)--;
    if (view.isHidden || view.alpha < 0.05 || view.tag == kASOwnViewTag) return;

    CGRect rect = (view == window) ? window.bounds : [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(rect) || !CGRectIntersectsRect(rect, window.bounds)) return;

    BOOL tappable = view != window && ASViewIsTappable(view);
    NSString *directText = ASTextOfView(view);
    UIView *candidate = view;
    if (directText.length > 0 && !tappable) {
        // 文字通常挂在按钮内部；如果父级有点击能力，框选父级比只框
        // UILabel 更准确。没有可点击父级时仍保留文字节点作为可点击候选。
        UIView *parent = view.superview;
        for (NSInteger level = 0; level < 6 && parent && parent != window; level++) {
            if (ASViewIsTappable(parent)) {
                candidate = parent;
                break;
            }
            parent = parent.superview;
        }
    }

    if (candidate != window && ![results containsObject:candidate]) {
        CGRect candidateRect = [candidate convertRect:candidate.bounds toView:window];
        CGSize windowSize = window.bounds.size;
        BOOL reasonableSize = candidateRect.size.width >= 12.0 &&
            candidateRect.size.height >= 12.0 &&
            candidateRect.size.width <= windowSize.width * 0.72 &&
            candidateRect.size.height <= windowSize.height * 0.22;
        NSString *candidateDirectText = ASTextOfView(candidate);
        BOOL useful = ASViewIsTappable(candidate) || candidateDirectText.length > 0 ||
            candidate.accessibilityLabel.length > 0;
        BOOL genericButMeaningful = ASViewIsTappable(candidate) ||
            candidateDirectText.length > 0 ||
            candidate.accessibilityLabel.length > 0;
        if (reasonableSize && useful && (!ASIsGenericViewClass(candidate) || genericButMeaningful)) {
            [results addObject:candidate];
        }
    }

    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        [self collectNodeCandidatesFromView:subview
                                   inWindow:window
                                      depth:depth + 1
                                     budget:budget
                                    results:results];
        if (results.count >= 80) break;
    }
}

- (void)stopPointWatcher {
    if (self.pointTimer) {
        [self appendTemplateDebugLog:@"全程监听定时器停止"];
        dispatch_source_cancel(self.pointTimer);
        self.pointTimer = nil;
    }
    self.watchBurstDeadline = 0;
}

- (void)wakeWatchBurstWithDuration:(NSTimeInterval)duration {
    // 事件驱动短时唤醒：平时保持休眠零消耗，仅在出现新窗口、新页面或
    // 全屏遮罩等界面变动事件时唤醒约 6 秒进行集中检测，超时自动停用。
    if (!self.enabledOn || !self.watchOn || self.pickOverlay || self.panelView) return;
    if (self.customPoints.count == 0 && !self.popupOn) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime newDeadline = now + duration;
    if (newDeadline > self.watchBurstDeadline) {
        self.watchBurstDeadline = newDeadline;
    }
    if (self.pointTimer) return;

    self.pointTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    [self appendTemplateDebugLog:[NSString stringWithFormat:@"全程监听唤醒 duration=%.1f", duration]];
    dispatch_source_set_timer(self.pointTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                              (uint64_t)(kASPointWatchInterval * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.pointTimer, ^{
        [weakSelf watchTick];
    });
    dispatch_resume(self.pointTimer);
}

- (void)watchTick {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!self.enabledOn || !self.watchOn || self.pickOverlay || self.panelView || now >= self.watchBurstDeadline) {
        [self stopPointWatcher];
        return;
    }
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || app.applicationState != UIApplicationStateActive) {
        [self stopPointWatcher];
        return;
    }
    NSArray<UIWindow *> *windows = ASVisibleWindows();
    if (windows.count == 0) return;

    if (self.popupOn) [self dismissPopupsInWindows:windows];

    [self watchSignedPoints];
}

- (void)updatePointWatcher {
    // 监听开关关闭或所有点被清除时立即停止定时器进入深度休眠；
    // 开启状态下由界面变动事件（noteUIChange）按需唤醒，不再无脑空转。
    BOOL want = self.enabledOn && self.watchOn && (self.customPoints.count > 0 || self.popupOn);
    if (!want) {
        [self stopPointWatcher];
    }
}

- (BOOL)view:(UIView *)anchor inWindow:(UIWindow *)window matchesSignature:(NSDictionary *)signature {
    // 文本签名优先级高于类名和尺寸；没有文本时才要求类名一致，
    // 并允许尺寸有小幅变化以适应不同字体和布局。
    NSString *recordedAccessibility = [signature[@"accessibility"] isKindOfClass:[NSString class]]
        ? signature[@"accessibility"] : @"";
    if (recordedAccessibility.length > 0 &&
        ![recordedAccessibility isEqualToString:anchor.accessibilityIdentifier ?: @""]) {
        return NO;
    }
    NSString *recordedText = [signature[@"text"] isKindOfClass:[NSString class]] ? signature[@"text"] : @"";
    if (recordedText.length > 0) {
        return ASSignatureTextMatches(recordedText, ASSignatureTextOfView(anchor, window));
    }
    NSString *recordedClass = [signature[@"cls"] isKindOfClass:[NSString class]] ? signature[@"cls"] : @"";
    if (recordedClass.length == 0 || ![recordedClass isEqualToString:NSStringFromClass([anchor class])]) return NO;
    if (ASIsGenericViewClass(anchor) &&
        ![signature[@"type"] isEqualToString:@"viewNode"]) return NO;
    if ([signature[@"size"] isKindOfClass:[NSString class]]) {
        CGSize recordedSize = CGSizeFromString(signature[@"size"]);
        CGSize size = [anchor convertRect:anchor.bounds toView:window].size;
        if (fabs(size.width - recordedSize.width) > MAX(8, recordedSize.width * 0.2) ||
            fabs(size.height - recordedSize.height) > MAX(8, recordedSize.height * 0.2)) return NO;
    }
    return YES;
}

- (UIView *)findNodeMatchingSignature:(NSDictionary *)signature
                             inWindow:(UIWindow *)window
                      nearScreenPoint:(CGPoint)screenPoint {
    // 节点模式不再只检查录制坐标下的 hitTest，而是遍历当前视图树，
    // 从所有匹配签名的节点中选择距离录制位置最近的一个。
    if (!signature.count || !window) return nil;
    CGPoint referencePoint = ASViewPointFromScreen(window, screenPoint);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    NSInteger budget = kASScanNodeBudget;

    while (stack.count > 0 && budget-- > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (!view || view.isHidden || view.alpha < 0.05 || view.tag == kASOwnViewTag) continue;

        CGRect rect = (view == window) ? window.bounds : [view convertRect:view.bounds toView:window];
        if (CGRectIsEmpty(rect) || !CGRectIntersectsRect(rect, window.bounds)) continue;
        if (view != window && [self view:view inWindow:window matchesSignature:signature]) {
            CGSize windowSize = window.bounds.size;
            BOOL reasonableSize = rect.size.width >= 12.0 &&
                rect.size.height >= 12.0 &&
                rect.size.width <= windowSize.width * 0.9 &&
                rect.size.height <= windowSize.height * 0.32;
            if (reasonableSize) {
                CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
                CGFloat distance = hypot(center.x - referencePoint.x, center.y - referencePoint.y);
                NSString *recordedText = [signature[@"text"] isKindOfClass:[NSString class]]
                    ? signature[@"text"] : @"";
                NSString *currentText = ASSignatureTextOfView(view, window);
                NSString *recordedClass = [signature[@"cls"] isKindOfClass:[NSString class]]
                    ? signature[@"cls"] : @"";
                CGFloat score = 0;
                if (recordedClass.length > 0 &&
                    [recordedClass isEqualToString:NSStringFromClass([view class])]) {
                    score += 250.0;
                }
                if (recordedText.length > 0 && currentText.length > 0) {
                    if ([recordedText isEqualToString:currentText]) {
                        score += 450.0;
                    } else {
                        score += 250.0;
                    }
                }
                if (ASViewIsTappable(view)) score += 180.0;
                score -= MIN(distance, 800.0) * 0.45;
                if (score > bestScore) {
                    bestScore = score;
                    best = view;
                }
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return best;
}

- (UIImage *)snapshotForHostWindow:(UIWindow *)window {
    if (!window || window.bounds.size.width <= 0 || window.bounds.size.height <= 0) return nil;
    UIView *contentView = window.rootViewController.view ?: window;
    CGRect contentBounds = contentView.bounds;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:contentBounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [contentView drawViewHierarchyInRect:contentBounds afterScreenUpdates:NO];
    }];
    if (ASImageHasVisiblePixels(image)) return image;

    // 部分 Metal/WebView 页面无法通过 drawViewHierarchyInRect 绘制，
    // 发现结果全透明时再使用图层渲染作为备用路径。
    format.opaque = YES;
    UIGraphicsImageRenderer *fallbackRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:contentBounds.size format:format];
    return [fallbackRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [contentView.layer renderInContext:context.CGContext];
    }];
}

- (NSValue *)matchTemplateImage:(UIImage *)templateImage
                       fileName:(NSString *)fileName
                    screenPoint:(CGPoint)screenPoint
                         window:(UIWindow *)window
                       snapshot:(UIImage *)snapshot
                       outScore:(CGFloat *)outScore {
    CGImageRef templateCGImage = templateImage.CGImage;
    CGImageRef snapshotCGImage = snapshot.CGImage;
    [self appendTemplateDebugLog:[NSString stringWithFormat:
        @"开始找图 file=%@ templateImage=%@ snapshotImage=%@ screenPoint=%@ windowBounds=%@ windowScale=%.2f",
        fileName ?: @"(nil)",
        templateImage ? @"YES" : @"NO",
        snapshot ? @"YES" : @"NO",
        NSStringFromCGPoint(screenPoint),
        NSStringFromCGRect(window.bounds),
        window.screen.scale]];
    if (!templateCGImage || !snapshotCGImage) {
        [self appendTemplateDebugLog:[NSString stringWithFormat:
            @"找图提前失败 templateCGImage=%@ snapshotCGImage=%@",
            templateCGImage ? @"YES" : @"NO",
            snapshotCGImage ? @"YES" : @"NO"]];
        if (outScore) *outScore = -1.0;
        return nil;
    }

    size_t templateWidth = 0;
    size_t templateHeight = 0;
    size_t snapshotWidth = 0;
    size_t snapshotHeight = 0;
    uint8_t *templateBytes = ASRGBABytesForImage(templateCGImage, &templateWidth, &templateHeight);
    uint8_t *snapshotBytes = ASRGBABytesForImage(snapshotCGImage, &snapshotWidth, &snapshotHeight);
    [self appendTemplateDebugLog:[NSString stringWithFormat:
        @"找图图片尺寸 templatePixels=%zux%zu templateScale=%.2f snapshotPixels=%zux%zu snapshotScale=%.2f anchor=%@",
        templateWidth,
        templateHeight,
        templateImage.scale,
        snapshotWidth,
        snapshotHeight,
        snapshot.scale,
        NSStringFromCGPoint(ASViewPointFromScreen(window, screenPoint))]];
    if (!templateBytes || !snapshotBytes) {
        if (templateBytes) free(templateBytes);
        if (snapshotBytes) free(snapshotBytes);
        if (outScore) *outScore = -1.0;
        return nil;
    }

    size_t N = templateWidth * templateHeight;
    if (N < 16) {
        free(templateBytes);
        free(snapshotBytes);
        if (outScore) *outScore = -1.0;
        return nil;
    }

    // 1. 预计算模板灰度与 OpenCV TM_CCOEFF_NORMED 零均值特征
    double *zeroMeanTemplate = (double *)malloc(N * sizeof(double));
    if (!zeroMeanTemplate) {
        free(templateBytes);
        free(snapshotBytes);
        if (outScore) *outScore = -1.0;
        return nil;
    }

    double templateSum = 0.0;
    double templateSqSum = 0.0;
    for (size_t i = 0; i < N; i++) {
        size_t off = i * 4;
        double g = 0.299 * templateBytes[off] +
                   0.587 * templateBytes[off + 1] +
                   0.114 * templateBytes[off + 2];
        zeroMeanTemplate[i] = g;
        templateSum += g;
        templateSqSum += g * g;
    }
    double templateMean = templateSum / (double)N;
    double templateVar = templateSqSum - (templateSum * templateSum) / (double)N;
    if (templateVar <= 1e-4) {
        // 模板为纯单色/无方差，无法计算互相关系数
        free(zeroMeanTemplate);
        free(templateBytes);
        free(snapshotBytes);
        if (outScore) *outScore = -1.0;
        return nil;
    }
    double templateStd = sqrt(templateVar);

    // 转换为零均值模板 T' = T - mean(T)，使后续点积直接得出协方差分子
    for (size_t i = 0; i < N; i++) {
        zeroMeanTemplate[i] -= templateMean;
    }

    // 2. 划定搜索区域（以录制锚点为中心，半径 ±kASTemplateSearchRadius 范围）
    CGPoint anchor = ASViewPointFromScreen(window, screenPoint);
    NSInteger halfWidth = (NSInteger)templateWidth / 2;
    NSInteger halfHeight = (NSInteger)templateHeight / 2;
    NSInteger centerX = (NSInteger)lround(anchor.x);
    NSInteger centerY = (NSInteger)lround(anchor.y);
    NSInteger radius = (NSInteger)kASTemplateSearchRadius;

    NSInteger tW = (NSInteger)templateWidth;
    NSInteger tH = (NSInteger)templateHeight;

    // 模板左上角搜索范围 [minX, maxX] x [minY, maxY]
    NSInteger minX = MAX((NSInteger)0, centerX - radius - halfWidth);
    NSInteger maxX = MIN((NSInteger)snapshotWidth - tW, centerX + radius - halfWidth);
    NSInteger minY = MAX((NSInteger)0, centerY - radius - halfHeight);
    NSInteger maxY = MIN((NSInteger)snapshotHeight - tH, centerY + radius - halfHeight);

    if (minX > maxX || minY > maxY) {
        free(zeroMeanTemplate);
        free(templateBytes);
        free(snapshotBytes);
        if (outScore) *outScore = -1.0;
        return nil;
    }

    // 提取搜索所需的局部宿主 ROI 区域，构建积分图与平方和积分图
    NSInteger roiX = minX;
    NSInteger roiY = minY;
    NSInteger roiW = maxX + tW - roiX;
    NSInteger roiH = maxY + tH - roiY;

    double *roiGray = (double *)malloc((size_t)roiW * (size_t)roiH * sizeof(double));
    size_t iiStride = (size_t)(roiW + 1);
    double *iiSum = (double *)calloc((size_t)(roiH + 1) * iiStride, sizeof(double));
    double *iiSq = (double *)calloc((size_t)(roiH + 1) * iiStride, sizeof(double));

    if (!roiGray || !iiSum || !iiSq) {
        if (roiGray) free(roiGray);
        if (iiSum) free(iiSum);
        if (iiSq) free(iiSq);
        free(zeroMeanTemplate);
        free(templateBytes);
        free(snapshotBytes);
        if (outScore) *outScore = -1.0;
        return nil;
    }

    // 一次性生成 ROI 灰度图并动态构建积分图与平方和积分图
    for (NSInteger ry = 0; ry < roiH; ry++) {
        double rowSum = 0.0;
        double rowSq = 0.0;
        size_t snapRowOff = ((size_t)(roiY + ry) * snapshotWidth + (size_t)roiX) * 4;
        size_t roiRowOff = (size_t)ry * (size_t)roiW;
        const double *prevSum = &iiSum[(size_t)ry * iiStride];
        const double *prevSq = &iiSq[(size_t)ry * iiStride];
        double *currSum = &iiSum[(size_t)(ry + 1) * iiStride];
        double *currSq = &iiSq[(size_t)(ry + 1) * iiStride];

        for (NSInteger rx = 0; rx < roiW; rx++) {
            size_t sOff = snapRowOff + (size_t)rx * 4;
            double g = 0.299 * snapshotBytes[sOff] +
                       0.587 * snapshotBytes[sOff + 1] +
                       0.114 * snapshotBytes[sOff + 2];
            roiGray[roiRowOff + (size_t)rx] = g;

            rowSum += g;
            rowSq += g * g;
            currSum[rx + 1] = prevSum[rx + 1] + rowSum;
            currSq[rx + 1] = prevSq[rx + 1] + rowSq;
        }
    }

    // 3. 逐像素步长=1 密集滑动窗口计算标准 OpenCV TM_CCOEFF_NORMED
    double bestScore = -1.0;
    NSInteger bestTopLeftX = 0;
    NSInteger bestTopLeftY = 0;

    for (NSInteger y = minY; y <= maxY; y++) {
        NSInteger localY = y - roiY;
        size_t y1 = (size_t)localY;
        size_t y2 = (size_t)(localY + tH);
        const double *iiSumTop = &iiSum[y1 * iiStride];
        const double *iiSumBottom = &iiSum[y2 * iiStride];
        const double *iiSqTop = &iiSq[y1 * iiStride];
        const double *iiSqBottom = &iiSq[y2 * iiStride];

        for (NSInteger x = minX; x <= maxX; x++) {
            NSInteger localX = x - roiX;
            size_t x1 = (size_t)localX;
            size_t x2 = (size_t)(localX + tW);

            // O(1) 瞬时获取当前滑动窗口的和与平方和
            double winSum = (iiSumBottom[x2] - iiSumBottom[x1]) - (iiSumTop[x2] - iiSumTop[x1]);
            double winSq = (iiSqBottom[x2] - iiSqBottom[x1]) - (iiSqTop[x2] - iiSqTop[x1]);

            // 窗口方差 Sum((I - mean(I))^2) = winSq - (winSum^2) / N
            double winVar = winSq - (winSum * winSum) / (double)N;
            if (winVar <= 1e-4) {
                // 该窗口为纯色或对比度过低，相关系数无意义直接跳过
                continue;
            }
            double winStd = sqrt(winVar);

            // 协方差分子 Cov(T, I) = Sum( T'(r, c) * I(r, c) )
            // 由于 Sum(T') = 0，展开后 Sum(T' * (I - mean(I))) == Sum(T' * I)
            double cov = 0.0;
            for (NSInteger r = 0; r < tH; r++) {
                const double *tRow = &zeroMeanTemplate[(size_t)r * (size_t)tW];
                const double *iRow = &roiGray[((size_t)localY + (size_t)r) * (size_t)roiW + (size_t)localX];
                for (NSInteger c = 0; c < tW; c++) {
                    cov += tRow[c] * iRow[c];
                }
            }

            // 归一化互相关系数 R = Cov(T, I) / (std(T) * std(I))
            double score = cov / (templateStd * winStd);
            if (score > 1.0) score = 1.0;
            else if (score < -1.0) score = -1.0;

            if (score > bestScore) {
                bestScore = score;
                bestTopLeftX = x;
                bestTopLeftY = y;
            }
        }
    }

    free(roiGray);
    free(iiSum);
    free(iiSq);
    free(zeroMeanTemplate);
    free(templateBytes);
    free(snapshotBytes);

    if (outScore) *outScore = (CGFloat)bestScore;

    CGPoint bestCenter = CGPointMake((CGFloat)bestTopLeftX + (CGFloat)halfWidth,
                                     (CGFloat)bestTopLeftY + (CGFloat)halfHeight);

    [self appendTemplateDebugLog:[NSString stringWithFormat:
        @"OpenCV找图完成 bestScore=%.4f threshold=%.4f bestCenter=%@ searchCenter=(%ld,%ld) radius=%ld result=%@",
        bestScore,
        kASTemplateMatchThreshold,
        NSStringFromCGPoint(bestCenter),
        (long)centerX,
        (long)centerY,
        (long)radius,
        bestScore >= kASTemplateMatchThreshold ? @"MATCH" : @"NO_MATCH"]];

    if (bestScore < kASTemplateMatchThreshold) return nil;
    return [NSValue valueWithCGPoint:bestCenter];
}

- (NSValue *)templateMatchForSignature:(NSDictionary *)signature
                           screenPoint:(CGPoint)screenPoint
                                window:(UIWindow *)window
                              snapshot:(UIImage *)snapshot {
    NSString *fileName = signature[@"templateFile"];
    NSString *path = [self templatePathForFileName:fileName];
    UIImage *templateImage = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    return [self matchTemplateImage:templateImage
                           fileName:fileName
                        screenPoint:screenPoint
                             window:window
                           snapshot:snapshot
                           outScore:NULL];
}

- (void)watchSignedPoints {
    // 全程监听只检查用户明确保存的视图节点。
    // 截图模板保留给手动测试，不参与自动开屏跳过，避免任何图像或坐标兜底误触。
    // 必须同时满足：应用活跃、面板未打开、冷却已结束。
    if (!self.enabledOn || self.pickOverlay || self.panelView) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || app.applicationState != UIApplicationStateActive) return;
    NSArray<UIWindow *> *windows = ASVisibleWindows();
    if (windows.count == 0) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSArray<NSValue *> *points = [self.customPoints copy];
    NSArray<NSDictionary *> *signatures = [self.customSignatures copy];
    for (NSUInteger index = 0; index < points.count; index++) {
        NSDictionary *signature = index < signatures.count ? signatures[index] : @{};
        if (signature.count == 0) continue;
        NSNumber *last = self.pointLastTap[@(index)];
        if (last && now - last.doubleValue < kASPointCooldown) continue;
        CGPoint screenPoint = points[index].CGPointValue;

        if ([signature[@"templateFile"] isKindOfClass:[NSString class]]) {
            [self appendTemplateDebugLog:[NSString stringWithFormat:
                                          @"监听跳过截图模板 index=%lu 原因=自动模式仅使用视图节点",
                                          (unsigned long)index]];
            continue;
        }

        // 节点特征匹配：优先在当前视图树中寻找节点，不再要求
        // 节点必须恰好位于录制时的固定坐标。
        BOOL nodeFound = NO;
        for (UIWindow *window in windows) {
            if (signature.count > 0) {
                UIView *anchor = [self findNodeMatchingSignature:signature
                                                        inWindow:window
                                                 nearScreenPoint:screenPoint];
                if (!anchor) continue;
                nodeFound = YES;
                if ([self.pointTappedViews containsObject:anchor]) {
                    [self appendTemplateDebugLog:[NSString stringWithFormat:
                                                  @"监听节点跳过 index=%lu 原因=节点已成功处理 class=%@",
                                                  (unsigned long)index, NSStringFromClass([anchor class])]];
                    continue;
                }
                if (![self view:anchor inWindow:window matchesSignature:signature]) continue;
                CGRect rect = [anchor convertRect:anchor.bounds toView:window];
                CGPoint point = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
                NSString *text = ASSignatureTextOfView(anchor, window);
                BOOL directActivated = [self activateView:anchor inWindow:window];
                [self appendTemplateDebugLog:[NSString stringWithFormat:
                                              @"监听节点命中 index=%lu class=%@ text='%@' rect=%@ direct=%d fallback=0 result=%d",
                                              (unsigned long)index,
                                              NSStringFromClass([anchor class]),
                                              text ?: @"",
                                              NSStringFromCGRect(rect),
                                              directActivated,
                                              directActivated]];
                if (directActivated) {
                    self.pointLastTap[@(index)] = @(now);
                    [self.pointTappedViews addObject:anchor];
                    [self recordSkipWithMethod:@"节点匹配"];
                    [self showTapFeedbackAtPoint:point inWindow:window];
                    return;
                }
                [self appendTemplateDebugLog:[NSString stringWithFormat:
                                              @"监听节点点击失败 index=%lu，将在后续监听中重试",
                                              (unsigned long)index]];
                break;
            }
        }
        if (!nodeFound) {
            [self appendTemplateDebugLog:[NSString stringWithFormat:
                                          @"监听节点未匹配 index=%lu class=%@ text='%@' anchor=(%.1f, %.1f)",
                                          (unsigned long)index,
                                          signature[@"cls"] ?: @"",
                                          signature[@"text"] ?: @"",
                                          screenPoint.x,
                                          screenPoint.y]];
        }
    }
}

#pragma mark 会话调度

- (void)markActivationAndStart {
    // 启动和回前台都重置一次短时会话，同时把设置手势装到当前可见窗口。
    self.lastActivation = CFAbsoluteTimeGetCurrent();
    for (UIWindow *window in ASVisibleWindows()) {
        [self installSettingsGestureOnWindow:window];
    }
    [self startSession];
}

- (void)handleWindowBecameVisible:(UIWindow *)window {
    // 新窗口触发节点监听和启动阶段的严格“跳过”文字扫描。
    if ([window isKindOfClass:[SplashAwayHUDWindow class]]) return;
    [self installSettingsGestureOnWindow:window];
    if (!ASIsSystemInputWindow(window)) {
        [self noteUIChange:window fresh:YES];
    }
}

- (UIView *)findStartupSkipInView:(UIView *)view
                         inWindow:(UIWindow *)window
                            depth:(NSInteger)depth
                           budget:(NSInteger *)budget {
    if (!view || !window || depth > 32 || !budget || *budget <= 0) return nil;
    (*budget)--;
    if (view.isHidden || view.alpha < 0.05 || view.tag == kASOwnViewTag) return nil;

    CGRect rect = view == window ? window.bounds : [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(rect) || !CGRectIntersectsRect(rect, window.bounds)) return nil;

    NSString *directText = ASTextOfView(view);
    if (view != window && ASIsStartupSkipText(directText)) {
        UIView *candidate = ASNearestTappableAncestor(view, window) ?: view;
        CGRect candidateRect = [candidate convertRect:candidate.bounds toView:window];
        CGSize windowSize = window.bounds.size;
        BOOL reasonable = candidateRect.size.width >= 12.0 &&
            candidateRect.size.height >= 12.0 &&
            candidateRect.size.width <= windowSize.width * 0.6 &&
            candidateRect.size.height <= MIN(100.0, windowSize.height * 0.25);
        if (reasonable && ![self.failedViews containsObject:candidate]) return candidate;
    }

    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        UIView *candidate = [self findStartupSkipInView:subview
                                               inWindow:window
                                                  depth:depth + 1
                                                 budget:budget];
        if (candidate) return candidate;
    }
    return nil;
}

- (void)scanStartupSkip {
    // 这是启动会话内的严格原生文字扫描，只接受明确的“跳过”语义。
    // 不识别“关闭”、单字母 X 或普通业务里的“跳过推荐”等文案。
    if (!self.isMonitoring || self.hasTriggered || self.pickOverlay || self.panelView) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app || app.applicationState != UIApplicationStateActive) return;

    NSArray<UIWindow *> *windows = ASVisibleWindows();
    if (windows.count == 0) return;
    for (UIWindow *window in windows) {
        NSInteger budget = kASScanNodeBudget;
        UIView *candidate = [self findStartupSkipInView:window
                                               inWindow:window
                                                  depth:0
                                                 budget:&budget];
        if (!candidate) continue;

        CGRect rect = [candidate convertRect:candidate.bounds toView:window];
        CGPoint point = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
        NSString *text = ASSignatureTextOfView(candidate, window);
        BOOL directActivated = [self activateView:candidate inWindow:window];
        BOOL coordinateActivated = NO;
        if (!directActivated) {
            coordinateActivated = [self activateScreenPoint:ASScreenPointFromView(window, point)];
        }
        BOOL activated = directActivated || coordinateActivated;
        [self appendTemplateDebugLog:[NSString stringWithFormat:
                                      @"开屏跳过文字命中 class=%@ text='%@' rect=%@ direct=%d coordinate=%d result=%d",
                                      NSStringFromClass([candidate class]),
                                      text ?: @"",
                                      NSStringFromCGRect(rect),
                                      directActivated,
                                      coordinateActivated,
                                      activated]];
        if (activated) {
            [self finishWithFeedbackAtPoint:point inWindow:window method:@"开屏文字识别"];
            return;
        }
        [self.failedViews addObject:candidate];
        [self appendTemplateDebugLog:@"开屏跳过文字点击失败，将在后续扫描中重试"];
    }
    [self appendTemplateDebugLog:[NSString stringWithFormat:
                                  @"开屏跳过文字未匹配 windows=%lu",
                                  (unsigned long)windows.count]];
}

- (void)startSession {
    // 启动和回前台建立节点监听窗口，同时开启一次有时限的严格“跳过”文字扫描。
    [self stopSession];
    [self stopPointWatcher];
    if (!self.enabledOn) return;
    self.hasTriggered = NO;
    [self.failedViews removeAllObjects];
    [self.pointLastTap removeAllObjects];
    [self.pointTappedViews removeAllObjects];
    self.sessionStart = CFAbsoluteTimeGetCurrent();
    self.isMonitoring = YES;

    [self appendTemplateDebugLog:[NSString stringWithFormat:@"启动节点监听 enabled=%d watchOn=%d customPoints=%lu popupOn=%d",
                                  self.enabledOn, self.watchOn, (unsigned long)self.customPoints.count, self.popupOn]];
    [self.customSignatures enumerateObjectsUsingBlock:^(NSDictionary *signature, NSUInteger index, BOOL *stop) {
        if (signature.count == 0) return;
        [self appendTemplateDebugLog:[NSString stringWithFormat:
                                      @"启动节点配置 index=%lu class=%@ text='%@' accessibility='%@'",
                                      (unsigned long)index,
                                      signature[@"cls"] ?: @"",
                                      signature[@"text"] ?: @"",
                                      signature[@"accessibility"] ?: @""]];
    }];
    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kASStartupSkipInitialDelay * NSEC_PER_SEC)),
                              (uint64_t)(kASStartupSkipInterval * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf scanStartupSkip];
    });
    dispatch_resume(self.scanTimer);
    [self appendTemplateDebugLog:[NSString stringWithFormat:
                                  @"启动跳过文字扫描 initial=%.1f interval=%.1f",
                                  kASStartupSkipInitialDelay,
                                  kASStartupSkipInterval]];
    if (self.watchOn && self.customPoints.count > 0) {
        [self wakeWatchBurstWithDuration:kASSessionDuration];
    }
}

- (void)stopSession {
    // dispatch source 取消后立即置空，下一次会话可以安全创建新的 timer。
    self.isMonitoring = NO;
    if (self.scanTimer) {
        dispatch_source_cancel(self.scanTimer);
        self.scanTimer = nil;
    }
}

#pragma mark 弹窗清理

- (BOOL)dismissPopupsInWindows:(NSArray<UIWindow *> *)windows {
    // 先处理系统 UIAlertController，再处理自绘遮罩弹窗；两类弹窗
    // 共用冷却时间，避免连续动画期间重复点击。
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
    // 系统弹窗只处理普通 Alert，不处理带输入框的弹窗或破坏性 action。
    // action handler 会在 dismiss 完成后调用，尽量保留 UIKit 原本的语义。
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
    // 自绘弹窗没有统一类型，只能通过近似全屏的半透明背景寻找候选根节点。
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
    // 收集弹窗文案和尺寸合适的候选控件；预算与深度限制避免把整个
    // 宿主页面当作弹窗递归扫描。
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
    // 自绘弹窗按“危险词拒绝、打扰词确认、按钮尺寸过滤”的顺序
    // 选择最保守的可点击候选，找不到安全候选时不做任何动作。
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
    // 记录弹窗统计并显示点击反馈；监听模式下稍后重新扫描，以处理
    // “一个弹窗关闭后又露出下一个弹窗”的连续场景。
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
    // 界面变化只负责唤醒节点监听，不再安排通用插屏文字扫描。
    if (!self.enabledOn || !self.watchOn) return;
    [self wakeWatchBurstWithDuration:fresh ? kASSessionDuration : kASWatchBurstDuration];
}

- (void)passiveScan {
    // 保留方法名以兼容已经排队的旧回调，但不再执行任何通用兜底点击。
    self.passiveScanPending = NO;
    [self.freshRoots removeAllObjects];
}

#pragma mark 点击派发

- (BOOL)activateView:(UIView *)view inWindow:(UIWindow *)window {
    // 点击优先级：可用 UIControl action -> UITapGestureRecognizer；
    // 两者都没有时由调用方继续尝试屏幕坐标和合成触摸。
    CGSize windowSize = window.bounds.size;
    UIView *current = view;
    for (NSInteger level = 0; level < 6 && current && current != window; level++) {
        CGRect rect = [current convertRect:current.bounds toView:window];
        BOOL oversized = rect.size.width > windowSize.width * 0.6 ||
            rect.size.height > windowSize.height * 0.3;

        if ((!oversized || [current isKindOfClass:[UIControl class]]) &&
            [current isKindOfClass:[UIControl class]] && ((UIControl *)current).isEnabled) {
            [(UIControl *)current sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if (!oversized) {
            for (UIGestureRecognizer *gesture in current.gestureRecognizers) {
                if ([gesture isKindOfClass:[UITapGestureRecognizer class]] && gesture.isEnabled && ASFireTapGesture(gesture)) {
                    return YES;
                }
            }
        }
        current = current.superview;
    }
    return NO;
}

- (BOOL)activateScreenPoint:(CGPoint)screenPoint {
    // 屏幕坐标点击会重新命中当前最上层窗口，避免使用录制时已经失效
    // 的 UIView 指针；命中插件 HUD 时主动跳过。
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

#pragma mark 偏好与统计

- (BOOL)boolForKey:(NSString *)key {
    // 新安装默认开启所有功能；只有用户明确写入 NO 时才关闭。
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ? [value boolValue] : YES;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
}

- (BOOL)threeFingerEnabled {
    // 三指长按固定开启，始终保留一个不依赖启动提示的设置入口。
    return YES;
}

- (void)recordSkipWithMethod:(NSString *)method {
    // 跳过次数和最近方式按宿主应用自己的 NSUserDefaults 隔离保存。
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:[defaults integerForKey:kASSkipCountDefaultsKey] + 1 forKey:kASSkipCountDefaultsKey];
    [defaults setObject:method ?: @"" forKey:kASLastMethodDefaultsKey];
    [defaults setObject:[NSDate date] forKey:kASLastDateDefaultsKey];
}

- (void)recordPopupWithMethod:(NSString *)method {
    // 弹窗统计与开屏广告统计分开计数，但共用最近一次操作说明。
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:[defaults integerForKey:kASPopupCountDefaultsKey] + 1 forKey:kASPopupCountDefaultsKey];
    [defaults setObject:method ?: @"" forKey:kASLastMethodDefaultsKey];
    [defaults setObject:[NSDate date] forKey:kASLastDateDefaultsKey];
}

- (NSString *)lastSkipDescription {
    // 面板只显示相对时间，避免暴露宿主应用的具体时间信息；
    // 没有记录时使用明确的空状态文案。
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
    NSArray<UIWindow *> *windows = ASVisibleWindows();
    for (UIWindow *candidate in windows) {
        if (candidate.isKeyWindow) return candidate;
    }
    return windows.firstObject;
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
    // 每个宿主 scene 只维护一个 HUD。宿主 scene 变化时重建，避免把
    // 一个 scene 的 UIView 挂到另一个 scene，导致布局和坐标转换异常。
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
    // 所有成功路径最终都汇聚到这里，统一停止当前会话、写入统计并显示
    // 点击反馈，避免不同识别方式产生不一致的状态。
    self.hasTriggered = YES;
    [self stopSession];
    [self stopPointWatcher];
    [self recordSkipWithMethod:method];
    [self appendTemplateDebugLog:[NSString stringWithFormat:@"完成跳过反馈 method='%@' point=(%.1f, %.1f) window=%@",
                                  method ?: @"", point.x, point.y, NSStringFromClass([window class])]];
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
    // 胶囊提示属于非阻塞反馈，不改变宿主窗口的触摸链；只有启动提示
    // 会在创建后额外添加点击手势作为设置入口。
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
    // 坐标标记使用屏幕坐标转换到 HUD 局部坐标，不能直接把宿主窗口
    // 的 bounds 当作 HUD 坐标，否则在安全区或旋转后会发生偏移。
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
        marker.layer.backgroundColor = UIColor.clearColor.CGColor;
        marker.layer.cornerRadius = 13;
        marker.layer.borderColor = [UIColor whiteColor].CGColor;
        marker.layer.borderWidth = 1.5;
        marker.layer.shadowColor = [UIColor blackColor].CGColor;
        marker.layer.shadowOpacity = 0.35;
        marker.layer.shadowRadius = 4;
        marker.layer.shadowOffset = CGSizeMake(0, 1);
        [container addSubview:marker];

        BOOL placeOnRight = point.x <= CGRectGetMidX(container.bounds);
        if (point.x < 38.0) placeOnRight = YES;
        if (point.x > CGRectGetWidth(container.bounds) - 38.0) placeOnRight = NO;
        BOOL isTemplate = index < self.customSignatures.count &&
            [self.customSignatures[index][@"templateFile"] isKindOfClass:[NSString class]];
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(point.x + (placeOnRight ? 8.0 : -26.0),
                                                                     point.y < 30.0 ? point.y + 8.0 : point.y - 26.0,
                                                                     18.0,
                                                                     18.0)];
        badge.text = isTemplate ? @"图" : @"点";
        badge.textAlignment = NSTextAlignmentCenter;
        badge.textColor = UIColor.whiteColor;
        badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        badge.backgroundColor = isTemplate
            ? [UIColor colorWithRed:0.25 green:0.48 blue:1.0 alpha:0.96]
            : [UIColor colorWithRed:1.0 green:0.55 blue:0.10 alpha:0.96];
        badge.layer.cornerRadius = 9.0;
        badge.clipsToBounds = YES;
        badge.layer.borderWidth = 1.0;
        badge.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        badge.userInteractionEnabled = NO;
        [container addSubview:badge];
    }];
    return container;
}

- (void)showPointMarkersInWindow:(UIWindow *)window duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    // “查看”只显示短暂的只读标记；标记视图不接收触摸，避免用户
    // 误以为查看状态会改变坐标。
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

- (void)refreshPointEditorUI {
    NSUInteger selectedCount = self.selectedPointIndexes.count;
    self.pointSelectionLabel.text = selectedCount > 0
        ? [NSString stringWithFormat:@"已选 %lu 个，可测试或删除", (unsigned long)selectedCount]
        : @"点击标记选择要测试或删除的项目";
    self.pointTestButton.enabled = selectedCount == 1;
    self.pointTestButton.alpha = selectedCount == 1 ? 1.0 : 0.45;
    self.pointDeleteButton.enabled = selectedCount > 0;
    self.pointDeleteButton.alpha = selectedCount > 0 ? 1.0 : 0.45;
    [self.pointMarkerButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger index, BOOL *stop) {
        BOOL selected = [self.selectedPointIndexes containsIndex:index];
        button.backgroundColor = UIColor.clearColor;
        button.layer.borderColor = (selected ? ASAccentColor() : UIColor.whiteColor).CGColor;
        button.layer.borderWidth = selected ? 2.5 : 1.5;
        NSString *kind = index < self.customSignatures.count && self.customSignatures[index][@"templateFile"]
            ? @"截图模板" : @"点击坐标";
        button.accessibilityLabel = [NSString stringWithFormat:@"第 %lu 个%@", (unsigned long)(index + 1), kind];
    }];
}

- (void)showPointEditorInWindow:(UIWindow *)window {
    [self.markerView removeFromSuperview];
    self.markerView = nil;
    [self.selectedPointIndexes removeAllIndexes];
    self.pointMarkerButtons = [NSMutableArray array];
    self.pointSelectionLabel = nil;
    self.pointTestButton = nil;
    self.pointDeleteButton = nil;
    if (!window || self.customPoints.count == 0) {
        [self showToast:@"当前应用还没有录制项目" symbol:@"info.circle.fill" inWindow:window];
        [self presentSettingsInWindow:window];
        return;
    }

    UIView *root = [self hudRootForWindow:window];
    UIView *container = [[UIView alloc] initWithFrame:root.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor colorWithWhite:0 alpha:0.10];
    [root addSubview:container];
    self.markerView = container;

    UILabel *hint = [self labelWithText:@"点击编号选择，可多选删除" size:13 weight:UIFontWeightSemibold alpha:0.92];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.66];
    hint.layer.cornerRadius = 14;
    hint.clipsToBounds = YES;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:hint];

    for (NSUInteger index = 0; index < self.customPoints.count; index++) {
        CGPoint point = [self hudPointForScreenPoint:self.customPoints[index].CGPointValue];
        UIButton *marker = [UIButton buttonWithType:UIButtonTypeSystem];
        marker.frame = CGRectMake(point.x - 24, point.y - 24, 48, 48);
        marker.tag = 3000 + (NSInteger)index;
        marker.layer.cornerRadius = 24;
        marker.layer.shadowColor = UIColor.blackColor.CGColor;
        marker.layer.shadowOpacity = 0.35;
        marker.layer.shadowRadius = 5;
        marker.layer.shadowOffset = CGSizeMake(0, 1);
        [marker setTitle:[NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)] forState:UIControlStateNormal];
        marker.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
        marker.tintColor = UIColor.whiteColor;
        [marker addTarget:self action:@selector(onPointMarkerTap:) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:marker];
        [self.pointMarkerButtons addObject:marker];

        // 角标只显示一个字，避免遮挡中间的序号；完整类型仍通过无障碍
        // 标签提供。靠近左边缘时放右上角，靠近右边缘时放左上角，
        // 中间位置按屏幕左右自动选择，避免角标伸出屏幕。
        BOOL placeOnRight = point.x <= CGRectGetMidX(container.bounds);
        if (point.x < 38.0) placeOnRight = YES;
        if (point.x > CGRectGetWidth(container.bounds) - 38.0) placeOnRight = NO;
        BOOL isTemplate = index < self.customSignatures.count &&
            [self.customSignatures[index][@"templateFile"] isKindOfClass:[NSString class]];
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(placeOnRight ? 29.0 : 1.0, point.y < 30.0 ? 4.0 : -5.0, 18.0, 18.0)];
        badge.text = isTemplate ? @"图" : @"点";
        badge.textAlignment = NSTextAlignmentCenter;
        badge.textColor = UIColor.whiteColor;
        badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        badge.backgroundColor = isTemplate
            ? [UIColor colorWithRed:0.25 green:0.48 blue:1.0 alpha:0.96]
            : [UIColor colorWithRed:1.0 green:0.55 blue:0.10 alpha:0.96];
        badge.layer.cornerRadius = 9.0;
        badge.clipsToBounds = YES;
        badge.layer.borderWidth = 1.0;
        badge.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        badge.userInteractionEnabled = NO;
        [marker addSubview:badge];
    }

    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.layer.cornerRadius = 19;
    bar.layer.cornerCurve = kCACornerCurveContinuous;
    bar.clipsToBounds = YES;
    [container addSubview:bar];

    UILabel *selectionLabel = [self labelWithText:@"" size:12 weight:UIFontWeightMedium alpha:0.82];
    selectionLabel.textAlignment = NSTextAlignmentCenter;
    selectionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.pointSelectionLabel = selectionLabel;

    UIButton *testButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [testButton setTitle:@"测试选中" forState:UIControlStateNormal];
    testButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    testButton.tintColor = UIColor.whiteColor;
    testButton.backgroundColor = [UIColor colorWithRed:0.25 green:0.48 blue:1.0 alpha:0.92];
    testButton.layer.cornerRadius = 13;
    [testButton addTarget:self action:@selector(onPointEditorTest) forControlEvents:UIControlEventTouchUpInside];
    testButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.pointTestButton = testButton;

    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [deleteButton setTitle:@"删除选中" forState:UIControlStateNormal];
    deleteButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    deleteButton.tintColor = UIColor.whiteColor;
    deleteButton.backgroundColor = [UIColor colorWithRed:0.95 green:0.30 blue:0.25 alpha:0.92];
    deleteButton.layer.cornerRadius = 13;
    [deleteButton addTarget:self action:@selector(onPointEditorDelete) forControlEvents:UIControlEventTouchUpInside];
    deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.pointDeleteButton = deleteButton;

    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [doneButton setTitle:@"完成" forState:UIControlStateNormal];
    doneButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    doneButton.tintColor = [UIColor colorWithWhite:0.03 alpha:1];
    doneButton.backgroundColor = ASAccentColor();
    doneButton.layer.cornerRadius = 13;
    [doneButton addTarget:self action:@selector(onPointEditorDone) forControlEvents:UIControlEventTouchUpInside];
    doneButton.translatesAutoresizingMaskIntoConstraints = NO;

    [bar.contentView addSubview:selectionLabel];
    [bar.contentView addSubview:testButton];
    [bar.contentView addSubview:deleteButton];
    [bar.contentView addSubview:doneButton];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:12],
        [hint.heightAnchor constraintEqualToConstant:28],
        [bar.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [selectionLabel.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:12],
        [selectionLabel.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
        [testButton.leadingAnchor constraintEqualToAnchor:selectionLabel.trailingAnchor constant:8],
        [testButton.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor constant:7],
        [testButton.bottomAnchor constraintEqualToAnchor:bar.contentView.bottomAnchor constant:-7],
        [testButton.widthAnchor constraintEqualToConstant:70],
        [deleteButton.leadingAnchor constraintEqualToAnchor:testButton.trailingAnchor constant:7],
        [deleteButton.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor constant:7],
        [deleteButton.bottomAnchor constraintEqualToAnchor:bar.contentView.bottomAnchor constant:-7],
        [deleteButton.widthAnchor constraintEqualToConstant:76],
        [doneButton.leadingAnchor constraintEqualToAnchor:deleteButton.trailingAnchor constant:7],
        [doneButton.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-8],
        [doneButton.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor constant:7],
        [doneButton.bottomAnchor constraintEqualToAnchor:bar.contentView.bottomAnchor constant:-7],
        [doneButton.widthAnchor constraintEqualToConstant:52],
    ]];
    [self refreshPointEditorUI];
}

- (void)onPointMarkerTap:(UIButton *)marker {
    NSInteger index = marker.tag - 3000;
    if (index < 0 || index >= (NSInteger)self.customPoints.count) return;
    if ([self.selectedPointIndexes containsIndex:(NSUInteger)index]) {
        [self.selectedPointIndexes removeIndex:(NSUInteger)index];
    } else {
        [self.selectedPointIndexes addIndex:(NSUInteger)index];
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self refreshPointEditorUI];
}

- (void)onPointEditorTest {
    if (self.selectedPointIndexes.count != 1) {
        [self showToast:@"请只选择一个项目进行测试" symbol:@"exclamationmark.circle.fill" inWindow:[self resolveHostWindow:nil]];
        return;
    }
    NSUInteger index = self.selectedPointIndexes.firstIndex;
    if (index == NSNotFound || index >= self.customPoints.count) return;
    UIWindow *host = [self resolveHostWindow:nil];
    if (!host) return;

    NSDictionary *signature = index < self.customSignatures.count ? self.customSignatures[index] : @{};
    if ([signature[@"templateFile"] isKindOfClass:[NSString class]]) {
        NSString *templatePath = [self templatePathForFileName:signature[@"templateFile"]];
        [self appendTemplateDebugLog:[NSString stringWithFormat:
            @"开始手动测试 index=%lu file=%@ path=%@ exists=%@ screenPoint=%@",
            (unsigned long)index,
            signature[@"templateFile"],
            templatePath ?: @"(nil)",
            templatePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:templatePath] ? @"YES" : @"NO",
            NSStringFromCGPoint(self.customPoints[index].CGPointValue)]];
        if (![self templateFileExistsForSignature:signature]) {
            [self appendTemplateDebugLog:@"手动测试失败：模板文件不存在"];
            [self showToast:@"找图失败：模板文件不存在，请重新录制截图模板"
                     symbol:@"doc.badge.exclamationmark"
                   inWindow:host];
            return;
        }
        UIImage *snapshot = [self snapshotForHostWindow:host];
        UIImage *templateImage = templatePath.length > 0 ? [UIImage imageWithContentsOfFile:templatePath] : nil;
        CGFloat testScore = -1.0;
        NSValue *match = [self matchTemplateImage:templateImage
                                         fileName:signature[@"templateFile"]
                                      screenPoint:self.customPoints[index].CGPointValue
                                           window:host
                                         snapshot:snapshot
                                         outScore:&testScore];
        if (!match) {
            NSString *failMsg = (testScore > 0.0)
                ? [NSString stringWithFormat:@"找图失败：当前未匹配 (最高分: %.2f)", testScore]
                : @"找图失败：当前画面没有匹配模板";
            [self showToast:failMsg symbol:@"magnifyingglass" inWindow:host];
            return;
        }
        CGPoint matchPoint = match.CGPointValue;
        CGPoint matchScreenPoint = ASScreenPointFromView(host, matchPoint);
        if ([self activateScreenPoint:matchScreenPoint]) {
            [self showTapFeedbackAtPoint:matchPoint inWindow:host];
            [self showToast:[NSString stringWithFormat:@"找图成功，已点击 · 得分: %.2f", testScore]
                     symbol:@"checkmark.circle.fill"
                   inWindow:host];
        } else {
            [self showToast:@"找图成功，但点击派发失败" symbol:@"exclamationmark.circle.fill" inWindow:host];
        }
        return;
    }

    CGPoint screenPoint = self.customPoints[index].CGPointValue;
    if ([self activateScreenPoint:screenPoint]) {
        [self showTapFeedbackAtPoint:ASViewPointFromScreen(host, screenPoint) inWindow:host];
        [self showToast:@"点击测试成功" symbol:@"checkmark.circle.fill" inWindow:host];
    } else {
        [self showToast:@"点击测试失败：当前位置无法点击" symbol:@"exclamationmark.circle.fill" inWindow:host];
    }
}

- (void)onPointEditorDelete {
    if (self.selectedPointIndexes.count == 0) return;
    NSUInteger deletedCount = self.selectedPointIndexes.count;
    for (NSInteger index = (NSInteger)self.customPoints.count - 1; index >= 0; index--) {
        if (![self.selectedPointIndexes containsIndex:(NSUInteger)index]) continue;
        if (index < (NSInteger)self.customSignatures.count) {
            [self removeTemplateForSignature:self.customSignatures[(NSUInteger)index]];
            [self.customSignatures removeObjectAtIndex:(NSUInteger)index];
        }
        [self.customPoints removeObjectAtIndex:(NSUInteger)index];
    }
    [self persistCustomPoints];
    [self.selectedPointIndexes removeAllIndexes];
    [self.markerView removeFromSuperview];
    self.markerView = nil;
    self.pointMarkerButtons = [NSMutableArray array];
    UIWindow *host = [self resolveHostWindow:nil];
    if (self.customPoints.count > 0) {
        [self showPointEditorInWindow:host];
    }
    [self showToast:[NSString stringWithFormat:@"已删除 %lu 个项目", (unsigned long)deletedCount]
             symbol:@"trash.circle.fill"
           inWindow:host];
    if (self.customPoints.count == 0) {
        [self presentSettingsInWindow:host];
    }
}

- (void)onPointEditorDone {
    [self.markerView removeFromSuperview];
    self.markerView = nil;
    [self.selectedPointIndexes removeAllIndexes];
    self.pointMarkerButtons = [NSMutableArray array];
    [self presentSettingsInWindow:[self resolveHostWindow:nil]];
}

#pragma mark 设置入口：启动提示与三指长按

- (void)refreshSettingsGestures {
    // 新窗口出现后可能没有安装三指手势，因此每次刷新都重新枚举可见窗口；
    // 具体窗口通过关联对象保证不会重复添加识别器。
    for (UIWindow *window in ASVisibleWindows()) {
        [self installSettingsGestureOnWindow:window];
    }
}

- (void)scheduleLaunchToastAttempt:(NSInteger)attempt {
    // 宿主刚启动时窗口可能尚未完成创建，最多重试几次再显示启动入口，
    // 不用固定延时强行访问尚未准备好的窗口。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive || ASVisibleWindows().count == 0) {
            if (attempt < 4) [self scheduleLaunchToastAttempt:attempt + 1];
            return;
        }
        [self showLaunchToast];
    });
}

- (void)showLaunchToast {
    // 启动提示和三指长按都固定开启，始终保留两个设置入口。
    if (self.panelView || self.pickOverlay) return;
    BOOL enabled = YES;
    BOOL hasUpdate = self.updateStatus == ASUpdateStatusAvailable && self.latestTagName.length > 0;
    NSString *title = hasUpdate
        ? [NSString stringWithFormat:@"发现新版本 %@", self.latestTagName]
        : (enabled ? @"开屏广告走开 · 已就绪" : @"开屏广告走开 · 已暂停");
    NSString *detail = hasUpdate ? @"点此打开设置查看" : @"点此打开设置";
    UIView *pill = [self makePillWithTitle:title detail:detail
                                    symbol:hasUpdate ? @"arrow.down.circle.fill" : (enabled ? @"bolt.fill" : @"pause.circle.fill")
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
    // 三指手势安装在宿主窗口而不是 HUD 上，确保它不会被插件自己的
    // 面板层级影响；关闭开关时只禁用已有识别器。
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
    // 长按状态只响应 Began，避免 Changed/Ended 阶段重复打开面板。
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIWindow *window = gesture.view.window ?: (UIWindow *)gesture.view;
    [self presentSettingsInWindow:window];
}

#pragma mark 设置面板

- (void)presentSettingsInWindow:(UIWindow *)window {
    // 打开面板会暂停自动跳过会话，并隐藏当前提示；这样用户编辑开关
    // 或录制坐标时不会被后台流程同时点击宿主界面。
    if (self.pickOverlay) return;
    if (self.panelView) {
        [self rebuildPanel];
        [self checkForUpdatesIfNeeded:NO];
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
    [self checkForUpdatesIfNeeded:NO];

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
    // 面板退出完成后再执行录制或标记回调，保证旧的约束和触摸层已经
    // 从 HUD 根视图移除。
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
    // 统一生成带分隔线的圆角分组，避免每个设置项重复实现背景和间距。
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
    // 开关的 tag 是面板开关到 Defaults key 的索引，映射关系集中在
    // onPanelSwitch 中处理，便于折叠栏和新增开关共享同一套 UI。
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

- (UIView *)updateRow {
    // 在线更新使用普通可点击行而不是 UISwitch：点击有新版本时打开
    // GitHub 发布页，其他状态则重新检查，避免增加一个容易误解的开关。
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    icon.tintColor = ASAccentColor();
    icon.contentMode = UIViewContentModeCenter;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;

    UILabel *title = [self labelWithText:@"在线更新" size:15 weight:UIFontWeightMedium alpha:0.95];
    UILabel *detail = [self labelWithText:[self updateDetailText] size:12 weight:UIFontWeightRegular alpha:0.5];
    detail.numberOfLines = 1;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    self.updateTitleLabel = title;
    self.updateDetailLabel = detail;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, detail]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;

    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.tintColor = [UIColor colorWithWhite:1 alpha:0.45];
    arrow.contentMode = UIViewContentModeCenter;
    arrow.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    [arrow.widthAnchor constraintEqualToConstant:18].active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, arrow]];
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 12;
    content.userInteractionEnabled = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;

    UIControl *row = [[UIControl alloc] init];
    row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    row.layer.cornerRadius = 16;
    row.layer.cornerCurve = kCACornerCurveContinuous;
    [row addTarget:self action:@selector(onUpdateRowTap) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:row.topAnchor constant:11],
        [content.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-11],
        [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
    ]];
    return row;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action enabled:(BOOL)enabled destructive:(BOOL)destructive {
    // 坐标操作按钮统一由这里创建；破坏性操作只改变视觉强调，不在
    // 此处直接执行，清除逻辑仍由 onPanelClear 的二次确认负责。
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
    // 面板采用“完整重建”而不是逐项修改约束。开关和坐标数量变化时，
    // 这样更不容易留下旧的 arrangedSubview 或错误的折叠高度。
    UIStackView *stack = self.panelStack;
    if (!stack) return;
    for (UIView *view in stack.arrangedSubviews) {
        [stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    BOOL enabled = self.enabledOn;

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
        [self switchRowWithTitle:@"弹窗清理" detail:@"关掉更新、通知、评分等弹窗" symbol:@"xmark.rectangle" key:kASPopupDefaultsKey tag:1],
        [self switchRowWithTitle:@"全程监听" detail:@"使用中按已保存节点处理" symbol:@"eye" key:kASWatchDefaultsKey tag:2],
    ]];
    switchGroup.hidden = !self.switchesExpanded;
    switchGroup.alpha = self.switchesExpanded ? 1 : 0;
    [stack addArrangedSubview:switchGroup];
    self.switchGroup = switchGroup;
    self.switchChevron = chevron;
    self.switchSummary = summary;

    UIView *updateRow = [self updateRow];
    [stack addArrangedSubview:updateRow];
    [stack setCustomSpacing:8 afterView:updateRow];

    NSUInteger points = self.customPoints.count;
    UILabel *pointsTitle = [self labelWithText:points > 0 ? [NSString stringWithFormat:@"自定义项目 · %lu 个", (unsigned long)points] : @"自定义项目 · 未录制"
                                          size:13 weight:UIFontWeightSemibold alpha:0.6];
    [stack addArrangedSubview:pointsTitle];
    [stack setCustomSpacing:8 afterView:pointsTitle];

    BOOL hasPoints = points > 0;
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self actionButtonWithTitle:@"添加节点" symbol:@"viewfinder.circle" action:@selector(onPanelRecord) enabled:YES destructive:NO],
        [self actionButtonWithTitle:@"截图模板" symbol:@"crop" action:@selector(onPanelCaptureTemplate) enabled:YES destructive:NO],
        [self actionButtonWithTitle:@"选择删除" symbol:@"checkmark.circle" action:@selector(onPanelShowMarkers) enabled:hasPoints destructive:NO],
        [self actionButtonWithTitle:@"撤销" symbol:@"arrow.uturn.left" action:@selector(onPanelUndo) enabled:hasPoints destructive:NO],
        [self actionButtonWithTitle:self.clearArmed ? @"确认清除" : @"清除" symbol:@"trash" action:@selector(onPanelClear) enabled:hasPoints destructive:YES],
    ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 8;
    [stack addArrangedSubview:actions];

    UILabel *footer = [self labelWithText:[NSString stringWithFormat:@"v%@ · 自动检查更新、三指长按默认开启 · 设置只对当前应用生效", kASVersion] size:11 weight:UIFontWeightRegular alpha:0.35];
    footer.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:footer];
}

- (NSString *)switchSummaryText {
    // 折叠状态下仍显示关闭项，用户不展开列表也能知道哪些功能被停用。
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"弹窗清理", kASPopupDefaultsKey], @[@"全程监听", kASWatchDefaultsKey],
    ];
    NSMutableArray<NSString *> *off = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        if (![self boolForKey:item[1]]) [off addObject:item[0]];
    }
    if (off.count == 0) return [NSString stringWithFormat:@"已开 %lu/%lu", (unsigned long)items.count, (unsigned long)items.count];
    return [NSString stringWithFormat:@"已关 %@", [off componentsJoinedByString:@"、"]];
}

- (void)onSwitchHeaderTap {
    // 折叠栏只改变自身内容和箭头状态；开关值仍由每个 UISwitch 单独
    // 写入，避免点击标题栏意外改变功能设置。
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
    // 启动提示、三指长按和自动检查更新固定开启，不映射到面板开关。
    NSArray<NSString *> *keys = @[@"", kASPopupDefaultsKey, kASWatchDefaultsKey];
    if (toggle.tag <= 0 || toggle.tag >= (NSInteger)keys.count) return;
    NSString *key = keys[toggle.tag];
    UIWindow *host = [self resolveHostWindow:nil];

    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self setBool:toggle.on forKey:key];
    [self refreshCachedSettings];
    self.switchSummary.text = [self switchSummaryText];
}

- (void)onPanelRecord {
    // 先关闭面板再进入节点选择，避免面板的 HUD 控件挡住宿主节点。
    UIWindow *host = [self resolveHostWindow:nil];
    [self dismissPanelThen:^{
        [self beginPickingInWindow:host];
    }];
}

- (void)onPanelCaptureTemplate {
    // 截图模板和传统坐标录制分开入口，保留旧坐标的简单、低风险行为。
    // 模板保存后仍绑定一个屏幕锚点，运行时只在锚点附近搜索，避免全屏误匹配。
    UIWindow *host = [self resolveHostWindow:nil];
    [self dismissPanelThen:^{
        [self beginCapturingTemplateInWindow:host];
    }];
}

- (void)onPanelShowMarkers {
    // 进入可交互的项目管理层。标记沿用屏幕坐标到 HUD 的显式换算，
    // 点击编号后可以选中任意坐标或截图模板，而不是只能撤销最后一项。
    UIWindow *host = [self resolveHostWindow:nil];
    [self dismissPanelThen:^{
        [self showPointEditorInWindow:host];
    }];
}

- (void)onPanelUndo {
    // 撤销始终只删除最后一个点，并同步删除同下标的控件签名。
    if (self.customPoints.count == 0) return;
    NSUInteger removedNumber = self.customPoints.count;
    if (self.customSignatures.count > 0) {
        [self removeTemplateForSignature:self.customSignatures.lastObject];
    }
    [self.customPoints removeLastObject];
    if (self.customSignatures.count > 0) [self.customSignatures removeLastObject];
    [self persistCustomPoints];
    self.clearArmed = NO;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self rebuildPanel];
    [self showToast:[NSString stringWithFormat:@"已删除第 %lu 个项目", (unsigned long)removedNumber] symbol:@"arrow.uturn.left.circle.fill" inWindow:[self resolveHostWindow:nil]];
}

- (void)onPanelClear {
    // 清除采用两次点击确认，并设置短暂确认窗口，避免误触导致当前
    // 应用已经录制好的坐标全部丢失。
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
    for (NSDictionary *signature in self.customSignatures) {
        [self removeTemplateForSignature:signature];
    }
    [self.customPoints removeAllObjects];
    [self.customSignatures removeAllObjects];
    [self persistCustomPoints];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self rebuildPanel];
    [self showToast:@"已清除当前应用的自定义项目" symbol:@"trash.circle.fill" inWindow:[self resolveHostWindow:nil]];
}

#pragma mark 录制视图节点

- (void)beginPickingInWindow:(UIWindow *)window {
    // 节点选择层位于独立 HUD 上。候选按钮只覆盖识别到的节点边框，
    // 因此用户点击绿色框时不会把点击事件发送给宿主应用。
    UIWindow *host = [self resolveHostWindow:window];
    if (!host || self.pickOverlay) return;
    [self stopSession];
    [self dismissPill:self.toastView];
    [self.markerView removeFromSuperview];
    self.markerView = nil;

    UIView *root = [self hudRootForWindow:host];
    UIView *overlay = [[UIView alloc] initWithFrame:root.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.userInteractionEnabled = YES;
    [root addSubview:overlay];

    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    NSInteger budget = 6000;
    [self collectNodeCandidatesFromView:host
                               inWindow:host
                                  depth:0
                                 budget:&budget
                                results:candidates];
    [candidates sortUsingComparator:^NSComparisonResult(UIView *first, UIView *second) {
        BOOL firstTappable = ASViewIsTappable(first);
        BOOL secondTappable = ASViewIsTappable(second);
        if (firstTappable != secondTappable) {
            return firstTappable ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL firstHasText = ASTextOfView(first).length > 0 || first.accessibilityLabel.length > 0;
        BOOL secondHasText = ASTextOfView(second).length > 0 || second.accessibilityLabel.length > 0;
        if (firstHasText != secondHasText) {
            return firstHasText ? NSOrderedAscending : NSOrderedDescending;
        }
        CGRect firstRect = [first convertRect:first.bounds toView:host];
        CGRect secondRect = [second convertRect:second.bounds toView:host];
        CGFloat firstArea = firstRect.size.width * firstRect.size.height;
        CGFloat secondArea = secondRect.size.width * secondRect.size.height;
        if (fabs(firstArea - secondArea) > 1.0) {
            return firstArea < secondArea ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    if (candidates.count == 0) {
        [overlay removeFromSuperview];
        [self showToast:@"当前页面没有可选择的视图节点" symbol:@"viewfinder" inWindow:host];
        [self presentSettingsInWindow:host];
        return;
    }
    self.nodeHostWindow = host;
    self.nodeCandidateViews = candidates;
    self.nodeCandidateButtons = [NSMutableArray array];

    UIColor *nodeColor = [UIColor colorWithRed:0.22 green:0.92 blue:0.46 alpha:1.0];
    [candidates enumerateObjectsUsingBlock:^(UIView *node, NSUInteger index, BOOL *stop) {
        CGRect hostRect = [node convertRect:node.bounds toView:host];
        CGPoint screenMin = ASScreenPointFromView(host, CGPointMake(CGRectGetMinX(hostRect), CGRectGetMinY(hostRect)));
        CGPoint screenMax = ASScreenPointFromView(host, CGPointMake(CGRectGetMaxX(hostRect), CGRectGetMaxY(hostRect)));
        CGPoint hudMin = ASViewPointFromScreen(overlay, screenMin);
        CGPoint hudMax = ASViewPointFromScreen(overlay, screenMax);
        CGRect frame = CGRectMake(MIN(hudMin.x, hudMax.x),
                                  MIN(hudMin.y, hudMax.y),
                                  fabs(hudMax.x - hudMin.x),
                                  fabs(hudMax.y - hudMin.y));
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = frame;
        button.tag = 5000 + (NSInteger)index;
        button.backgroundColor = [nodeColor colorWithAlphaComponent:0.10];
        button.layer.borderColor = nodeColor.CGColor;
        button.layer.borderWidth = 1.5;
        button.layer.cornerRadius = 3.0;
        button.clipsToBounds = YES;
        button.tintColor = UIColor.whiteColor;
        button.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        [button setTitle:[NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)]
                forState:UIControlStateNormal];
        button.accessibilityLabel = [NSString stringWithFormat:@"选择节点 %lu %@", (unsigned long)(index + 1),
                                     ASSignatureTextOfView(node, host)];
        [button addTarget:self action:@selector(onNodeCandidateTap:) forControlEvents:UIControlEventTouchUpInside];
        [overlay addSubview:button];
        [self.nodeCandidateButtons addObject:button];
    }];

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
    UILabel *title = [self labelWithText:@"点击绿色框选择节点 · 数字是候选序号" size:13 weight:UIFontWeightSemibold alpha:1.0];
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

    self.pickOverlay = overlay;
    overlay.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 1;
    }];
}

- (void)onNodeCandidateTap:(UIButton *)button {
    NSInteger index = button.tag - 5000;
    if (index < 0 || index >= (NSInteger)self.nodeCandidateViews.count) return;
    UIView *node = self.nodeCandidateViews[(NSUInteger)index];
    UIWindow *host = self.nodeHostWindow;
    if (!node || !host) return;

    CGRect rect = [node convertRect:node.bounds toView:host];
    CGPoint point = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGPoint screenPoint = ASScreenPointFromView(host, point);
    NSDictionary *signature = [self signatureForNode:node inWindow:host];
    if (signature.count == 0 || !ASIsUsableScreenPoint(screenPoint)) {
        [self showToast:@"这个节点无法保存，请选择其他绿色框"
                 symbol:@"exclamationmark.circle.fill"
               inWindow:host];
        return;
    }

    while (self.customSignatures.count < self.customPoints.count) {
        [self.customSignatures addObject:@{}];
    }
    [self.customPoints addObject:[NSValue valueWithCGPoint:screenPoint]];
    [self.customSignatures addObject:signature];
    [self persistCustomPoints];

    UIView *overlay = self.pickOverlay;
    self.pickOverlay = nil;
    self.nodeHostWindow = nil;
    self.nodeCandidateViews = [NSMutableArray array];
    self.nodeCandidateButtons = [NSMutableArray array];
    [overlay removeFromSuperview];

    [self showTapFeedbackAtPoint:point inWindow:host];
    NSString *text = signature[@"text"];
    NSString *message = text.length > 0
        ? [NSString stringWithFormat:@"已保存第 %lu 个节点 · “%@”",
           (unsigned long)self.customPoints.count, text]
        : [NSString stringWithFormat:@"已保存第 %lu 个节点 · %@",
           (unsigned long)self.customPoints.count, signature[@"cls"] ?: @"视图"];
    [self showToast:message symbol:@"checkmark.circle.fill" inWindow:host];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self presentSettingsInWindow:host];
    });
}

- (void)updateCaptureSelectionUI {
    UIView *overlay = self.pickOverlay;
    UIView *dim = self.pickDimView;
    UIView *box = self.pickSelectionBox;
    if (!overlay || !dim || !box) return;

    CGRect bounds = overlay.bounds;
    CGRect selection = self.pickSelectionRect;
    self.pickSelectionBox.frame = selection;
    self.pickSizeLabel.text = [NSString stringWithFormat:@"%.0f × %.0f", selection.size.width, selection.size.height];
    self.pickSizeLabel.frame = CGRectMake(6, -28, MAX(selection.size.width - 12, 40), 22);

    NSArray<NSValue *> *centers = @[
        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(selection), CGRectGetMinY(selection))],
        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(selection), CGRectGetMinY(selection))],
        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(selection), CGRectGetMaxY(selection))],
        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(selection), CGRectGetMaxY(selection))],
    ];
    for (NSUInteger index = 0; index < self.pickSelectionHandles.count && index < centers.count; index++) {
        UIView *handle = self.pickSelectionHandles[index];
        CGPoint center = [centers[index] CGPointValue];
        handle.center = [overlay convertPoint:center toView:handle.superview];
    }

    // 遮罩使用独立视图，这样选框内部可以保持透明，而底部操作条仍然
    // 位于遮罩上方，不会因为镂空路径被裁掉。
    CAShapeLayer *mask = [CAShapeLayer layer];
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, bounds);
    CGPathAddRect(path, NULL, selection);
    mask.path = path;
    mask.fillRule = kCAFillRuleEvenOdd;
    dim.layer.mask = mask;
    CGPathRelease(path);
}

- (void)beginCapturingTemplateInWindow:(UIWindow *)window {
    UIWindow *host = [self resolveHostWindow:window];
    if (!host || self.pickOverlay) return;
    [self stopSession];
    [self dismissPill:self.toastView];
    [self.markerView removeFromSuperview];
    self.markerView = nil;

    UIView *root = [self hudRootForWindow:host];
    UIView *overlay = [[UIView alloc] initWithFrame:root.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;

    UIView *dim = [[UIView alloc] initWithFrame:overlay.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.24];
    [overlay addSubview:dim];

    CGFloat side = MIN(72.0, MIN(CGRectGetWidth(overlay.bounds), CGRectGetHeight(overlay.bounds)) * 0.22);
    self.pickSelectionRect = CGRectMake(CGRectGetMidX(overlay.bounds) - side / 2.0,
                                        CGRectGetMidY(overlay.bounds) - side / 2.0,
                                        side,
                                        side);
    self.pickHostWindow = host;
    self.pickOverlay = overlay;
    self.pickDimView = dim;
    self.pickSelectionHandles = [NSMutableArray array];

    UIView *selectionBox = [[UIView alloc] initWithFrame:self.pickSelectionRect];
    selectionBox.backgroundColor = UIColor.clearColor;
    selectionBox.layer.borderWidth = 1.5;
    selectionBox.layer.borderColor = ASAccentColor().CGColor;
    selectionBox.layer.cornerRadius = 4;
    selectionBox.userInteractionEnabled = YES;
    [overlay addSubview:selectionBox];
    self.pickSelectionBox = selectionBox;

    UILabel *sizeLabel = [self labelWithText:@"" size:11 weight:UIFontWeightSemibold alpha:1.0];
    sizeLabel.textAlignment = NSTextAlignmentCenter;
    sizeLabel.textColor = UIColor.whiteColor;
    sizeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    sizeLabel.layer.cornerRadius = 7;
    sizeLabel.clipsToBounds = YES;
    [selectionBox addSubview:sizeLabel];
    self.pickSizeLabel = sizeLabel;

    for (NSUInteger index = 0; index < 4; index++) {
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
        handle.backgroundColor = ASAccentColor();
        handle.layer.cornerRadius = 11;
        handle.layer.borderWidth = 2;
        handle.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        handle.tag = 100 + index;
        handle.userInteractionEnabled = YES;
        [overlay addSubview:handle];
        [self.pickSelectionHandles addObject:handle];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onCaptureHandlePan:)];
        [handle addGestureRecognizer:pan];
    }
    UIPanGestureRecognizer *selectionPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onCaptureSelectionPan:)];
    [selectionBox addGestureRecognizer:selectionPan];
    [self updateCaptureSelectionUI];

    UILabel *hint = [self labelWithText:@"拖动选框移动 · 拖四角调整大小" size:12 weight:UIFontWeightMedium alpha:0.82];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:hint];

    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.layer.cornerRadius = 18;
    bar.layer.cornerCurve = kCACornerCurveContinuous;
    bar.clipsToBounds = YES;
    [overlay addSubview:bar];

    UIButton *(^button)(NSString *, SEL, BOOL) = ^UIButton *(NSString *title, SEL action, BOOL primary) {
        UIButton *item = [UIButton buttonWithType:UIButtonTypeSystem];
        [item setTitle:title forState:UIControlStateNormal];
        item.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        item.tintColor = primary ? [UIColor colorWithWhite:0.03 alpha:1] : UIColor.whiteColor;
        item.backgroundColor = primary ? ASAccentColor() : [UIColor colorWithWhite:1 alpha:0.12];
        item.layer.cornerRadius = 13;
        item.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        [item addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        return item;
    };
    UIButton *cancel = button(@"取消", @selector(onCaptureCancel), NO);
    UIButton *reset = button(@"重置", @selector(onCaptureReset), NO);
    UIButton *test = button(@"测试", @selector(onCaptureTest), NO);
    UIButton *confirm = button(@"确认截取", @selector(onCaptureConfirm), YES);
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[cancel, reset, test, confirm]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.spacing = 7;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.contentView addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-8],
        [bar.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [buttons.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor constant:7],
        [buttons.bottomAnchor constraintEqualToAnchor:bar.contentView.bottomAnchor constant:-7],
        [buttons.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:8],
        [buttons.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-8],
        [cancel.heightAnchor constraintEqualToConstant:28],
        [reset.heightAnchor constraintEqualToConstant:28],
        [test.heightAnchor constraintEqualToConstant:28],
        [confirm.heightAnchor constraintEqualToConstant:28],
    ]];

    [root addSubview:overlay];
    overlay.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 1;
    }];
}

- (void)onCaptureSelectionPan:(UIPanGestureRecognizer *)pan {
    UIView *overlay = self.pickOverlay;
    if (!overlay) return;
    CGPoint delta = [pan translationInView:overlay];
    [pan setTranslation:CGPointZero inView:overlay];
    CGRect next = CGRectOffset(self.pickSelectionRect, delta.x, delta.y);
    CGRect bounds = CGRectInset(overlay.bounds, 12, 12);
    next.origin.x = MAX(CGRectGetMinX(bounds), MIN(CGRectGetMaxX(bounds) - next.size.width, next.origin.x));
    next.origin.y = MAX(CGRectGetMinY(bounds), MIN(CGRectGetMaxY(bounds) - next.size.height, next.origin.y));
    self.pickSelectionRect = next;
    self.pendingCaptureImage = nil;
    [self updateCaptureSelectionUI];
}

- (void)onCaptureHandlePan:(UIPanGestureRecognizer *)pan {
    UIView *overlay = self.pickOverlay;
    if (!overlay) return;
    CGPoint delta = [pan translationInView:overlay];
    [pan setTranslation:CGPointZero inView:overlay];
    CGRect rect = self.pickSelectionRect;
    NSInteger index = pan.view.tag - 100;
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    if (index == 0 || index == 3) minX += delta.x;
    if (index == 1 || index == 2) maxX += delta.x;
    if (index == 0 || index == 1) minY += delta.y;
    if (index == 2 || index == 3) maxY += delta.y;

    CGRect bounds = CGRectInset(overlay.bounds, 12, 12);
    CGFloat minimum = kASTemplateMinimumSize;
    CGFloat maximumWidth = CGRectGetWidth(bounds) * kASTemplateMaximumFraction;
    CGFloat maximumHeight = CGRectGetHeight(bounds) * kASTemplateMaximumFraction;
    minX = MAX(CGRectGetMinX(bounds), minX);
    minY = MAX(CGRectGetMinY(bounds), minY);
    maxX = MIN(CGRectGetMaxX(bounds), maxX);
    maxY = MIN(CGRectGetMaxY(bounds), maxY);
    if (maxX - minX < minimum) {
        if (index == 0 || index == 3) minX = maxX - minimum;
        else maxX = minX + minimum;
    }
    if (maxY - minY < minimum) {
        if (index == 0 || index == 1) minY = maxY - minimum;
        else maxY = minY + minimum;
    }
    if (maxX - minX > maximumWidth) {
        if (index == 0 || index == 3) minX = maxX - maximumWidth;
        else maxX = minX + maximumWidth;
    }
    if (maxY - minY > maximumHeight) {
        if (index == 0 || index == 1) minY = maxY - maximumHeight;
        else maxY = minY + maximumHeight;
    }
    self.pickSelectionRect = CGRectMake(minX, minY, maxX - minX, maxY - minY);
    self.pendingCaptureImage = nil;
    [self updateCaptureSelectionUI];
}

- (void)onCaptureReset {
    UIView *overlay = self.pickOverlay;
    if (!overlay) return;
    CGFloat side = MIN(72.0, MIN(CGRectGetWidth(overlay.bounds), CGRectGetHeight(overlay.bounds)) * 0.22);
    self.pickSelectionRect = CGRectMake(CGRectGetMidX(overlay.bounds) - side / 2.0,
                                        CGRectGetMidY(overlay.bounds) - side / 2.0,
                                        side,
                                        side);
    self.pendingCaptureImage = nil;
    [self updateCaptureSelectionUI];
}

- (void)onCaptureTest {
    UIView *overlay = self.pickOverlay;
    UIWindow *host = self.pickHostWindow;
    if (!overlay || !host) return;
    CGRect selection = self.pickSelectionRect;
    CGPoint topLeft = ASScreenPointFromView(overlay, CGPointMake(CGRectGetMinX(selection), CGRectGetMinY(selection)));
    CGPoint bottomRight = ASScreenPointFromView(overlay, CGPointMake(CGRectGetMaxX(selection), CGRectGetMaxY(selection)));
    CGRect screenRect = CGRectMake(MIN(topLeft.x, bottomRight.x),
                                   MIN(topLeft.y, bottomRight.y),
                                   fabs(bottomRight.x - topLeft.x),
                                   fabs(bottomRight.y - topLeft.y));
    CGPoint anchorScreenPoint = CGPointMake(CGRectGetMidX(screenRect), CGRectGetMidY(screenRect));
    CGPoint hostTopLeft = ASViewPointFromScreen(host, CGPointMake(CGRectGetMinX(screenRect), CGRectGetMinY(screenRect)));
    CGPoint hostBottomRight = ASViewPointFromScreen(host, CGPointMake(CGRectGetMaxX(screenRect), CGRectGetMaxY(screenRect)));
    CGRect hostRect = CGRectMake(MIN(hostTopLeft.x, hostBottomRight.x),
                                 MIN(hostTopLeft.y, hostBottomRight.y),
                                 fabs(hostBottomRight.x - hostTopLeft.x),
                                 fabs(hostBottomRight.y - hostTopLeft.y));
    hostRect = CGRectIntersection(host.bounds, hostRect);
    if (CGRectIsNull(hostRect) || hostRect.size.width < kASTemplateMinimumSize || hostRect.size.height < kASTemplateMinimumSize) {
        [self showToast:@"截图区域太小，请调整后再测试" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }

    UIImage *snapshot = [self snapshotForHostWindow:host];
    if (!snapshot.CGImage) {
        [self showToast:@"当前画面无法截取，请重试" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }
    CGImageRef croppedCGImage = CGImageCreateWithImageInRect(snapshot.CGImage, hostRect);
    if (!croppedCGImage) {
        [self showToast:@"截图失败，请调整选框后再测试" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }
    UIImage *croppedImage = [UIImage imageWithCGImage:croppedCGImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(croppedCGImage);
    if (!ASImageHasVisiblePixels(croppedImage)) {
        [self showToast:@"当前选区为纯透明/空白，请框选实际图标" symbol:@"exclamationmark.triangle.fill" inWindow:host];
        return;
    }

    self.pendingCaptureImage = croppedImage;
    self.pendingCaptureHostRect = hostRect;
    self.pendingCaptureScreenRect = screenRect;

    CGFloat bestScore = -1.0;
    NSValue *match = [self matchTemplateImage:croppedImage
                                     fileName:@"(capture_test)"
                                  screenPoint:anchorScreenPoint
                                       window:host
                                     snapshot:snapshot
                                     outScore:&bestScore];
    [self appendTemplateDebugLog:[NSString stringWithFormat:
        @"截图界面原地测试 hostRect=%@ anchor=%@ score=%.4f threshold=%.4f matched=%@",
        NSStringFromCGRect(hostRect),
        NSStringFromCGPoint(anchorScreenPoint),
        bestScore,
        kASTemplateMatchThreshold,
        match ? @"YES" : @"NO"]];

    if (match) {
        CGPoint matchPoint = match.CGPointValue;
        [self showTapFeedbackAtPoint:matchPoint inWindow:host];
        UIView *hit = [host hitTest:matchPoint withEvent:nil];
        if (!hit || hit == host || hit.tag == kASOwnViewTag) hit = host;
        BOOL activated = [self activateView:hit inWindow:host];
        if (!activated) {
            activated = ASSynthesizeTap(host, hit, matchPoint);
        }
        [self showToast:[NSString stringWithFormat:@"找图成功 · 得分: %.2f (已触发点击)", bestScore]
                 symbol:@"checkmark.circle.fill"
               inWindow:host];
    } else {
        [self showToast:[NSString stringWithFormat:@"未达匹配阈值 · 最高分: %.2f (需>=%.2f)", bestScore, kASTemplateMatchThreshold]
                 symbol:@"exclamationmark.triangle.fill"
               inWindow:host];
    }
}

- (void)onCaptureConfirm {
    UIView *overlay = self.pickOverlay;
    UIWindow *host = self.pickHostWindow;
    if (!overlay || !host) return;
    CGRect selection = self.pickSelectionRect;
    CGPoint topLeft = ASScreenPointFromView(overlay, CGPointMake(CGRectGetMinX(selection), CGRectGetMinY(selection)));
    CGPoint bottomRight = ASScreenPointFromView(overlay, CGPointMake(CGRectGetMaxX(selection), CGRectGetMaxY(selection)));
    CGRect screenRect = CGRectMake(MIN(topLeft.x, bottomRight.x),
                                   MIN(topLeft.y, bottomRight.y),
                                   fabs(bottomRight.x - topLeft.x),
                                   fabs(bottomRight.y - topLeft.y));
    CGPoint anchorScreenPoint = CGPointMake(CGRectGetMidX(screenRect), CGRectGetMidY(screenRect));
    CGPoint hostTopLeft = ASViewPointFromScreen(host, CGPointMake(CGRectGetMinX(screenRect), CGRectGetMinY(screenRect)));
    CGPoint hostBottomRight = ASViewPointFromScreen(host, CGPointMake(CGRectGetMaxX(screenRect), CGRectGetMaxY(screenRect)));
    CGRect hostRect = CGRectMake(MIN(hostTopLeft.x, hostBottomRight.x),
                                 MIN(hostTopLeft.y, hostBottomRight.y),
                                 fabs(hostBottomRight.x - hostTopLeft.x),
                                 fabs(hostBottomRight.y - hostTopLeft.y));
    hostRect = CGRectIntersection(host.bounds, hostRect);
    if (CGRectIsNull(hostRect) || hostRect.size.width < kASTemplateMinimumSize || hostRect.size.height < kASTemplateMinimumSize) {
        [self showToast:@"截图区域太小，请重新调整" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }

    UIImage *croppedImage = nil;
    UIImage *snapshot = nil;
    if (self.pendingCaptureImage &&
        CGRectEqualToRect(self.pendingCaptureScreenRect, screenRect) &&
        !CGRectIsNull(self.pendingCaptureHostRect)) {
        croppedImage = self.pendingCaptureImage;
        hostRect = self.pendingCaptureHostRect;
    } else {
        snapshot = [self snapshotForHostWindow:host];
        if (!snapshot.CGImage) {
            [self showToast:@"当前画面无法截取，请重试" symbol:@"exclamationmark.circle.fill" inWindow:host];
            return;
        }
        CGImageRef croppedCGImage = CGImageCreateWithImageInRect(snapshot.CGImage, hostRect);
        if (!croppedCGImage) {
            [self showToast:@"截图失败，请重新调整选框" symbol:@"exclamationmark.circle.fill" inWindow:host];
            return;
        }
        croppedImage = [UIImage imageWithCGImage:croppedCGImage scale:1.0 orientation:UIImageOrientationUp];
        CGImageRelease(croppedCGImage);
    }
    [self appendTemplateDebugLog:[NSString stringWithFormat:
        @"录制截图 hostClass=%@ rootClass=%@ screenRect=%@ hostRect=%@ snapshotPixels=%zux%zu croppedVisible=%@",
        NSStringFromClass(host.class),
        NSStringFromClass(host.rootViewController.view.class),
        NSStringFromCGRect(screenRect),
        NSStringFromCGRect(hostRect),
        snapshot.CGImage ? CGImageGetWidth(snapshot.CGImage) : (size_t)0,
        snapshot.CGImage ? CGImageGetHeight(snapshot.CGImage) : (size_t)0,
        ASImageHasVisiblePixels(croppedImage) ? @"YES" : @"NO"]];
    if (!ASImageHasVisiblePixels(croppedImage)) {
        [self showToast:@"当前选区无法读取，请重新选择实际图标区域"
                 symbol:@"exclamationmark.triangle.fill"
               inWindow:host];
        return;
    }
    NSData *pngData = UIImagePNGRepresentation(croppedImage);
    if (pngData.length == 0) {
        [self showToast:@"截图保存失败，请重试" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [self templateDirectoryPath];
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        [self showToast:@"无法创建当前应用的模板目录" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }
    NSString *fileName = [NSString stringWithFormat:@"tpl_%@.png", NSUUID.UUID.UUIDString.lowercaseString];
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    NSError *writeError = nil;
    if (![pngData writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        [self showToast:@"截图保存失败，请重试" symbol:@"exclamationmark.circle.fill" inWindow:host];
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    BOOL excludedFromBackup = YES;
    [fileURL setResourceValue:@(excludedFromBackup) forKey:NSURLIsExcludedFromBackupKey error:nil];

    NSMutableDictionary *signature = [[self signatureAtScreenPoint:anchorScreenPoint] mutableCopy] ?: [NSMutableDictionary dictionary];
    signature[@"type"] = @"imageTemplate";
    signature[@"templateFile"] = fileName;
    signature[@"templateSize"] = NSStringFromCGSize(hostRect.size);
    signature[@"templateRect"] = NSStringFromCGRect(screenRect);
    while (self.customSignatures.count < self.customPoints.count) [self.customSignatures addObject:@{}];
    [self.customPoints addObject:[NSValue valueWithCGPoint:anchorScreenPoint]];
    [self.customSignatures addObject:[signature copy]];
    [self persistCustomPoints];

    self.pickOverlay = nil;
    self.pickDimView = nil;
    self.pickSelectionBox = nil;
    self.pickSizeLabel = nil;
    self.pickHostWindow = nil;
    self.pickSelectionHandles = [NSMutableArray array];
    self.pendingCaptureImage = nil;
    self.pendingCaptureHostRect = CGRectZero;
    self.pendingCaptureScreenRect = CGRectZero;
    [overlay removeFromSuperview];
    [self showTapFeedbackAtPoint:ASViewPointFromScreen(host, anchorScreenPoint) inWindow:host];
    [self showToast:[NSString stringWithFormat:@"已保存截图模板 · %.0f × %.0f", hostRect.size.width, hostRect.size.height] inWindow:host];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self presentSettingsInWindow:host];
    });
}

- (void)onCaptureCancel {
    UIView *overlay = self.pickOverlay;
    self.pendingCaptureImage = nil;
    self.pendingCaptureHostRect = CGRectZero;
    self.pendingCaptureScreenRect = CGRectZero;
    self.pickOverlay = nil;
    self.pickDimView = nil;
    self.pickSelectionBox = nil;
    self.pickSizeLabel = nil;
    self.pickHostWindow = nil;
    self.pickSelectionHandles = [NSMutableArray array];
    self.pendingCaptureImage = nil;
    self.pendingCaptureHostRect = CGRectZero;
    self.pendingCaptureScreenRect = CGRectZero;
    [overlay removeFromSuperview];
    UIWindow *host = [self resolveHostWindow:nil];
    [self showToast:@"已取消截图" symbol:@"xmark.circle.fill" inWindow:host];
    [self presentSettingsInWindow:host];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // 录制遮罩的 tap 只接收 overlay 自己的触摸，卡片拖动和取消按钮
    // 由它们各自的手势/控件处理。
    if (gestureRecognizer.view != self.pickOverlay) return YES;
    return touch.view == self.pickOverlay;
}

- (void)onOverlayTap:(UITapGestureRecognizer *)tap {
    // 把录制点立即转换成屏幕坐标并校验，再保存控件签名；
    // 屏幕坐标是唯一持久化坐标系，防止窗口坐标变化造成偏移。
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
                               : [NSString stringWithFormat:@"已保存第 %lu 个 · 纯坐标点", (unsigned long)self.customPoints.count]);
    [self showToast:message inWindow:host];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self presentSettingsInWindow:host];
    });
}

- (void)onPickPillPan:(UIPanGestureRecognizer *)pan {
    // 拖动提示卡时只修改 HUD 局部 transform，并按安全区限制边界，
    // 不会影响已经录制的屏幕坐标。
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
    // 取消只移除节点选择层，不修改已保存的项目；随后返回设置面板。
    UIView *overlay = self.pickOverlay;
    self.pickOverlay = nil;
    self.nodeHostWindow = nil;
    self.nodeCandidateViews = [NSMutableArray array];
    self.nodeCandidateButtons = [NSMutableArray array];
    [overlay removeFromSuperview];
    UIWindow *host = [self resolveHostWindow:nil];
    [self showToast:@"已取消录制" symbol:@"xmark.circle.fill" inWindow:host];
    [self presentSettingsInWindow:host];
}

@end

#pragma mark - 入口

static void ASInstallUIHooks(void) {
    // 监听只挂在通用的 viewDidAppear/addSubview 上，用于捕捉新页面和
    // 全屏遮罩。所有回调都先调用原实现，再做轻量登记，避免破坏宿主行为。
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
    // 包名和工程名改过后，旧版本仍可能留下 AdSkip.* 设置。
    // 只迁移不存在的新 key，避免覆盖用户已经在新版本中修改的值。
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
        // 动态库加载时只完成轻量初始化和通知注册；真正的窗口扫描由
        // UIApplication 生命周期通知触发，避免过早访问宿主 UIKit。
        if (!ASShouldRunInProcess()) return;
        ASMigrateLegacyDefaults();
        [SplashAwayEngine shared];
        ASInstallUIHooks();
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];

        [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            [[SplashAwayEngine shared] markActivationAndStart];
            [[SplashAwayEngine shared] scheduleLaunchToastAttempt:0];
            // 启动后延迟检查，避免把 GitHub 网络请求放在宿主首屏关键路径上。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[SplashAwayEngine shared] checkForUpdatesIfNeeded:NO];
            });
        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            [[SplashAwayEngine shared] markActivationAndStart];
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            [[SplashAwayEngine shared] markActivationAndStart];
        }];
        [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[UIWindow class]]) {
                [[SplashAwayEngine shared] handleWindowBecameVisible:note.object];
            }
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:mainQueue usingBlock:^(NSNotification *note) {
            [[SplashAwayEngine shared] stopSession];
            [[SplashAwayEngine shared] stopPointWatcher];
        }];
    }
}
