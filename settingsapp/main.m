#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.aprin.goldticker";

static id GTPref(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
}

static void GTPrefSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFTypeRef)value,
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}

static BOOL GTPrefBool(NSString *key, BOOL fallback) {
    id value = GTPref(key);
    return value ? [value boolValue] : fallback;
}

static double GTPrefDouble(NSString *key, double fallback) {
    id value = GTPref(key);
    return value ? [value doubleValue] : fallback;
}

static UILabel *GTLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

@interface GTSettingsController : UIViewController
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISwitch *alertSwitch;
@property (nonatomic, strong) UISwitch *soundSwitch;
@property (nonatomic, strong) UITextField *intervalField;
@property (nonatomic, strong) UITextField *thresholdField;
@end

@implementation GTSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"金价设置";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(save)];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    self.stack = stack;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-40]
    ]];

    // 开关行
    self.enabledSwitch = [self addSwitchRow:@"在状态栏显示金价"
                                      value:GTPrefBool(@"enable", YES)];
    self.alertSwitch = [self addSwitchRow:@"跌破提醒"
                                    value:GTPrefBool(@"alert_enable", YES)];
    self.soundSwitch = [self addSwitchRow:@"提醒时播放音乐"
                                    value:GTPrefBool(@"sound_enable", YES)];

    // 输入行
    double interval = GTPrefDouble(@"interval", 5.0);
    NSString *intervalText = [NSString stringWithFormat:@"%.0f", interval];
    self.intervalField = [self addFieldRow:@"刷新间隔（秒，最小 3）" text:intervalText keyboard:UIKeyboardTypeNumberPad];

    id threshold = GTPref(@"threshold");
    NSString *thresholdText = threshold ? [NSString stringWithFormat:@"%.2f", [threshold doubleValue]] : @"";
    self.thresholdField = [self addFieldRow:@"提醒金额（元/克）" text:thresholdText keyboard:UIKeyboardTypeDecimalPad];

    [stack addArrangedSubview:GTLabel(@"留空表示不提醒。价格跌破该值时会播放音乐并弹出横幅；价格回升到 1.002 倍以上才会重新武装。",
                                      [UIFont systemFontOfSize:13],
                                      [UIColor secondaryLabelColor])];
    [stack addArrangedSubview:GTLabel(@"自定义音乐：把音频放到 /var/mobile/Library/GoldTicker/alert.m4a（也支持 mp3 / wav / caf / aac），文件名固定为 alert。",
                                      [UIFont systemFontOfSize:13],
                                      [UIColor secondaryLabelColor])];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [saveButton setTitle:@"保存设置" forState:UIControlStateNormal];
    saveButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    saveButton.backgroundColor = [UIColor systemBlueColor];
    [saveButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveButton.layer.cornerRadius = 10.0;
    saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [saveButton.heightAnchor constraintEqualToConstant:46].active = YES;
    [saveButton addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:saveButton];
}

- (UISwitch *)addSwitchRow:(NSString *)title value:(BOOL)value {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;

    UILabel *label = GTLabel(title, [UIFont systemFontOfSize:16], UIColor.labelColor);
    [row addArrangedSubview:label];
    [row addArrangedSubview:[[UIView alloc] init]];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = value;
    [row addArrangedSubview:toggle];

    [[self stack] addArrangedSubview:row];
    return toggle;
}

- (UITextField *)addFieldRow:(NSString *)title text:(NSString *)text keyboard:(UIKeyboardType)keyboard {
    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 6.0;

    [box addArrangedSubview:GTLabel(title, [UIFont systemFontOfSize:14], [UIColor secondaryLabelColor])];

    UITextField *field = [[UITextField alloc] init];
    field.text = text;
    field.keyboardType = keyboard;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
    field.placeholder = @"例如 980.50";
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.heightAnchor constraintEqualToConstant:40].active = YES;
    [box addArrangedSubview:field];

    [[self stack] addArrangedSubview:box];
    return field;
}

- (void)save {
    GTPrefSet(@"enable", @(self.enabledSwitch.on));
    GTPrefSet(@"alert_enable", @(self.alertSwitch.on));
    GTPrefSet(@"sound_enable", @(self.soundSwitch.on));

    double interval = [self.intervalField.text doubleValue];
    if (interval < 3.0) interval = 3.0;
    GTPrefSet(@"interval", @(interval));

    NSString *thresholdText = [self.thresholdField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    double threshold = thresholdText.length ? [thresholdText doubleValue] : 0.0;
    if (threshold > 0) {
        GTPrefSet(@"threshold", @(threshold));
    } else {
        GTPrefSet(@"threshold", nil);
    }

    self.intervalField.text = [NSString stringWithFormat:@"%.0f", interval];
    [self.view endEditing:YES];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已保存"
                                                                  message:@"状态栏会立即按新设置刷新，无需注销。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface GTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation GTAppDelegate
- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    GTSettingsController *controller = [[GTSettingsController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([GTAppDelegate class]));
    }
}
