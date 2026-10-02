#import <AppKit/AppKit.h>
#import "AudioController.h"
#import "Symbols.h"
#import "MediaKeys.h"
#import "SettingsController.h"
#import "StatusServer.h"
#import "Localization.h"
#include <math.h>

static NSString *const UVVolumePreference = @"USBVolume.volume";
static NSString *const UVDevicePreference = @"USBVolume.deviceUID";
static NSString *const UVMutePreference = @"USBVolume.muted";
static NSString *const UVFeedbackPreference = @"USBVolume.feedback";
static NSString *const UVShowNotification = @"local.lee.USBVolume.showPopover";

@interface UVSlider : NSSlider
@property(nonatomic) BOOL trackingGesture;
@property(nonatomic) BOOL changedDuringGesture;
@property(nonatomic) NSUInteger mouseDownCount;
@property(nonatomic, copy) dispatch_block_t gestureEnded;
@end
@implementation UVSlider
- (BOOL)becomeFirstResponder {
    self.focusRingType = NSApp.currentEvent.type == NSEventTypeKeyDown ? NSFocusRingTypeDefault : NSFocusRingTypeNone;
    return [super becomeFirstResponder];
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    self.mouseDownCount++;
    self.focusRingType = NSFocusRingTypeNone;
    [self.window makeFirstResponder:self];
    self.trackingGesture = YES;
    self.changedDuringGesture = NO;
    // Let the native cell own geometry, drawing, hit testing and drag tracking.
    [super mouseDown:event];
    self.trackingGesture = NO;
    if (self.changedDuringGesture && self.gestureEnded) self.gestureEnded();
}
- (void)setUserValue:(double)value {
    if (!self.enabled) return;
    double clamped = fmax(self.minValue, fmin(self.maxValue, value));
    if (fabs(clamped - self.doubleValue) < 0.0001) return;
    self.doubleValue = clamped;
    [self sendAction:self.action to:self.target];
    self.needsDisplay = YES;
}
- (void)keyDown:(NSEvent *)event {
    self.focusRingType = NSFocusRingTypeDefault;
    NSString *characters = event.charactersIgnoringModifiers;
    if (!characters.length) { [super keyDown:event]; return; }
    unichar key = [characters characterAtIndex:0];
    double step = (event.modifierFlags & NSEventModifierFlagShift) ? 10 : 1;
    BOOL handled = YES;
    switch (key) {
        case NSLeftArrowFunctionKey: case NSDownArrowFunctionKey: [self setUserValue:self.doubleValue - step]; break;
        case NSRightArrowFunctionKey: case NSUpArrowFunctionKey: [self setUserValue:self.doubleValue + step]; break;
        case NSHomeFunctionKey: [self setUserValue:self.minValue]; break;
        case NSEndFunctionKey: [self setUserValue:self.maxValue]; break;
        case 0x1b: [self.window cancelOperation:self]; break;
        default: handled = NO; break;
    }
    self.needsDisplay = YES;
    if (!handled) [super keyDown:event];
}
- (void)scrollWheel:(NSEvent *)event {
    if (!self.enabled) return;
    CGFloat delta = fabs(event.scrollingDeltaX) > fabs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY;
    [self setUserValue:self.doubleValue + delta * (event.hasPreciseScrollingDeltas ? 0.15 : 1)];
}

@end

@interface UVContentView : NSVisualEffectView
@end
@implementation UVContentView
- (BOOL)isFlipped { return YES; }
@end

@interface UVPanel : NSPanel
@property(nonatomic, copy) dispatch_block_t dismissed;
@end
@implementation UVPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender { (void)sender; if (self.dismissed) self.dismissed(); }
@end

@interface UVAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic) UVAudioController *audio;
@property(nonatomic) UVMediaKeys *mediaKeys;
@property(nonatomic) UVSettingsController *settingsController;
@property(nonatomic) UVStatusServer *statusServer;
@property(nonatomic) NSUInteger mediaKeyActionCount;
@property(nonatomic) NSUInteger mediaChangedKeys;
@property(nonatomic) BOOL mediaKeyRouteOwned;
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) UVPanel *panel;
@property(nonatomic) UVContentView *panelContent;
@property(nonatomic) id localClickMonitor;
@property(nonatomic) id globalClickMonitor;
@property(nonatomic) UVSlider *volumeSlider;
@property(nonatomic) NSButton *muteButton;
@property(nonatomic) NSTextField *errorLabel;
@property(nonatomic) NSButton *retryButton;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSTimer *feedbackTimer;
@property(nonatomic) NSArray<NSDictionary *> *knownDevices;
@property(nonatomic, copy) NSString *selectedUID;
@property(nonatomic, copy) NSString *diagnosticPath;
@property(nonatomic) NSUInteger tick;
@property(nonatomic) NSUInteger feedbackCount;
@property(nonatomic) NSUInteger sliderCommitCount;
@property(nonatomic) NSUInteger volumeActionCount;
@property(nonatomic) BOOL performingStart;
@property(nonatomic) BOOL quitting;
@property(nonatomic) BOOL smokeTest;
@property(nonatomic) BOOL showOnLaunch;
@property(nonatomic) BOOL reconnectWanted;
@property(nonatomic) BOOL selectedWasPresent;
@end

@implementation UVAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{UVFeedbackPreference:@YES, UVMutePreference:@NO}];
    self.audio = [[UVAudioController alloc] init];
    NSNumber *saved = [defaults objectForKey:UVVolumePreference];
    float initialVolume = saved ? saved.floatValue : 0.2f;
    self.audio.volume = isfinite(initialVolume) ? fminf(1, fmaxf(0, initialVolume)) : 0.2f;
    self.audio.muted = [defaults boolForKey:UVMutePreference];
    self.selectedUID = [defaults stringForKey:UVDevicePreference];
    self.reconnectWanted = !self.smokeTest;
    __weak UVAppDelegate *weakSelf = self;
    self.mediaKeys = [[UVMediaKeys alloc] init];
    // Event-tap callbacks must not wait on Core Audio IPC or redraw the UI.
    self.mediaKeys.shouldHandle = ^BOOL{ return weakSelf.mediaKeyRouteOwned; };
    self.mediaKeys.handler = ^(UVMediaKey key, BOOL fine) { [weakSelf mediaKeyPressed:key fine:fine]; };
    self.mediaKeys.releaseHandler = ^(UVMediaKey key) { [weakSelf mediaKeyReleased:key]; };
    if (!self.smokeTest) [self.mediaKeys start];
    self.audio.stateChanged = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateUI]; });
    };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageChanged:) name:UVLanguageDidChangeNotification object:nil];
    [self installMenu];
    [self buildPanel];
    [self refreshDevices];
    [self updateUI];
    self.statusServer = [[UVStatusServer alloc] init];
    self.statusServer.reportProvider = ^NSDictionary *{ return [weakSelf statusReport]; };
    [self.statusServer start];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(reopen:) name:UVShowNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    if (!self.smokeTest && self.selectedWasPresent) [self startAudio];
    if (self.showOnLaunch) dispatch_async(dispatch_get_main_queue(), ^{ [self showPopover]; });
}

- (void)languageChanged:(NSNotification *)notification {
    (void)notification;
    [self installMenu];
    [self updateUI];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    UVRefreshLanguage();
}

- (void)installMenu {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:UVL(@"USB 音量")];
    [appMenu addItem:[self menuItem:UVL(@"关于 USB 音量") action:@selector(showAbout:)]];
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings = [self menuItem:UVL(@"设置…") action:@selector(showSettings:)];
    settings.keyEquivalent = @",";
    [appMenu addItem:settings];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:UVL(@"退出 USB 音量") action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [main addItem:appItem];
    NSApp.mainMenu = main;
    if (!self.statusItem) self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:30];
    self.statusItem.button.image = UVStatusImage(self.audio.muted);
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    self.statusItem.button.accessibilityLabel = UVL(@"USB 音量");
}

- (void)buildPanel {
    self.panel = [[UVPanel alloc] initWithContentRect:NSMakeRect(0, 0, 216, 40)
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = UVL(@"USB 音量");
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.level = NSStatusWindowLevel;
    self.panel.hidesOnDeactivate = NO; // Explicit dismissal avoids NSPanel auto-restoring after activation.
    self.panel.releasedWhenClosed = NO;
    self.panel.animationBehavior = NSWindowAnimationBehaviorNone;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.delegate = self;
    self.panelContent = [[UVContentView alloc] initWithFrame:NSMakeRect(0, 0, 216, 40)];
    self.panelContent.material = NSVisualEffectMaterialPopover;
    self.panelContent.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.panelContent.state = NSVisualEffectStateActive;
    self.panelContent.wantsLayer = YES;
    self.panelContent.layer.cornerRadius = 10;
    self.panelContent.layer.masksToBounds = YES;
    self.panel.contentView = self.panelContent;
    self.volumeSlider = [[UVSlider alloc] initWithFrame:NSMakeRect(39, 4, 165, 32)];
    self.volumeSlider.controlSize = NSControlSizeRegular;
    self.volumeSlider.focusRingType = NSFocusRingTypeNone;
    self.volumeSlider.minValue = 0;
    self.volumeSlider.maxValue = 100;
    self.volumeSlider.doubleValue = self.audio.volume * 100;
    self.volumeSlider.continuous = YES;
    self.volumeSlider.target = self;
    self.volumeSlider.action = @selector(volumeChanged:);
    self.volumeSlider.accessibilityLabel = UVL(@"音量");
    self.volumeSlider.accessibilityIdentifier = @"volumeSlider";
    __weak UVAppDelegate *weakSelf = self;
    self.volumeSlider.gestureEnded = ^{ [weakSelf commitSliderGesture]; };
    self.panel.dismissed = ^{ [weakSelf closePanel]; };
    [self.panelContent addSubview:self.volumeSlider];
    self.muteButton = [[NSButton alloc] initWithFrame:NSMakeRect(5, 6, 28, 28)];
    self.muteButton.bordered = NO;
    self.muteButton.title = @"";
    self.muteButton.imagePosition = NSImageOnly;
    self.muteButton.imageScaling = NSImageScaleProportionallyDown;
    self.muteButton.contentTintColor = NSColor.labelColor;
    self.muteButton.target = self;
    self.muteButton.action = @selector(toggleMute:);
    self.muteButton.accessibilityIdentifier = @"muteButton";
    [self.panelContent addSubview:self.muteButton];
    self.errorLabel = [NSTextField labelWithString:@""];
    self.errorLabel.frame = NSMakeRect(10, 47, 164, 18);
    self.errorLabel.font = [NSFont systemFontOfSize:11];
    self.errorLabel.textColor = NSColor.secondaryLabelColor;
    self.errorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.panelContent addSubview:self.errorLabel];
    self.retryButton = [NSButton buttonWithTitle:UVL(@"重试") target:self action:@selector(retry:)];
    self.retryButton.frame = NSMakeRect(186, 41, 44, 28);
    self.retryButton.bezelStyle = NSBezelStyleRounded;
    self.retryButton.controlSize = NSControlSizeSmall;
    [self.panelContent addSubview:self.retryButton];
    self.localClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^NSEvent *(NSEvent *event) {
        UVAppDelegate *self = weakSelf;
        if (self.panel.visible && event.window != self.panel && event.window != self.statusItem.button.window) [self closePanel];
        return event;
    }];
    self.globalClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^(NSEvent *event) {
        (void)event;
        UVAppDelegate *self = weakSelf;
        NSStatusBarButton *button = self.statusItem.button;
        NSRect statusRect = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
        NSPoint cursor = NSEvent.mouseLocation;
        if (NSPointInRect(cursor, statusRect) || NSPointInRect(cursor, self.panel.frame)) return;
        [self closePanel];
    }];
}

- (NSDictionary *)selectedDevice {
    for (NSDictionary *device in self.knownDevices) if ([device[@"uid"] isEqualToString:self.selectedUID]) return device;
    return nil;
}

- (void)refreshDevices {
    self.knownDevices = [self.audio devices] ?: @[];
    // Never silently move a remembered USB route to a display or built-in speaker.
    if (!self.selectedUID.length) {
        for (NSDictionary *device in self.knownDevices) {
            if ([device[@"name"] caseInsensitiveCompare:@"MOONDROP MM3A"] == NSOrderedSame) {
                self.selectedUID = device[@"uid"];
                [NSUserDefaults.standardUserDefaults setObject:self.selectedUID forKey:UVDevicePreference];
                break;
            }
        }
    }
    BOOL present = [self selectedDevice] != nil;
    BOOL reappeared = !self.selectedWasPresent && present;
    self.selectedWasPresent = present;
    if (self.tick > 0 && reappeared && self.reconnectWanted && !self.audio.running && !self.performingStart) [self startAudio];
}

- (NSString *)shortStatus {
    if (self.performingStart) return UVL(@"正在连接…");
    if (![self selectedDevice]) return self.selectedUID.length ? UVL(@"音箱未连接") : UVL(@"请选择输出设备");
    if (self.audio.running) return self.audio.muted ? UVL(@"已静音") : [NSString stringWithFormat:@"%.0f%%", self.audio.volume * 100];
    NSString *error = self.audio.lastErrorKey;
    if (error.length) {
        if ([error containsString:@"eqMac 正在接管"] || [error containsString:@"请先退出 eqMac"])
            return UVL(@"连接失败，点重试");
        if ([error containsString:@"系统音频录制"] && [error containsString:@"允许"])
            return UVL(@"请允许系统音频录制");
        return UVL(@"连接失败，点重试");
    }
    return UVL(@"音量控制已暂停");
}

- (void)updateUI {
    if (!self.panel) return;
    BOOL running = self.audio.running;
    self.mediaKeyRouteOwned = self.audio.ownsDefaultOutput;
    self.mediaKeys.enabled = running;
    [self.settingsController updateKeyboardActive:self.mediaKeys.active needsPermission:self.mediaKeys.needsPermission];
    if (!running) self.mediaChangedKeys = 0;
    BOOL editable = running || self.smokeTest;
    if (!self.volumeSlider.trackingGesture) self.volumeSlider.doubleValue = self.audio.volume * 100;
    self.volumeSlider.enabled = editable;
    self.muteButton.enabled = editable;
    self.panel.title = UVL(@"USB 音量");
    self.volumeSlider.accessibilityLabel = UVL(@"音量");
    self.statusItem.button.accessibilityLabel = UVL(@"USB 音量");
    self.volumeSlider.toolTip = [NSString stringWithFormat:UVL(@"音量 %.0f%%"), self.audio.volume * 100];
    self.volumeSlider.needsDisplay = YES;
    BOOL silent = self.audio.muted || self.audio.volume == 0;
    NSString *symbol = silent ? @"speaker.slash.fill" : self.audio.volume < 0.34f ? @"speaker.wave.1.fill" : @"speaker.wave.2.fill";
    NSImage *speaker = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.muteButton.image = [speaker imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
    self.muteButton.accessibilityLabel = self.audio.muted ? UVL(@"取消静音") : UVL(@"静音");
    self.muteButton.toolTip = self.muteButton.accessibilityLabel;
    NSString *status = [self shortStatus];
    self.statusItem.button.image = UVStatusImage(silent);
    NSString *deviceName = [self selectedDevice][@"name"] ?: UVL(@"USB 音量");
    self.statusItem.button.toolTip = [NSString stringWithFormat:UVL(@"%@ · %@\n点击调音量，右键更多选项"), deviceName, status];
    self.statusItem.button.accessibilityValue = status;
    BOOL needsStatus = !running && !self.smokeTest;
    self.panelContent.needsDisplay = YES;
    self.errorLabel.hidden = !needsStatus;
    self.retryButton.hidden = !needsStatus;
    self.errorLabel.stringValue = status;
    self.errorLabel.toolTip = self.audio.lastError.length ? self.audio.lastError : status;
    self.retryButton.title = [self selectedDevice] ? UVL(@"重试") : UVL(@"设备");
    self.retryButton.enabled = !self.performingStart;
    CGFloat retryWidth = MAX(44, self.retryButton.intrinsicContentSize.width);
    CGFloat panelWidth = needsStatus ? MAX(244, retryWidth + 190) : 216;
    self.errorLabel.frame = NSMakeRect(10, 47, panelWidth - retryWidth - 28, 18);
    self.retryButton.frame = NSMakeRect(panelWidth - retryWidth - 8, 41, retryWidth, 28);
    NSSize wantedSize = NSMakeSize(panelWidth, needsStatus ? 72 : 40);
    if (!NSEqualSizes(self.panel.contentView.bounds.size, wantedSize)) {
        [self.panel setContentSize:wantedSize];
        if (self.panel.visible) [self positionPanel];
        self.panelContent.needsDisplay = YES;
    }
    [self writeDiagnostics];
}

- (void)poll:(NSTimer *)timer {
    (void)timer;
    self.tick++;
    if (self.tick % 4 == 0 && !self.performingStart) [self refreshDevices];
    if (self.tick % 4 == 0 && !self.smokeTest && !self.mediaKeys.active) [self.mediaKeys start];
    if (self.panel.visible && !self.volumeSlider.trackingGesture) [self positionPanel];
    [self updateUI];
}

- (void)saveVolumeState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setFloat:self.audio.volume forKey:UVVolumePreference];
    [defaults setBool:self.audio.muted forKey:UVMutePreference];
}

- (void)enableMediaKeys:(id)sender {
    (void)sender;
    [self.mediaKeys requestPermission];
    [self.mediaKeys start];
    [self updateUI];
}

- (void)prepareSettings {
    if (self.settingsController) return;
    self.settingsController = [[UVSettingsController alloc] init];
    __weak UVAppDelegate *weakSelf = self;
    self.settingsController.feedbackChanged = ^{
        [weakSelf.feedbackTimer invalidate];
        weakSelf.feedbackTimer = nil;
        [weakSelf writeDiagnostics];
    };
    self.settingsController.keyboardPermissionRequested = ^{ [weakSelf enableMediaKeys:nil]; };
    [self.settingsController updateKeyboardActive:self.mediaKeys.active needsPermission:self.mediaKeys.needsPermission];
}

- (void)showSettings:(id)sender {
    (void)sender;
    [self closePanel];
    [self prepareSettings];
    [self.settingsController show];
}

- (void)showAbout:(id)sender {
    (void)sender;
    [self closePanel];
    [self prepareSettings];
    [self.settingsController showAbout];
}

- (void)showVolume:(id)sender {
    (void)sender;
    // Wait until the menu closes before opening the volume panel.
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPopover]; });
}

- (void)mediaKeyPressed:(UVMediaKey)key fine:(BOOL)fine {
    if (!self.audio.ownsDefaultOutput) return;
    [self.feedbackTimer invalidate];
    self.feedbackTimer = nil;
    self.mediaKeyActionCount++;
    if (key == UVMediaKeyMute) {
        [self toggleMute:nil];
        return;
    }
    float step = fine ? 1.0f / 64.0f : 1.0f / 16.0f;
    float next = fminf(1, fmaxf(0, self.audio.volume + (key == UVMediaKeyUp ? step : -step)));
    if (fabsf(next - self.audio.volume) > 0.00001f || self.audio.muted) {
        self.mediaChangedKeys |= (1UL << key);
        self.audio.volume = next;
        self.audio.muted = NO;
        [self saveVolumeState];
        [self updateUI];
    }
}

- (void)mediaKeyReleased:(UVMediaKey)key {
    if (key == UVMediaKeyMute) return;
    NSUInteger bit = 1UL << key;
    if (!(self.mediaChangedKeys & bit)) return;
    self.mediaChangedKeys &= ~bit;
    if (self.audio.ownsDefaultOutput) [self playFeedback];
}

- (void)volumeChanged:(id)sender {
    (void)sender;
    self.volumeActionCount++;
    if (self.volumeSlider.trackingGesture) self.volumeSlider.changedDuringGesture = YES;
    self.audio.volume = self.volumeSlider.floatValue / 100;
    self.audio.muted = NO;
    [self saveVolumeState];
    [self.feedbackTimer invalidate];
    self.feedbackTimer = nil;
    // Keyboard and accessibility changes have no mouse-up event; settle before previewing.
    if (!self.volumeSlider.trackingGesture) {
        self.feedbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 target:self selector:@selector(feedbackTimerFired:) userInfo:nil repeats:NO];
    }
    [self updateUI];
}

- (void)feedbackTimerFired:(NSTimer *)timer {
    (void)timer;
    self.feedbackTimer = nil;
    [self commitSliderGesture];
}

- (void)commitSliderGesture {
    self.sliderCommitCount++;
    [self playFeedback];
    [self writeDiagnostics];
}

- (void)playFeedback {
    if (![NSUserDefaults.standardUserDefaults boolForKey:UVFeedbackPreference] || !self.audio.running || self.audio.muted || self.audio.volume <= 0) return;
    [self.audio playFeedback];
    self.feedbackCount++;
    [self writeDiagnostics];
}

- (void)toggleMute:(id)sender {
    (void)sender;
    [self.feedbackTimer invalidate];
    self.feedbackTimer = nil;
    self.audio.muted = !self.audio.muted;
    [self saveVolumeState];
    [self updateUI];
}

- (void)startAudio {
    if (self.performingStart || self.audio.running || ![self selectedDevice]) return;
    self.performingStart = YES;
    NSString *uid = self.selectedUID;
    [self updateUI];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        [self.audio startDeviceUID:uid error:&error];
        self.performingStart = NO;
        [self updateUI];
    });
}

- (void)retry:(id)sender {
    (void)sender;
    [self refreshDevices];
    if (![self selectedDevice]) { [self showOptionsMenu]; return; }
    self.reconnectWanted = YES;
    [self startAudio];
}

- (void)chooseDevice:(NSMenuItem *)sender {
    NSString *uid = sender.representedObject;
    if (!uid.length || ([uid isEqualToString:self.selectedUID] && self.audio.running)) return;
    [self.audio stop];
    self.selectedUID = uid;
    [NSUserDefaults.standardUserDefaults setObject:uid forKey:UVDevicePreference];
    self.selectedWasPresent = YES;
    self.reconnectWanted = YES;
    [self startAudio];
}

- (void)toggleFeedback:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:UVFeedbackPreference] forKey:UVFeedbackPreference];
    [self writeDiagnostics];
}

- (BOOL)confirmRestoringOutputForQuit:(BOOL)quit {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = quit ? UVL(@"退出音量控制？") : UVL(@"暂停音量控制？");
    alert.informativeText = UVL(@"音箱将恢复原始音量，请先暂停播放。");
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:UVL(@"取消")];
    [alert addButtonWithTitle:quit ? UVL(@"退出") : UVL(@"暂停")];
    [NSApp activateIgnoringOtherApps:YES];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

- (void)toggleAudio:(id)sender {
    (void)sender;
    if (self.audio.running) {
        if (![self confirmRestoringOutputForQuit:NO]) return;
        self.reconnectWanted = NO;
        [self.audio stop];
    } else {
        self.reconnectWanted = YES;
        [self startAudio];
    }
    [self updateUI];
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)showOptionsMenu {
    [self closePanel];
    [self refreshDevices];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:UVL(@"USB 音量")];
    menu.autoenablesItems = NO;
    NSString *volumeTitle = self.audio.running ? [NSString stringWithFormat:UVL(@"音量 %.0f%%%@"), self.audio.volume * 100, self.audio.muted ? UVL(@" · 已静音") : @""] : [self shortStatus];
    NSMenuItem *status = [self menuItem:volumeTitle action:@selector(showVolume:)];
    status.toolTip = self.audio.lastError;
    [menu addItem:status];
    NSMenuItem *devices = [[NSMenuItem alloc] initWithTitle:UVL(@"输出设备") action:nil keyEquivalent:@""];
    NSMenu *deviceMenu = [[NSMenu alloc] initWithTitle:UVL(@"输出设备")];
    deviceMenu.autoenablesItems = NO;
    for (NSDictionary *device in self.knownDevices) {
        NSMenuItem *item = [self menuItem:device[@"name"] action:@selector(chooseDevice:)];
        item.representedObject = device[@"uid"];
        item.state = [device[@"uid"] isEqualToString:self.selectedUID] ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = !self.performingStart;
        [deviceMenu addItem:item];
    }
    if (!deviceMenu.numberOfItems) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:UVL(@"未找到输出设备") action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [deviceMenu addItem:empty];
    }
    devices.submenu = deviceMenu;
    [menu addItem:devices];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings = [self menuItem:UVL(@"设置…") action:@selector(showSettings:)];
    settings.keyEquivalent = @",";
    [menu addItem:settings];
    NSMenuItem *control = [self menuItem:self.audio.running ? UVL(@"暂停控制") : UVL(@"重新连接") action:@selector(toggleAudio:)];
    control.enabled = !self.performingStart && [self selectedDevice] != nil;
    [menu addItem:control];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:UVL(@"退出 USB 音量") action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItem:quit];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(self.statusItem.button.bounds) + 4) inView:self.statusItem.button];
}

- (void)positionPanel {
    // App activation can rearrange menu-bar items; never move beneath a drag.
    if (self.volumeSlider.trackingGesture) return;
    NSStatusBarButton *button = self.statusItem.button;
    if (!button.window) return;
    NSRect anchor = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
    NSScreen *screen = button.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSSize size = self.panel.frame.size;
    CGFloat x = NSMidX(anchor) - size.width / 2;
    x = fmax(NSMinX(visible) + 8, fmin(NSMaxX(visible) - size.width - 8, x));
    CGFloat y = fmin(NSMinY(anchor), NSMaxY(visible)) - size.height - 6;
    [self.panel setFrameOrigin:NSMakePoint(x, y)];
}

- (void)showPopover {
    if (!self.statusItem.button) return;
    [self updateUI];
    [self positionPanel];
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.volumeSlider];
    self.volumeSlider.focusRingType = NSFocusRingTypeNone;
    // Status-item layout settles after activation, not necessarily in this turn.
    __weak UVAppDelegate *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UVAppDelegate *self = weakSelf;
        if (self.panel.visible) { [self positionPanel]; [self writeDiagnostics]; }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UVAppDelegate *self = weakSelf;
        if (self.panel.visible) { [self positionPanel]; [self writeDiagnostics]; }
    });
    [self writeDiagnostics];
}

- (void)closePanel {
    if (!self.panel.visible) return;
    [self.panel orderOut:nil];
    [self writeDiagnostics];
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) [self showOptionsMenu];
    else if (self.panel.visible) [self closePanel];
    else [self showPopover];
}

- (BOOL)isStatusItemMouseEvent {
    NSEvent *event = NSApp.currentEvent;
    if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeRightMouseDown &&
        event.type != NSEventTypeLeftMouseUp && event.type != NSEventTypeRightMouseUp) return NO;
    NSStatusBarButton *button = self.statusItem.button;
    NSRect rect = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
    return NSPointInRect(NSEvent.mouseLocation, rect);
}

- (void)windowDidResignKey:(NSNotification *)notification {
    // The status button's mouse-up action owns toggling; don't close on mouse-down.
    if (notification.object == self.panel && ![self isStatusItemMouseEvent]) [self closePanel];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    (void)notification;
    [self closePanel];
}

- (void)reopen:(NSNotification *)notification { (void)notification; [self showPopover]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return NO; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender; (void)flag;
    [self showPopover];
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.audio.running && !self.quitting && ![self confirmRestoringOutputForQuit:YES]) return NSTerminateCancel;
    self.quitting = YES;
    [self.audio stop];
    [self writeDiagnostics];
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
    [self.feedbackTimer invalidate];
    if (self.localClickMonitor) [NSEvent removeMonitor:self.localClickMonitor];
    if (self.globalClickMonitor) [NSEvent removeMonitor:self.globalClickMonitor];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.audio.stateChanged = nil;
    [self.mediaKeys stop];
    [self.statusServer stop];
    [self.audio stop];
}

- (NSDictionary *)statusReport {
    NSMutableDictionary *report = [[self.audio diagnostics] mutableCopy] ?: [NSMutableDictionary dictionary];
    report[@"pid"] = @(NSProcessInfo.processInfo.processIdentifier);
    report[@"version"] = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"development";
    report[@"language"] = UVCurrentLanguage();
    report[@"languageOverride"] = UVLanguageOverride();
    report[@"mediaKeys"] = self.mediaKeys.diagnostics ?: @{};
    NSDictionary *(^rectJSON)(NSRect) = ^NSDictionary *(NSRect rect) {
        return @{@"x":@(rect.origin.x), @"y":@(rect.origin.y), @"width":@(rect.size.width), @"height":@(rect.size.height)};
    };
    NSWindow *sliderWindow = self.volumeSlider.window;
    NSRect sliderScreenRect = sliderWindow ? [sliderWindow convertRectToScreen:[self.volumeSlider convertRect:self.volumeSlider.bounds toView:nil]] : NSZeroRect;
    NSRect knobRect = [self.volumeSlider.cell knobRectFlipped:self.volumeSlider.flipped];
    NSRect knobScreenRect = sliderWindow ? [sliderWindow convertRectToScreen:[self.volumeSlider convertRect:knobRect toView:nil]] : NSZeroRect;
    NSWindow *statusWindow = self.statusItem.button.window;
    NSRect statusScreenRect = statusWindow ? [statusWindow convertRectToScreen:[self.statusItem.button convertRect:self.statusItem.button.bounds toView:nil]] : NSZeroRect;
    NSScreen *screen = sliderWindow.screen ?: statusWindow.screen ?: NSScreen.mainScreen;
    report[@"ui"] = @{
        @"mediaKeysActive":@(self.mediaKeys.active), @"mediaKeysNeedPermission":@(self.mediaKeys.needsPermission),
        @"mediaKeyActionCount":@(self.mediaKeyActionCount),
        @"settingsVisible":@(self.settingsController.window.visible),
        @"mode":@"menu-bar", @"activationPolicy":@(NSApp.activationPolicy),
        @"sliderScreenRect":rectJSON(sliderScreenRect), @"sliderKnobScreenRect":rectJSON(knobScreenRect),
        @"panelScreenRect":rectJSON(self.panel.frame), @"screenFrame":rectJSON(screen.frame),
        @"statusItemScreenRect":rectJSON(statusScreenRect), @"statusIconFrame":rectJSON(statusScreenRect),
        @"selectedUID":self.selectedUID ?: @"", @"selectedDevicePresent":@([self selectedDevice] != nil),
        @"volumePercent":@(self.audio.volume * 100), @"muted":@(self.audio.muted),
        @"running":@(self.audio.running), @"statusItemVisible":@(self.statusItem.visible),
        @"popoverVisible":@(self.panel.visible), @"panelVisible":@(self.panel.visible), @"windowVisible":@(self.panel.visible), @"mainWindowVisible":@NO,
        @"feedbackEnabled":@([NSUserDefaults.standardUserDefaults boolForKey:UVFeedbackPreference]),
        @"feedbackCount":@(self.feedbackCount), @"sliderCommitCount":@(self.sliderCommitCount),
        @"volumeActionCount":@(self.volumeActionCount), @"mouseDownCount":@(self.volumeSlider.mouseDownCount),
        @"trackingSlider":@(self.volumeSlider.trackingGesture),
        @"popoverWidth":@(self.panel.frame.size.width), @"popoverHeight":@(self.panel.frame.size.height)
    };
    return report;
}

- (void)writeDiagnostics {
    if (!self.diagnosticPath.length) return;
    NSDictionary *report = [self statusReport];
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [json writeToFile:self.diagnosticPath options:NSDataWritingAtomic error:nil];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *diagnosticPath = nil;
        BOOL smokeTest = NO;
        BOOL showOnLaunch = NO;
        NSAppearanceName appearanceName = nil;
        for (int i = 1; i < argc; i++) {
            NSString *argument = [NSString stringWithUTF8String:argv[i]];
            if ([argument isEqualToString:@"--status"]) return [UVStatusServer printRunningStatus];
            if ([argument isEqualToString:@"--list-devices"]) {
                UVAudioController *audio = [[UVAudioController alloc] init];
                NSData *json = [NSJSONSerialization dataWithJSONObject:[audio devices] ?: @[] options:NSJSONWritingPrettyPrinted error:nil];
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return 0;
            }
            if ([argument isEqualToString:@"--diagnostics"] && i + 1 < argc) diagnosticPath = [NSString stringWithUTF8String:argv[++i]];
            if ([argument isEqualToString:@"--smoke-test"]) smokeTest = YES;
            if ([argument isEqualToString:@"--show-popover"]) showOnLaunch = YES;
            if ([argument isEqualToString:@"--appearance"] && i + 1 < argc) {
                NSString *appearance = [NSString stringWithUTF8String:argv[++i]];
                if ([appearance isEqualToString:@"dark"]) appearanceName = NSAppearanceNameDarkAqua;
                else if ([appearance isEqualToString:@"light"]) appearanceName = NSAppearanceNameAqua;
            }
        }
        [NSApplication sharedApplication];
        if (appearanceName) NSApp.appearance = [NSAppearance appearanceNamed:appearanceName];
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"local.lee.USBVolume";
        for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
            if (other.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:UVShowNotification object:nil userInfo:nil deliverImmediately:YES];
                [other activateWithOptions:0];
                return 0;
            }
        }
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        static UVAppDelegate *delegate;
        delegate = [[UVAppDelegate alloc] init];
        delegate.diagnosticPath = diagnosticPath;
        delegate.smokeTest = smokeTest;
        delegate.showOnLaunch = showOnLaunch;
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
