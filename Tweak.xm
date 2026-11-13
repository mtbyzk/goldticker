/**
 * GoldTicker —— iOS 状态栏实时金价（注入 SpringBoard）
 *
 * - 状态栏时钟右侧显示金价，按刷新间隔轮询行情
 * - 跌破提醒金额时：播放自定义音乐（默认 3 次）+ 顶部横幅提示
 * - 配置由设置面板（prefs 子项目）写入 com.aprin.goldticker 域
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

static NSString *const kPrefDomain = @"com.aprin.goldticker";
static NSString *const kSinaURL = @"https://hq.sinajs.cn/list=nf_AU0,gds_AU9999,hf_XAU,fx_susdcny";
static NSString *const kJZJURL = @"https://i.jzj9999.com/res/quote/pq.json?m_t%.0f";
static NSString *const kAlertName = @"alert";

#pragma mark - 配置读取

static id GTPref(NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)kPrefDomain;
    CFPreferencesAppSynchronize(domain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain));
}

static BOOL GTPrefBool(NSString *key, BOOL fallback) {
    id value = GTPref(key);
    return value ? [value boolValue] : fallback;
}

static double GTPrefDouble(NSString *key, double fallback) {
    id value = GTPref(key);
    return value ? [value doubleValue] : fallback;
}

/** 用户自定义音乐的查找目录：沙盒外的共享目录 + 插件自带目录 */
static NSArray<NSString *> *GTDataDirs(void) {
    return @[ @"/var/mobile/Library/GoldTicker", @"/var/jb/Library/GoldTicker" ];
}

#pragma mark - 主体

@interface GoldTicker : NSObject

@property (nonatomic, strong) UIWindow *barWindow;
@property (nonatomic, strong) UILabel *priceLabel;

@property (nonatomic, strong) UIWindow *bannerWindow;
@property (nonatomic, strong) UIView *bannerBox;
@property (nonatomic, strong) UILabel *bannerLabel;

@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSDate *lastFetch;

@property (nonatomic, assign) double lastPrice;
@property (nonatomic, assign) BOOL alerting;
@property (nonatomic, assign) NSInteger retry;

/** 防烧屏：当前是否在第三方 App 内（不在主屏/锁屏） */
@property (nonatomic, assign) BOOL inApp;
/** 防烧屏：每 10 分钟递增一次，用来左右交替微移 */
@property (nonatomic, assign) NSInteger driftStep;
@property (nonatomic, strong) NSTimer *burninTimer;
/** 每 10 秒重新套用一次配色，保证设置里开关后用不着切 App */
@property (nonatomic, assign) NSInteger tickCount;

+ (instancetype)shared;
- (void)start;

@end

@interface GoldTicker ()
- (UIWindowScene *)activeScene;
- (CGFloat)statusBarHeight;
- (void)buildBarWindow;
- (CGRect)clockRectOnScreen;
- (UIView *)clockViewIn:(UIView *)root regex:(NSRegularExpression *)regex;
- (void)layoutPriceLabel;
- (void)onTick:(NSTimer *)timer;
- (void)refresh;
- (void)refreshSina;
- (void)setupBurnIn;
- (void)onBurninTick:(NSTimer *)timer;
- (void)appDidActivate:(NSNotification *)note;
- (void)appDidDeactivate:(NSNotification *)note;
- (void)updateAppearance;
- (UIColor *)normalTextColor;
- (UIColor *)normalShadowColor;
- (CGFloat)driftX;
- (CGFloat)driftY;
- (double)parseJZJ:(NSData *)data;
- (double)parseSina:(NSString *)text;
- (NSArray *)fieldsFor:(NSString *)code in:(NSString *)text;
- (void)applyPrice:(double)price;
- (void)evaluateAlert:(double)price;
- (void)fireAlert:(double)price threshold:(double)threshold;
- (NSString *)alertPath;
- (void)playAlert;
- (void)buildBannerIfNeeded;
- (void)showBanner:(NSString *)text;
- (void)hideBanner;
@end

@implementation GoldTicker

+ (instancetype)shared {
    static GoldTicker *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GoldTicker alloc] init];
    });
    return instance;
}

- (void)start {
    @try {
        if (self.timer) return;
        if (![self activeScene]) {
            // SpringBoard 刚启动时 windowScene 还没就绪，每秒重试
            if (self.retry++ < 40) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self start];
                });
            }
            return;
        }
        [self buildBarWindow];
        [self setupBurnIn];
        self.timer = [NSTimer timerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(onTick:)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
        [self onTick:nil];
    } @catch (NSException *exception) {
        NSLog(@"[GoldTicker] start failed: %@", exception);
    }
}

- (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

#pragma mark 状态栏覆盖层

- (CGFloat)statusBarHeight {
    CGRect frame = UIApplication.sharedApplication.statusBarFrame;
    if (frame.size.height > 0) return frame.size.height;
    CGRect clock = [self clockRectOnScreen];
    if (clock.size.height > 0) return clock.origin.y * 2.0 + clock.size.height;
    return 54.0;
}

- (void)buildBarWindow {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    // 多留 24pt 纵向空间，方便用户把价格往下调
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, screen.width, [self statusBarHeight] + 24.0)];
    window.windowScene = [self activeScene];
    window.windowLevel = UIWindowLevelStatusBar + 1;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.clipsToBounds = NO;
    window.hidden = NO;
    self.barWindow = window;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"----";
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedDigitSystemFontOfSize:10.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentLeft;
    label.userInteractionEnabled = NO;
    // 白字加黑色描边阴影，浅色壁纸/浅色 App 下也能看清
    label.layer.shadowColor = UIColor.blackColor.CGColor;
    label.layer.shadowOpacity = 0.9;
    label.layer.shadowRadius = 1.5;
    label.layer.shadowOffset = CGSizeZero;
    [window addSubview:label];
    self.priceLabel = label;

    [self layoutPriceLabel];
}

/** 找到状态栏里显示时间的那个文本视图（用来定位价格标签，避免压住时钟） */
- (CGRect)clockRectOnScreen {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,2}:[0-9]{2}$"
                                                          options:0
                                                            error:nil];
    });
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window == self.barWindow || window == self.bannerWindow) continue;
        UIView *view = [self clockViewIn:window regex:regex];
        if (view) {
            CGRect rect = [view convertRect:view.bounds toView:nil];
            return CGRectOffset(rect, window.frame.origin.x, window.frame.origin.y);
        }
    }
    return CGRectZero;
}

- (UIView *)clockViewIn:(UIView *)root regex:(NSRegularExpression *)regex {
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:NSClassFromString(@"_UIStatusBarStringView")] &&
            [sub respondsToSelector:@selector(text)]) {
            NSString *text = [(UILabel *)sub text];
            if ([text isKindOfClass:[NSString class]] && text.length &&
                [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] > 0) {
                return sub;
            }
        }
        UIView *found = [self clockViewIn:sub regex:regex];
        if (found) return found;
    }
    return nil;
}

- (void)layoutPriceLabel {
    if (!self.priceLabel) return;
    CGFloat statusHeight = [self statusBarHeight];
    CGFloat barHeight = self.barWindow.bounds.size.height;
    CGRect clock = [self clockRectOnScreen];
    NSString *text = self.priceLabel.text.length ? self.priceLabel.text : @"----";

    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:10.0 weight:UIFontWeightSemibold];
    CGSize size = [text sizeWithAttributes:@{NSFontAttributeName : font}];
    CGFloat x = clock.size.width > 0 ? CGRectGetMaxX(clock) + 4.0 : 92.0;
    CGFloat limit = UIScreen.mainScreen.bounds.size.width * 0.5 - 36.0;
    if (x + size.width > limit) {
        font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightSemibold];
        size = [text sizeWithAttributes:@{NSFontAttributeName : font}];
    }
    // 用户在设置里配置的横/纵偏移 + 防烧屏微移
    CGFloat offsetX = GTPrefDouble(@"offset_x", 0);
    CGFloat offsetY = GTPrefDouble(@"offset_y", 0);
    x += offsetX + [self driftX];
    if (x + size.width > limit) {
        x = MAX(4.0, limit - size.width);
    }

    CGFloat y = ceil((statusHeight - size.height) / 2.0) + offsetY + [self driftY];
    y = MAX(0.0, MIN(y, barHeight - size.height));

    self.priceLabel.font = font;
    self.priceLabel.frame = CGRectMake(x, y, size.width + 2.0, size.height);
}

#pragma mark 防烧屏

- (void)setupBurnIn {
    if (self.burninTimer) return;

    // SpringBoard 会给前后台切换发这些通知：App 激活 = 不在主屏
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(appDidActivate:)
                   name:@"SBApplicationDidBecomeActiveNotification"
                 object:nil];
    [center addObserver:self
               selector:@selector(appDidDeactivate:)
                   name:@"SBApplicationDidResignActiveNotification"
                 object:nil];
    [center addObserver:self
               selector:@selector(appDidDeactivate:)
                   name:@"SBApplicationDidExitNotification"
                 object:nil];

    // 每 10 分钟微移一次，避免同一像素长期高亮
    self.burninTimer = [NSTimer timerWithTimeInterval:600.0
                                               target:self
                                             selector:@selector(onBurninTick:)
                                             userInfo:nil
                                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.burninTimer forMode:NSRunLoopCommonModes];

    [self updateAppearance];
}

- (void)onBurninTick:(NSTimer *)timer {
    self.driftStep = self.driftStep + 1;
    [self layoutPriceLabel];
}

- (void)appDidActivate:(NSNotification *)note {
    self.inApp = YES;
    [self updateAppearance];
}

- (void)appDidDeactivate:(NSNotification *)note {
    self.inApp = NO;
    [self updateAppearance];
}

/** 主屏用白字（配黑描边），其它 App 用黑字（配白描边） */
- (UIColor *)normalTextColor {
    if (self.inApp && GTPrefBool(@"burnin", YES)) return UIColor.blackColor;
    return UIColor.whiteColor;
}

- (UIColor *)normalShadowColor {
    if (self.inApp && GTPrefBool(@"burnin", YES)) return UIColor.whiteColor;
    return UIColor.blackColor;
}

- (void)updateAppearance {
    if (!self.priceLabel) return;
    if (!self.alerting) self.priceLabel.textColor = [self normalTextColor];
    self.priceLabel.layer.shadowColor = [self normalShadowColor].CGColor;
    [self layoutPriceLabel];
}

- (CGFloat)driftX {
    if (!GTPrefBool(@"burnin", YES)) return 0;
    return (self.driftStep % 2 == 0) ? -2.0 : 2.0;
}

- (CGFloat)driftY {
    if (!GTPrefBool(@"burnin", YES)) return 0;
    return (self.driftStep % 4 < 2) ? 0.0 : -1.0;
}

#pragma mark 定时与刷新

- (void)onTick:(NSTimer *)timer {
    @try {
        BOOL enabled = GTPrefBool(@"enable", YES);
        self.barWindow.hidden = !enabled;
        if (!enabled) return;

        [self layoutPriceLabel];

        self.tickCount = self.tickCount + 1;
        if (self.tickCount % 10 == 0) {
            [self updateAppearance];
        }

        double interval = GTPrefDouble(@"interval", 5.0);
        if (interval < 3.0) interval = 3.0;
        if (!self.lastFetch || [[NSDate date] timeIntervalSinceDate:self.lastFetch] >= interval) {
            [self refresh];
        }
    } @catch (NSException *exception) {
        NSLog(@"[GoldTicker] tick failed: %@", exception);
    }
}

- (void)refresh {
    self.lastFetch = [NSDate date];

    NSString *url = [NSString stringWithFormat:kJZJURL, [[NSDate date] timeIntervalSince1970] * 1000.0];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 6.0;
    [request setValue:@"Mozilla/5.0 MicroMessenger/8.0.52" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://servicewechat.com/" forHTTPHeaderField:@"Referer"];

    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        double price = [self parseJZJ:data];
        if (price > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self applyPrice:price];
            });
        } else {
            [self refreshSina];
        }
    }] resume];
}

- (void)refreshSina {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kSinaURL]];
    request.timeoutInterval = 6.0;
    [request setValue:@"https://finance.sina.com.cn" forHTTPHeaderField:@"Referer"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(self) self = weakSelf;
        if (!self || data.length == 0) return;
        NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        NSString *text = [[NSString alloc] initWithData:data encoding:encoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        double price = [self parseSina:text];
        if (price > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self applyPrice:price];
            });
        }
    }] resume];
}

#pragma mark 行情解析

- (double)parseJZJ:(NSData *)data {
    if (data.length == 0) return 0;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return 0;
    NSArray *items = ((NSDictionary *)object)[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return 0;

    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (![item[@"code"] isEqual:@"JZJ_au"]) continue;
        double ask = [item[@"askprice"] doubleValue];
        double stamp = [item[@"stime"] doubleValue];
        if (ask <= 0) return 0;
        // 超过 90 秒视为停盘/陈旧数据
        if (stamp > 0 && [[NSDate date] timeIntervalSince1970] - stamp > 90) return 0;
        return ask;
    }
    return 0;
}

- (double)parseSina:(NSString *)text {
    if (text.length == 0) return 0;

    NSArray *nf = [self fieldsFor:@"nf_AU0" in:text];
    if (nf.count >= 11) {
        double price = [nf[8] doubleValue];
        if (price > 0) return price;
    }
    NSArray *au = [self fieldsFor:@"gds_AU9999" in:text];
    if (au.count >= 9) {
        double price = [au[0] doubleValue];
        if (price > 0) return price;
    }
    NSArray *xau = [self fieldsFor:@"hf_XAU" in:text];
    NSArray *fx = [self fieldsFor:@"fx_susdcny" in:text];
    if (xau.count > 6 && fx.count > 2) {
        double usd = [xau[0] doubleValue];
        double rate = ([fx[1] doubleValue] + [fx[2] doubleValue]) / 2.0;
        if (usd > 0 && rate > 0) return usd * rate / 31.1034768;
    }
    return 0;
}

- (NSArray *)fieldsFor:(NSString *)code in:(NSString *)text {
    NSString *pattern = [NSString stringWithFormat:@"hq_str_%@=\"([^\"]*)\"", code];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    NSString *body = [text substringWithRange:[match rangeAtIndex:1]];
    return [body componentsSeparatedByString:@","];
}

#pragma mark 显示与提醒

- (void)applyPrice:(double)price {
    if (price <= 0) return;
    self.lastPrice = price;
    self.priceLabel.text = [NSString stringWithFormat:@"%.2f", price];
    [self evaluateAlert:price];
    [self layoutPriceLabel];
}

- (void)evaluateAlert:(double)price {
    double threshold = GTPrefDouble(@"threshold", 0);
    BOOL alertEnabled = GTPrefBool(@"alert_enable", YES);

    if (!alertEnabled || threshold <= 0) {
        self.alerting = NO;
        self.priceLabel.textColor = [self normalTextColor];
        return;
    }

    if (price < threshold) {
        self.priceLabel.textColor = [UIColor colorWithRed:1.0 green:0.72 blue:0.30 alpha:1.0];
        if (!self.alerting) {
            self.alerting = YES;
            [self fireAlert:price threshold:threshold];
        }
    } else {
        self.priceLabel.textColor = [self normalTextColor];
        // 回升到提醒价上方 0.2% 才重新武装，避免价格贴着阈值反复响
        if (price > threshold * 1.002) self.alerting = NO;
    }
}

- (void)fireAlert:(double)price threshold:(double)threshold {
    [self showBanner:[NSString stringWithFormat:@"金价 %.2f 已低于提醒价 %.2f", price, threshold]];
    if (GTPrefBool(@"sound_enable", YES)) {
        [self playAlert];
    }
}

- (NSString *)alertPath {
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *dir in GTDataDirs()) {
        for (NSString *ext in @[ @"m4a", @"mp3", @"wav", @"caf", @"aac" ]) {
            NSString *path = [dir stringByAppendingPathComponent:[kAlertName stringByAppendingPathExtension:ext]];
            if ([manager fileExistsAtPath:path]) return path;
        }
    }
    return nil;
}

- (void)playAlert {
    NSString *path = [self alertPath];
    if (!path) {
        AudioServicesPlaySystemSound(1005);
        return;
    }
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    [session setActive:YES error:&error];

    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                         error:&error];
    if (!self.player) {
        NSLog(@"[GoldTicker] audio error: %@", error);
        AudioServicesPlaySystemSound(1005);
        return;
    }
    self.player.numberOfLoops = 2;
    self.player.volume = 1.0;
    [self.player play];
}

#pragma mark 横幅

- (void)buildBannerIfNeeded {
    if (self.bannerWindow) return;

    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.windowScene = [self activeScene];
    window.windowLevel = UIWindowLevelAlert + 3;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.hidden = NO;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 64)];
    box.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    box.layer.cornerRadius = 16.0;
    box.layer.masksToBounds = YES;
    box.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:box.bounds];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    label.numberOfLines = 0;
    label.userInteractionEnabled = NO;
    [box addSubview:label];

    [window addSubview:box];
    self.bannerWindow = window;
    self.bannerBox = box;
    self.bannerLabel = label;
}

- (void)showBanner:(NSString *)text {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showBanner:text];
        });
        return;
    }
    [self buildBannerIfNeeded];

    self.bannerLabel.text = text;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat width = MIN(320.0, screen.width - 32.0);
    CGSize fit = [text boundingRectWithSize:CGSizeMake(width - 28.0, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:@{NSFontAttributeName : self.bannerLabel.font}
                                    context:nil].size;
    CGFloat height = MAX(56.0, ceil(fit.height) + 24.0);

    self.bannerBox.frame = CGRectMake((screen.width - width) / 2.0, 12.0, width, height);
    self.bannerLabel.frame = CGRectMake(14.0, 12.0, width - 28.0, height - 24.0);
    self.bannerBox.hidden = NO;
    self.bannerBox.alpha = 0.0;
    [UIView animateWithDuration:0.25 animations:^{
        self.bannerBox.alpha = 1.0;
    }];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideBanner) object:nil];
    [self performSelector:@selector(hideBanner) withObject:nil afterDelay:6.0];
}

- (void)hideBanner {
    [UIView animateWithDuration:0.3 animations:^{
        self.bannerBox.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.bannerBox.hidden = YES;
    }];
}

@end

#pragma mark - 入口

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[GoldTicker shared] start];
    });
}
