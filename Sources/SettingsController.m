#import "SettingsController.h"
#import "Localization.h"
#import <ServiceManagement/ServiceManagement.h>
#include <math.h>

static NSString *const UVSettingsFeedbackKey = @"USBVolume.feedback";

static NSTextField *UVSettingsLabel(NSString *text, CGFloat size) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@interface UVSettingsController () <NSWindowDelegate>
@property(nonatomic) SMAppService *loginService;
@property(nonatomic) NSTextField *languageLabel;
@property(nonatomic) NSPopUpButton *languagePicker;
@property(nonatomic) NSLayoutConstraint *languagePickerWidth;
@property(nonatomic) NSLayoutConstraint *feedbackTop;
@property(nonatomic) BOOL showsLoginDetail;
@property(nonatomic) NSTextField *loginLabel;
@property(nonatomic) NSTextField *keyboardLabel;
@property(nonatomic) NSButton *aboutButton;
@property(nonatomic) NSSwitch *loginSwitch;
@property(nonatomic) NSTextField *loginStatusLabel;
@property(nonatomic) NSButton *loginSettingsButton;
@property(nonatomic) NSButton *feedbackCheckbox;
@property(nonatomic) NSTextField *keyboardStatusLabel;
@property(nonatomic) NSButton *keyboardPermissionButton;
@property(nonatomic) BOOL updatingLogin;
@property(nonatomic) BOOL keyboardActive;
@property(nonatomic) BOOL keyboardNeedsPermission;
@property(nonatomic, copy) NSString *loginError;
@property(nonatomic) SMAppServiceStatus lastLoginStatus;
@property(nonatomic) BOOL hasLoginStatus;
@end

@implementation UVSettingsController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 232)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.title = UVL(@"设置");
        window.releasedWhenClosed = NO;
        window.delegate = self;
        [window center];
        _loginService = SMAppService.mainAppService;
        _loginError = @"";
        [self buildControls];
        [self applyLocalization];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationBecameActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
        [center addObserver:self selector:@selector(defaultsChanged:) name:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults];
        [center addObserver:self selector:@selector(languageDidChange:) name:UVLanguageDidChangeNotification object:nil];
    }
    return self;
}

- (void)buildControls {
    NSView *content = self.window.contentView;
    self.languageLabel = UVSettingsLabel(@"", 13);
    self.languagePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.languagePicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.languagePicker.controlSize = NSControlSizeSmall;
    self.languagePicker.font = [NSFont systemFontOfSize:12];
    self.languagePicker.target = self;
    self.languagePicker.action = @selector(languageChanged:);
    self.languagePicker.accessibilityIdentifier = @"languagePicker";
    self.languagePickerWidth = [self.languagePicker.widthAnchor constraintEqualToConstant:176];
    self.loginLabel = UVSettingsLabel(@"", 13);
    self.loginLabel.maximumNumberOfLines = 2;
    self.loginLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.loginSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    self.loginSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginSwitch.target = self;
    self.loginSwitch.action = @selector(loginChanged:);
    self.loginSwitch.accessibilityIdentifier = @"launchAtLoginSwitch";
    self.loginStatusLabel = UVSettingsLabel(@"", 11);
    self.loginStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.loginStatusLabel.maximumNumberOfLines = 2;
    self.loginStatusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.loginSettingsButton = [NSButton buttonWithTitle:@"" target:self action:@selector(openLoginSettings:)];
    self.loginSettingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginSettingsButton.bezelStyle = NSBezelStyleRounded;
    self.loginSettingsButton.controlSize = NSControlSizeSmall;
    self.loginSettingsButton.accessibilityIdentifier = @"loginSettingsButton";
    self.feedbackCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(feedbackChanged:)];
    self.feedbackCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.feedbackCheckbox.accessibilityIdentifier = @"feedbackCheckbox";
    self.keyboardLabel = UVSettingsLabel(@"", 13);
    self.keyboardLabel.maximumNumberOfLines = 2;
    self.keyboardLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.keyboardStatusLabel = UVSettingsLabel(@"", 11);
    self.keyboardStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.keyboardStatusLabel.maximumNumberOfLines = 2;
    self.keyboardStatusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.keyboardPermissionButton = [NSButton buttonWithTitle:@"" target:self action:@selector(requestKeyboardPermission:)];
    self.keyboardPermissionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.keyboardPermissionButton.bezelStyle = NSBezelStyleRounded;
    self.keyboardPermissionButton.controlSize = NSControlSizeSmall;
    self.keyboardPermissionButton.accessibilityIdentifier = @"keyboardPermissionButton";
    self.aboutButton = [NSButton buttonWithTitle:@"" target:self action:@selector(aboutClicked:)];
    self.aboutButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.aboutButton.bezelStyle = NSBezelStyleRounded;
    self.aboutButton.controlSize = NSControlSizeSmall;
    self.aboutButton.accessibilityIdentifier = @"aboutButton";
    for (NSView *view in @[self.languageLabel, self.languagePicker, self.loginLabel, self.loginSwitch,
                          self.loginStatusLabel, self.loginSettingsButton, self.feedbackCheckbox,
                          self.keyboardLabel, self.keyboardStatusLabel, self.keyboardPermissionButton, self.aboutButton]) {
        [content addSubview:view];
    }
    for (NSButton *button in @[self.loginSettingsButton, self.keyboardPermissionButton, self.aboutButton]) {
        [button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    self.feedbackTop = [self.feedbackCheckbox.topAnchor constraintEqualToAnchor:self.loginLabel.bottomAnchor constant:24];
    [NSLayoutConstraint activateConstraints:@[
        [self.languageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.languageLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [self.languagePicker.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.languagePicker.centerYAnchor constraintEqualToAnchor:self.languageLabel.centerYAnchor],
        [self.languageLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.languagePicker.leadingAnchor constant:-16],
        self.languagePickerWidth,
        [self.loginLabel.leadingAnchor constraintEqualToAnchor:self.languageLabel.leadingAnchor],
        [self.loginLabel.topAnchor constraintEqualToAnchor:self.languageLabel.bottomAnchor constant:24],
        [self.loginSwitch.trailingAnchor constraintEqualToAnchor:self.languagePicker.trailingAnchor],
        [self.loginSwitch.centerYAnchor constraintEqualToAnchor:self.loginLabel.centerYAnchor],
        [self.loginLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.loginSwitch.leadingAnchor constant:-16],
        [self.loginStatusLabel.leadingAnchor constraintEqualToAnchor:self.loginLabel.leadingAnchor],
        [self.loginStatusLabel.topAnchor constraintEqualToAnchor:self.loginLabel.bottomAnchor constant:8],
        [self.loginStatusLabel.trailingAnchor constraintEqualToAnchor:self.loginSettingsButton.leadingAnchor constant:-8],
        [self.loginSettingsButton.trailingAnchor constraintEqualToAnchor:self.loginSwitch.trailingAnchor],
        [self.loginSettingsButton.centerYAnchor constraintEqualToAnchor:self.loginStatusLabel.centerYAnchor],
        [self.feedbackCheckbox.leadingAnchor constraintEqualToAnchor:self.loginLabel.leadingAnchor],
        [self.feedbackCheckbox.trailingAnchor constraintLessThanOrEqualToAnchor:self.languagePicker.trailingAnchor],
        self.feedbackTop,
        [self.keyboardLabel.leadingAnchor constraintEqualToAnchor:self.loginLabel.leadingAnchor],
        [self.keyboardLabel.topAnchor constraintEqualToAnchor:self.feedbackCheckbox.bottomAnchor constant:16],
        [self.keyboardLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.keyboardPermissionButton.leadingAnchor constant:-16],
        [self.keyboardStatusLabel.leadingAnchor constraintEqualToAnchor:self.loginLabel.leadingAnchor],
        [self.keyboardStatusLabel.topAnchor constraintEqualToAnchor:self.keyboardLabel.bottomAnchor constant:4],
        [self.keyboardStatusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.keyboardPermissionButton.leadingAnchor constant:-12],
        [self.keyboardPermissionButton.trailingAnchor constraintEqualToAnchor:self.loginSwitch.trailingAnchor],
        [self.keyboardPermissionButton.centerYAnchor constraintEqualToAnchor:self.keyboardLabel.centerYAnchor],
        [self.aboutButton.trailingAnchor constraintEqualToAnchor:self.loginSwitch.trailingAnchor],
        [self.aboutButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [self.aboutButton.topAnchor constraintGreaterThanOrEqualToAnchor:self.keyboardStatusLabel.bottomAnchor constant:12],
    ]];
}

- (void)applyLocalization {
    self.window.title = UVL(@"设置");
    self.languageLabel.stringValue = UVL(@"语言");
    self.languagePicker.accessibilityLabel = UVL(@"语言");
    self.loginLabel.stringValue = UVL(@"登录时自动启动");
    self.loginSwitch.accessibilityLabel = self.loginLabel.stringValue;
    self.loginSettingsButton.title = UVL(@"系统设置…");
    self.feedbackCheckbox.title = UVL(@"调节时播放提示音");
    self.feedbackCheckbox.accessibilityLabel = self.feedbackCheckbox.title;
    self.keyboardLabel.stringValue = UVL(@"键盘音量键");
    self.aboutButton.title = UVL(@"关于…");
    [self.languagePicker removeAllItems];
    [self.languagePicker addItemWithTitle:UVL(@"跟随系统")];
    self.languagePicker.lastItem.representedObject = @"";
    NSString *override = UVLanguageOverride() ?: @"";
    NSInteger selected = 0;
    for (NSDictionary *language in UVAvailableLanguages()) {
        NSString *code = language[@"code"];
        if (!code.length) continue;
        [self.languagePicker addItemWithTitle:language[@"nativeName"] ?: code];
        self.languagePicker.lastItem.representedObject = code;
        if ([code isEqualToString:override]) selected = self.languagePicker.numberOfItems - 1;
    }
    [self.languagePicker selectItemAtIndex:selected];
    NSUserInterfaceLayoutDirection direction = UVIsRightToLeft() ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight;
    NSView *content = self.window.contentView;
    content.userInterfaceLayoutDirection = direction;
    for (NSView *view in content.subviews) {
        view.userInterfaceLayoutDirection = direction;
        if ([view isKindOfClass:NSControl.class]) {
            NSControl *control = (NSControl *)view;
            control.cell.baseWritingDirection = UVIsRightToLeft() ? NSWritingDirectionRightToLeft : NSWritingDirectionLeftToRight;
            if ([control isKindOfClass:NSTextField.class]) control.alignment = NSTextAlignmentNatural;
        }
    }
    [self refreshPreferences];
    [self resizeForLocalizedContent];
}

- (void)resizeForLocalizedContent {
    CGFloat popupWidth = 176;
    NSDictionary *popupAttributes = @{NSFontAttributeName:self.languagePicker.font ?: [NSFont systemFontOfSize:12]};
    for (NSMenuItem *item in self.languagePicker.itemArray) {
        popupWidth = MAX(popupWidth, ceil([item.title sizeWithAttributes:popupAttributes].width) + 36);
    }
    self.languagePickerWidth.constant = MIN(240, popupWidth);
    CGFloat (^textWidth)(NSTextField *) = ^CGFloat(NSTextField *label) {
        return ceil([label.stringValue sizeWithAttributes:@{NSFontAttributeName:label.font}].width);
    };
    CGFloat width = 360;
    width = MAX(width, textWidth(self.languageLabel) + self.languagePickerWidth.constant + 48);
    width = MAX(width, textWidth(self.loginLabel) + self.loginSwitch.intrinsicContentSize.width + 48);
    width = MAX(width, self.feedbackCheckbox.intrinsicContentSize.width + 32);
    width = MAX(width, textWidth(self.keyboardLabel) + self.keyboardPermissionButton.intrinsicContentSize.width + 48);
    if (self.showsLoginDetail) {
        width = MAX(width, textWidth(self.loginStatusLabel) + self.loginSettingsButton.intrinsicContentSize.width + 40);
    }
    width = MIN(440, ceil(width));
    self.loginLabel.preferredMaxLayoutWidth = width - self.loginSwitch.intrinsicContentSize.width - 48;
    self.keyboardLabel.preferredMaxLayoutWidth = width - self.keyboardPermissionButton.intrinsicContentSize.width - 48;
    self.keyboardStatusLabel.preferredMaxLayoutWidth = width - self.keyboardPermissionButton.intrinsicContentSize.width - 44;
    self.loginStatusLabel.preferredMaxLayoutWidth = width - self.loginSettingsButton.intrinsicContentSize.width - 40;
    CGFloat extraHeight = 0;
    for (NSTextField *label in @[self.loginLabel, self.keyboardLabel, self.keyboardStatusLabel]) {
        NSDictionary *attributes = @{NSFontAttributeName:label.font};
        CGFloat oneLine = ceil([label.stringValue sizeWithAttributes:attributes].height);
        CGFloat wrapped = ceil([label.stringValue boundingRectWithSize:NSMakeSize(label.preferredMaxLayoutWidth, CGFLOAT_MAX)
                                                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                            attributes:attributes].size.height);
        extraHeight += MAX(0, wrapped - oneLine);
    }
    NSSize size = NSMakeSize(width, 232 + (self.showsLoginDetail ? 32 : 0) + extraHeight);
    if (!NSEqualSizes(self.window.contentView.bounds.size, size)) {
        NSRect oldFrame = self.window.frame;
        [self.window setContentSize:size];
        NSRect frame = self.window.frame;
        frame.origin.x = NSMidX(oldFrame) - frame.size.width / 2;
        frame.origin.y = NSMaxY(oldFrame) - frame.size.height;
        [self.window setFrame:frame display:self.window.visible];
    }
    self.window.contentView.needsUpdateConstraints = YES;
    [self.window.contentView layoutSubtreeIfNeeded];
}

- (void)languageChanged:(NSPopUpButton *)sender {
    NSString *code = sender.selectedItem.representedObject ?: @"";
    UVSetLanguageOverride(code);
}

- (void)languageDidChange:(NSNotification *)notification {
    (void)notification;
    if (NSThread.isMainThread) [self applyLocalization];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self applyLocalization]; });
}

- (void)show {
    [self refreshPreferences];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)refreshPreferences {
    // Reading status never registers a login item or requests authorization.
    SMAppServiceStatus status = self.loginService.status;
    if (self.hasLoginStatus && status != self.lastLoginStatus && !self.updatingLogin) self.loginError = @"";
    self.lastLoginStatus = status;
    self.hasLoginStatus = YES;
    // Pending services are already registered; keep the switch cancellable.
    BOOL registered = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval;
    self.loginSwitch.state = registered ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginSwitch.enabled = !self.updatingLogin;
    self.loginSettingsButton.hidden = status != SMAppServiceStatusRequiresApproval;
    self.loginSettingsButton.enabled = !self.updatingLogin;
    if (self.updatingLogin) {
        self.loginStatusLabel.stringValue = UVL(@"正在更新…");
        self.loginStatusLabel.toolTip = nil;
    } else if (status == SMAppServiceStatusRequiresApproval) {
        self.loginStatusLabel.stringValue = UVL(@"待系统允许，尚未生效");
        self.loginStatusLabel.toolTip = UVL(@"系统尚未允许登录时启动。");
    } else if (self.loginError.length) {
        self.loginStatusLabel.stringValue = UVL(@"无法更新，请重试");
        self.loginStatusLabel.toolTip = self.loginError;
    } else {
        // A service never registered with the system can also report NotFound.
        // Registration errors are shown only after an actual user request fails.
        self.loginStatusLabel.stringValue = status == SMAppServiceStatusEnabled ? UVL(@"已开启") : UVL(@"未开启");
        self.loginStatusLabel.toolTip = nil;
    }
    self.showsLoginDetail = self.updatingLogin || status == SMAppServiceStatusRequiresApproval || self.loginError.length > 0;
    self.loginStatusLabel.hidden = !self.showsLoginDetail;
    self.loginSwitch.toolTip = self.loginStatusLabel.stringValue;
    self.feedbackTop.constant = self.showsLoginDetail ? 56 : 24;
    [self refreshFeedbackPreference];
    [self refreshKeyboardStatus];
    [self resizeForLocalizedContent];
}

- (void)refreshFeedbackPreference {
    NSNumber *feedback = [NSUserDefaults.standardUserDefaults objectForKey:UVSettingsFeedbackKey];
    self.feedbackCheckbox.state = (!feedback || feedback.boolValue) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)loginChanged:(NSSwitch *)sender {
    if (self.updatingLogin) return;
    BOOL shouldEnable = sender.state == NSControlStateValueOn;
    SMAppServiceStatus status = self.loginService.status;
    self.loginError = @"";
    if (shouldEnable && status == SMAppServiceStatusRequiresApproval) {
        [self refreshPreferences];
        [SMAppService openSystemSettingsLoginItems];
        return;
    }
    if ((shouldEnable && status == SMAppServiceStatusEnabled) ||
        (!shouldEnable && status == SMAppServiceStatusNotRegistered)) {
        [self refreshPreferences];
        return;
    }
    self.updatingLogin = YES;
    [self refreshPreferences];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = shouldEnable ? [self.loginService registerAndReturnError:&error]
                                    : [self.loginService unregisterAndReturnError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.updatingLogin = NO;
            self.loginError = success ? @"" : (error.localizedDescription ?: UVL(@"系统未能更新登录启动设置。"));
            [self refreshPreferences];
        });
    });
}

- (void)openLoginSettings:(id)sender {
    (void)sender;
    [SMAppService openSystemSettingsLoginItems];
}

- (void)feedbackChanged:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:UVSettingsFeedbackKey];
    if (self.feedbackChanged) self.feedbackChanged();
}

- (void)updateKeyboardActive:(BOOL)active needsPermission:(BOOL)needsPermission {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateKeyboardActive:active needsPermission:needsPermission]; });
        return;
    }
    self.keyboardActive = active;
    self.keyboardNeedsPermission = needsPermission;
    [self refreshKeyboardStatus];
}

- (void)refreshKeyboardStatus {
    self.keyboardStatusLabel.stringValue = self.keyboardActive ? UVL(@"已启用") : self.keyboardNeedsPermission ? UVL(@"需要系统授权") : UVL(@"暂未启用");
    self.keyboardPermissionButton.hidden = self.keyboardActive;
    self.keyboardPermissionButton.title = self.keyboardNeedsPermission ? UVL(@"授权…") : UVL(@"重试");
    self.keyboardPermissionButton.accessibilityLabel = self.keyboardPermissionButton.title;
}

- (void)requestKeyboardPermission:(id)sender {
    (void)sender;
    if (self.keyboardPermissionRequested) self.keyboardPermissionRequested();
}

- (void)showAbout {
    [NSApp activateIgnoringOtherApps:YES];
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    NSString *displayVersion = build.length && ![build isEqualToString:version]
        ? [NSString stringWithFormat:@"%@ (%@)", version, build] : version;
    NSDictionary *options = @{
        NSAboutPanelOptionApplicationName:UVL(@"USB 音量"),
        NSAboutPanelOptionApplicationVersion:[NSString stringWithFormat:UVL(@"版本 %@"), displayVersion],
        NSAboutPanelOptionVersion:@"",
        @"Copyright":[NSString stringWithFormat:@"%@ · %@", UVL(@"USB 音量"), UVL(@"本机音频控制")],
    };
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)aboutClicked:(id)sender { (void)sender; [self showAbout]; }

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    [self refreshPreferences];
}

- (void)defaultsChanged:(NSNotification *)notification {
    (void)notification;
    // Volume drags also write defaults; avoid ServiceManagement IPC on those events.
    if (NSThread.isMainThread) [self refreshFeedbackPreference];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFeedbackPreference]; });
}

- (void)windowDidBecomeKey:(NSNotification *)notification { (void)notification; [self refreshPreferences]; }

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
