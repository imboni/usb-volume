#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
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
static NSString *const UVAutomaticDetectionPreference = @"USBVolume.autoDetectUSB";
static NSString *const UVShowNotification = @"local.lee.USBVolume.showPopover";

static NSColor *UVMixerAccentColor(void) {
    static NSColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [NSColor colorWithName:@"USBVolumeMixerAccent" dynamicProvider:^NSColor *(NSAppearance *appearance) {
            BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
            return dark ? [NSColor colorWithSRGBRed:0.467 green:0.784 blue:0.875 alpha:1] :
                          [NSColor colorWithSRGBRed:0.086 green:0.478 blue:0.588 alpha:1];
        }];
    });
    return color;
}

static NSRect UVLocalizedRect(NSRect rect, CGFloat width) {
    if (UVIsRightToLeft()) rect.origin.x = width - NSMaxX(rect);
    return rect;
}

static void UVLocalizeTextField(NSTextField *label, BOOL trailing, BOOL externalText) {
    BOOL rtl = UVIsRightToLeft();
    label.userInterfaceLayoutDirection = rtl ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight;
    label.alignment = rtl != trailing ? NSTextAlignmentRight : NSTextAlignmentLeft;
    label.cell.baseWritingDirection = externalText ? NSWritingDirectionNatural :
        rtl ? NSWritingDirectionRightToLeft : NSWritingDirectionLeftToRight;
}

static BOOL UVShouldAnimateInterface(NSEventType type, BOOL reduceMotion) {
    if (reduceMotion) return NO;
    return type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseUp ||
           type == NSEventTypeRightMouseDown || type == NSEventTypeRightMouseUp ||
           type == NSEventTypeOtherMouseDown || type == NSEventTypeOtherMouseUp;
}

// Native tracking and focus, with a restrained rollover surface for compact icons.
@interface UVIconButton : NSButton
@property(nonatomic) NSTrackingArea *hoverArea;
@property(nonatomic) BOOL hovered;
@end
@implementation UVIconButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.enabled && (self.hovered || self.cell.highlighted || self.state == NSControlStateValueOn)) {
        NSColor *color = self.state == NSControlStateValueOn ? UVMixerAccentColor() : NSColor.labelColor;
        [[color colorWithAlphaComponent:self.cell.highlighted ? 0.15 : 0.08] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:5 yRadius:5] fill];
    }
    [super drawRect:dirtyRect];
}
@end

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
    // A vertical gesture in the app list scrolls the list, not a random fader.
    // Option-scroll is an explicit volume adjustment; the master stays scrollable.
    if (self.enclosingScrollView && !(event.modifierFlags & NSEventModifierFlagOption)) {
        [self.enclosingScrollView scrollWheel:event];
        return;
    }
    if (!self.enabled) return;
    CGFloat delta = fabs(event.scrollingDeltaX) > fabs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY;
    [self setUserValue:self.doubleValue + delta * (event.hasPreciseScrollingDeltas ? 0.15 : 1)];
}

@end

// Rows keep their identity while the process list updates, preserving focus and drags.
@interface UVApplicationRow : NSView
@property(nonatomic, copy) NSString *applicationID;
@property(nonatomic) NSImageView *icon;
@property(nonatomic) NSTextField *nameLabel;
@property(nonatomic) NSTextField *valueLabel;
@property(nonatomic) NSTextField *stateLabel;
@property(nonatomic) UVSlider *slider;
@property(nonatomic) NSButton *muteButton;
@end
@implementation UVApplicationRow
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 2, 20, 20)];
        _icon.imageScaling = NSImageScaleProportionallyDown;
        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.frame = NSMakeRect(28, 2, 184, 16);
        _nameLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _valueLabel = [NSTextField labelWithString:@""];
        _valueLabel.frame = NSMakeRect(230, 2, 42, 16);
        _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        _valueLabel.alignment = NSTextAlignmentRight;
        _stateLabel = [NSTextField labelWithString:@""];
        _stateLabel.frame = NSMakeRect(28, 46, 246, 15);
        _stateLabel.font = [NSFont systemFontOfSize:10];
        _stateLabel.textColor = NSColor.secondaryLabelColor;
        _stateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _muteButton = [[UVIconButton alloc] initWithFrame:NSMakeRect(0, 22, 24, 24)];
        _muteButton.title = @"";
        _muteButton.bordered = NO;
        _muteButton.imagePosition = NSImageOnly;
        _slider = [[UVSlider alloc] initWithFrame:NSMakeRect(28, 22, 246, 22)];
        _slider.controlSize = NSControlSizeSmall;
        _slider.minValue = 0;
        _slider.maxValue = 100;
        _slider.continuous = YES;
        _slider.focusRingType = NSFocusRingTypeNone;
        for (NSView *view in @[_icon, _nameLabel, _valueLabel, _stateLabel, _muteButton, _slider]) [self addSubview:view];
    }
    return self;
}
- (void)applyLocalizedLayout {
    self.userInterfaceLayoutDirection = UVIsRightToLeft() ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight;
    self.icon.frame = UVLocalizedRect(NSMakeRect(0, 2, 20, 20), 276);
    self.nameLabel.frame = UVLocalizedRect(NSMakeRect(28, 2, 184, 16), 276);
    self.valueLabel.frame = UVLocalizedRect(NSMakeRect(230, 2, 42, 16), 276);
    self.stateLabel.frame = UVLocalizedRect(NSMakeRect(28, 46, 246, 15), 276);
    self.muteButton.frame = UVLocalizedRect(NSMakeRect(0, 22, 24, 24), 276);
    self.slider.frame = UVLocalizedRect(NSMakeRect(28, 22, 246, 22), 276);
    // Keep gain direction consistent with keyboard arrows and physical audio controls.
    self.slider.userInterfaceLayoutDirection = NSUserInterfaceLayoutDirectionLeftToRight;
    UVLocalizeTextField(self.nameLabel, NO, YES);
    UVLocalizeTextField(self.valueLabel, YES, YES);
    UVLocalizeTextField(self.stateLabel, NO, NO);
}
@end

@interface UVFlippedView : NSView
@end
@implementation UVFlippedView
- (BOOL)isFlipped { return YES; }
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
@property(nonatomic) BOOL panelWantedVisible;
@property(nonatomic) BOOL panelClosing;
@property(nonatomic) NSUInteger panelAnimationGeneration;
@property(nonatomic) UVContentView *panelContent;
@property(nonatomic) id localClickMonitor;
@property(nonatomic) id globalClickMonitor;
@property(nonatomic) UVSlider *volumeSlider;
@property(nonatomic) NSButton *muteButton;
@property(nonatomic) NSTextField *errorLabel;
@property(nonatomic) NSButton *retryButton;
@property(nonatomic) NSTextField *deviceLabel;
@property(nonatomic) NSTextField *masterHintLabel;
@property(nonatomic) NSTextField *browserDetailLabel;
@property(nonatomic) NSButton *settingsButton;
@property(nonatomic) NSBox *masterDivider;
@property(nonatomic) NSBox *footerDivider;
@property(nonatomic) NSTextField *masterLabel;
@property(nonatomic) NSTextField *masterValueLabel;
@property(nonatomic) NSTextField *applicationsLabel;
@property(nonatomic) NSTextField *emptyApplicationsLabel;
@property(nonatomic) NSTextField *mixerHintLabel;
@property(nonatomic) NSButton *resetApplicationsButton;
@property(nonatomic) NSButton *browserVolumeButton;
@property(nonatomic) NSScrollView *applicationsScroll;
@property(nonatomic) UVFlippedView *applicationsContent;
@property(nonatomic) NSMutableDictionary<NSString *, UVApplicationRow *> *applicationRows;
@property(nonatomic, copy) NSString *applicationActionError;
@property(nonatomic, copy) NSString *applicationActionErrorID;
@property(nonatomic) BOOL applicationErrorObservedInBackend;
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
@property(nonatomic) NSSet<NSString *> *observedUSBUIDs;
@property(nonatomic) NSDictionary<NSString *, NSNumber *> *observedUSBDeviceIDs;
@property(nonatomic) NSMutableOrderedSet<NSString *> *unofferedDeviceUIDs;
@property(nonatomic, readonly) BOOL automaticDetectionEnabled;
@property(nonatomic, copy) NSString *pendingDeviceUID;
@property(nonatomic) NSNumber *pendingDeviceID;
@property(nonatomic) NSUInteger connectionPromptGeneration;
@property(nonatomic) NSAlert *connectionAlert;
@property(nonatomic) BOOL monitoringDevices;
@property(nonatomic) NSUInteger deviceRefreshGeneration;
@property(nonatomic) NSUInteger startGeneration;
@end

@implementation UVAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{UVFeedbackPreference:@YES, UVMutePreference:@NO, UVAutomaticDetectionPreference:@YES}];
    self.audio = [[UVAudioController alloc] init];
    NSNumber *saved = [defaults objectForKey:UVVolumePreference];
    float initialVolume = saved ? saved.floatValue : 0.2f;
    self.audio.volume = isfinite(initialVolume) ? fminf(1, fmaxf(0, initialVolume)) : 0.2f;
    self.audio.muted = [defaults boolForKey:UVMutePreference];
    self.selectedUID = [defaults stringForKey:UVDevicePreference];
    self.observedUSBUIDs = [NSSet set];
    __weak UVAppDelegate *weakSelf = self;
    self.mediaKeys = [[UVMediaKeys alloc] init];
    // Event-tap callbacks must not wait on Core Audio IPC or redraw the UI.
    self.mediaKeys.shouldHandle = ^BOOL{ return weakSelf.mediaKeyRouteOwned; };
    self.mediaKeys.handler = ^(UVMediaKey key, BOOL fine) { [weakSelf mediaKeyPressed:key fine:fine]; };
    self.mediaKeys.releaseHandler = ^(UVMediaKey key) { [weakSelf mediaKeyReleased:key]; };
    self.audio.stateChanged = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.quitting) return;
            if (!weakSelf.audio.running && !weakSelf.performingStart) [weakSelf refreshDevices];
            [weakSelf updateUI];
        });
    };
    self.audio.devicesChanged = ^{ [weakSelf scheduleDeviceRefresh]; };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageChanged:) name:UVLanguageDidChangeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(motionPreferenceChanged:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    [self installMenu];
    [self buildPanel];
    [self updateDeviceMonitoring];
    [self refreshDevices];
    [self updateUI];
    self.statusServer = [[UVStatusServer alloc] init];
    self.statusServer.reportProvider = ^NSDictionary *{ return [weakSelf statusReport]; };
    [self.statusServer start];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(reopen:) name:UVShowNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
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
    self.panelContent.layer.cornerRadius = 12;
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
    self.muteButton = [[UVIconButton alloc] initWithFrame:NSMakeRect(5, 6, 28, 28)];
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
    self.masterLabel = [NSTextField labelWithString:@""];
    self.masterLabel.frame = NSMakeRect(14, 10, 200, 18);
    self.masterLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.masterLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.masterValueLabel = [NSTextField labelWithString:@""];
    self.masterValueLabel.frame = NSMakeRect(230, 8, 56, 22);
    self.masterValueLabel.alignment = NSTextAlignmentRight;
    self.masterValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightMedium];
    self.applicationsLabel = [NSTextField labelWithString:@""];
    self.applicationsLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.resetApplicationsButton = [UVIconButton buttonWithTitle:@"" target:self action:@selector(resetApplications:)];
    self.resetApplicationsButton.bordered = NO;
    self.resetApplicationsButton.imagePosition = NSImageOnly;
    self.resetApplicationsButton.image = [NSImage imageWithSystemSymbolName:@"arrow.counterclockwise" accessibilityDescription:nil];
    self.resetApplicationsButton.controlSize = NSControlSizeSmall;
    self.resetApplicationsButton.accessibilityIdentifier = @"resetApplicationsButton";
    self.applicationsScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.applicationsScroll.drawsBackground = NO;
    self.applicationsScroll.hasVerticalScroller = YES;
    self.applicationsScroll.autohidesScrollers = YES;
    self.applicationsContent = [[UVFlippedView alloc] initWithFrame:NSZeroRect];
    self.applicationsScroll.documentView = self.applicationsContent;
    self.applicationRows = [NSMutableDictionary dictionary];
    self.emptyApplicationsLabel = [NSTextField wrappingLabelWithString:@""];
    self.emptyApplicationsLabel.font = [NSFont systemFontOfSize:12];
    self.emptyApplicationsLabel.textColor = NSColor.secondaryLabelColor;
    self.mixerHintLabel = [NSTextField wrappingLabelWithString:@""];
    self.mixerHintLabel.font = [NSFont systemFontOfSize:11];
    self.mixerHintLabel.textColor = NSColor.secondaryLabelColor;
    self.browserVolumeButton = [UVIconButton buttonWithTitle:@"" target:self action:@selector(showBrowserVolume:)];
    self.browserVolumeButton.bordered = NO;
    self.browserVolumeButton.alignment = NSTextAlignmentLeft;
    self.browserVolumeButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.browserVolumeButton.imagePosition = NSImageOnly;
    self.browserVolumeButton.image = [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil];
    self.browserVolumeButton.controlSize = NSControlSizeSmall;
    self.browserVolumeButton.accessibilityIdentifier = @"browserVolumeButton";
    self.deviceLabel = [NSTextField labelWithString:@""];
    self.deviceLabel.frame = NSMakeRect(16, 16, 276, 18);
    self.deviceLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.deviceLabel.textColor = NSColor.secondaryLabelColor;
    self.deviceLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.masterHintLabel = [NSTextField labelWithString:@""];
    self.masterHintLabel.frame = NSMakeRect(16, 106, 308, 18);
    self.masterHintLabel.font = [NSFont systemFontOfSize:11];
    self.masterHintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.browserDetailLabel = [NSTextField labelWithString:@"Chrome / Edge"];
    self.browserDetailLabel.font = [NSFont systemFontOfSize:10];
    self.browserDetailLabel.textColor = NSColor.secondaryLabelColor;
    self.browserDetailLabel.alignment = NSTextAlignmentRight;
    self.settingsButton = [UVIconButton buttonWithTitle:@"" target:self action:@selector(showSettings:)];
    self.settingsButton.frame = NSMakeRect(300, 10, 28, 28);
    self.settingsButton.bordered = NO;
    self.settingsButton.imagePosition = NSImageOnly;
    self.settingsButton.image = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:nil];
    self.settingsButton.contentTintColor = NSColor.secondaryLabelColor;
    self.settingsButton.accessibilityIdentifier = @"settingsButton";
    self.deviceLabel.hidden = YES;
    self.masterHintLabel.hidden = YES;
    self.browserDetailLabel.hidden = YES;
    self.applicationsLabel.hidden = YES;
    self.emptyApplicationsLabel.alignment = NSTextAlignmentCenter;
    self.masterDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    self.masterDivider.boxType = NSBoxSeparator;
    self.footerDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    self.footerDivider.boxType = NSBoxSeparator;
    for (NSView *view in @[self.masterLabel, self.masterValueLabel, self.applicationsLabel,
          self.resetApplicationsButton, self.applicationsScroll, self.emptyApplicationsLabel,
          self.mixerHintLabel, self.browserVolumeButton, self.deviceLabel, self.masterHintLabel,
          self.browserDetailLabel, self.settingsButton, self.masterDivider, self.footerDivider]) [self.panelContent addSubview:view];
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
    NSMutableSet<NSString *> *currentUSB = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *currentIDs = [NSMutableDictionary dictionary];
    for (NSDictionary *device in self.knownDevices) {
        if ([device[@"isUSB"] boolValue] && [device[@"uid"] length]) {
            [currentUSB addObject:device[@"uid"]];
            if (device[@"id"]) currentIDs[device[@"uid"]] = device[@"id"];
        }
    }
    NSMutableSet<NSString *> *arrivals = [currentUSB mutableCopy];
    [arrivals minusSet:self.observedUSBUIDs ?: [NSSet set]];
    for (NSString *uid in currentIDs) {
        NSNumber *previousID = self.observedUSBDeviceIDs[uid];
        if (previousID && ![previousID isEqual:currentIDs[uid]]) [arrivals addObject:uid];
    }
    BOOL selectedReplaced = self.observedUSBDeviceIDs[self.selectedUID ?: @""] &&
        currentIDs[self.selectedUID ?: @""] &&
        ![self.observedUSBDeviceIDs[self.selectedUID] isEqual:currentIDs[self.selectedUID]];
    self.observedUSBUIDs = [currentUSB copy];
    self.observedUSBDeviceIDs = [currentIDs copy];
    if (!self.unofferedDeviceUIDs) self.unofferedDeviceUIDs = [NSMutableOrderedSet orderedSet];
    for (NSString *uid in self.unofferedDeviceUIDs.array) {
        if (![currentUSB containsObject:uid]) [self.unofferedDeviceUIDs removeObject:uid];
    }
    [self.unofferedDeviceUIDs addObjectsFromArray:[[arrivals allObjects] sortedArrayUsingSelector:@selector(compare:)]];
    // Disconnection cleanup is mandatory even when automatic prompting is off.
    if ((![self selectedDevice] || selectedReplaced) && (self.audio.running || self.performingStart)) {
        self.startGeneration++;
        self.performingStart = NO;
        [self.feedbackTimer invalidate]; self.feedbackTimer = nil;
        self.mediaKeyRouteOwned = NO;
        self.mediaKeys.enabled = NO;
        [self.mediaKeys stop];
        [self.audio stop];
        [self closePanel];
    }
    if (self.pendingDeviceUID.length && (![currentUSB containsObject:self.pendingDeviceUID] ||
        (self.pendingDeviceID && ![self.pendingDeviceID isEqual:currentIDs[self.pendingDeviceUID]]) ||
        !self.automaticDetectionEnabled || self.audio.running || self.performingStart)) [self dismissConnectionPrompt];
    if (!self.automaticDetectionEnabled || self.smokeTest || self.quitting || self.audio.running || self.performingStart) {
        [self.unofferedDeviceUIDs removeAllObjects];
        return;
    }
    if (self.pendingDeviceUID.length) return;
    NSString *candidateUID = [self.unofferedDeviceUIDs containsObject:self.selectedUID ?: @""] ? self.selectedUID : self.unofferedDeviceUIDs.firstObject;
    for (NSDictionary *device in self.knownDevices) {
        if ([device[@"uid"] isEqualToString:candidateUID]) {
            self.pendingDeviceUID = candidateUID;
            self.pendingDeviceID = device[@"id"];
            self.connectionPromptGeneration++;
            [self.unofferedDeviceUIDs removeObject:candidateUID];
            [self.audio clearError];
            [self presentConnectionPromptForDevice:device];
            break;
        }
    }
}

- (BOOL)automaticDetectionEnabled {
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:UVAutomaticDetectionPreference];
    return !value || value.boolValue;
}

- (void)updateDeviceMonitoring {
    BOOL shouldMonitor = self.automaticDetectionEnabled && !self.smokeTest && !self.quitting;
    if (shouldMonitor) self.monitoringDevices = [self.audio startMonitoringDevices];
    else { [self.audio stopMonitoringDevices]; self.monitoringDevices = NO; }
}

- (void)scheduleDeviceRefresh {
    NSUInteger generation = ++self.deviceRefreshGeneration;
    __weak UVAppDelegate *weakSelf = self;
    // HAL emits several notifications while a USB route and its streams settle.
    for (NSNumber *delay in @[@0.25, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UVAppDelegate *app = weakSelf;
            if (!app || app.quitting || generation != app.deviceRefreshGeneration) return;
            [app refreshDevices];
            [app updateUI];
        });
    }
}

- (void)automaticDetectionChanged {
    self.deviceRefreshGeneration++;
    [self dismissConnectionPrompt];
    [self.unofferedDeviceUIDs removeAllObjects];
    [self updateDeviceMonitoring];
    // Enabling detection also offers an already-connected USB speaker once.
    if (self.automaticDetectionEnabled) self.observedUSBUIDs = [NSSet set];
    [self refreshDevices];
    [self updateUI];
}

- (void)presentConnectionPromptForDevice:(NSDictionary *)device {
    [self closePanel];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = UVL(@"检测到 USB 音箱");
    alert.informativeText = [NSString stringWithFormat:UVL(@"为「%@」启用音量控制？"), device[@"name"] ?: @""];
    alert.alertStyle = NSAlertStyleInformational;
    alert.showsHelp = NO;
    alert.showsSuppressionButton = NO;
    [alert addButtonWithTitle:UVL(@"启用")];
    [alert addButtonWithTitle:UVL(@"暂不")];
    [alert layout];
    self.connectionAlert = alert;
    alert.buttons[0].target = self;
    alert.buttons[0].action = @selector(enableDetectedDevice:);
    alert.buttons[0].accessibilityIdentifier = @"enableDetectedDeviceButton";
    alert.buttons[1].target = self;
    alert.buttons[1].action = @selector(declineDetectedDevice:);
    alert.buttons[1].keyEquivalent = @"\e";
    alert.buttons[1].accessibilityIdentifier = @"declineDetectedDeviceButton";
    // A modeless alert lets disconnection and preference changes invalidate it.
    alert.window.delegate = self;
    [alert.window center];
    [NSApp activateIgnoringOtherApps:YES];
    [alert.window makeKeyAndOrderFront:nil];
}

- (void)dismissConnectionPrompt {
    [self.connectionAlert.window orderOut:nil];
    self.connectionAlert.window.delegate = nil;
    self.connectionAlert = nil;
    self.pendingDeviceUID = nil;
    self.pendingDeviceID = nil;
    self.connectionPromptGeneration++;
}

- (void)enableDetectedDevice:(id)sender {
    if (sender && sender != self.connectionAlert.buttons.firstObject) return;
    NSString *uid = self.pendingDeviceUID;
    NSUInteger generation = self.connectionPromptGeneration;
    [self refreshDevices];
    if (!uid.length || generation != self.connectionPromptGeneration ||
        ![uid isEqualToString:self.pendingDeviceUID] || !self.automaticDetectionEnabled ||
        self.quitting || self.audio.running || self.performingStart) return;
    [self dismissConnectionPrompt];
    self.selectedUID = uid;
    [self saveSelectedDevice];
    [self startAudio];
}

- (void)declineDetectedDevice:(id)sender {
    if (sender && (self.connectionAlert.buttons.count < 2 || sender != self.connectionAlert.buttons[1])) return;
    [self dismissConnectionPrompt];
    [self refreshDevices];
    [self updateUI];
}

- (void)saveSelectedDevice {
    [NSUserDefaults.standardUserDefaults setObject:self.selectedUID forKey:UVDevicePreference];
}

- (NSString *)shortStatus {
    if (self.performingStart) return UVL(@"正在连接…");
    if (!self.audio.running && self.automaticDetectionEnabled && self.observedUSBUIDs.count == 0) return UVL(@"等待 USB 音箱");
    if (self.pendingDeviceUID.length) return UVL(@"音箱已连接，等待启用。");
    if (![self selectedDevice]) return self.selectedUID.length ? UVL(@"音箱未连接") : UVL(@"请选择输出设备");
    if (self.audio.running) return self.audio.muted ? UVL(@"已静音") : UVPercentString(self.audio.volume);
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
    if (!running && self.mediaKeys.active) [self.mediaKeys stop];
    [self.settingsController updateKeyboardActive:self.mediaKeys.active needsPermission:self.mediaKeys.needsPermission];
    if (!running) self.mediaChangedKeys = 0;
    if (self.panelClosing) return;
    BOOL editable = (running && self.audio.ownsDefaultOutput) || self.smokeTest;
    if (!self.volumeSlider.trackingGesture) self.volumeSlider.doubleValue = self.audio.volume * 100;
    self.volumeSlider.enabled = editable;
    self.muteButton.enabled = editable;
    self.panel.title = UVL(@"USB 音量");
    self.volumeSlider.accessibilityLabel = UVL(@"音量");
    self.statusItem.button.accessibilityLabel = UVL(@"USB 音量");
    self.volumeSlider.toolTip = [NSString stringWithFormat:UVL(@"音量 %@"), UVPercentString(self.audio.volume)];
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
    self.deviceLabel.stringValue = self.audio.deviceName.length ? self.audio.deviceName : deviceName;
    self.deviceLabel.toolTip = self.deviceLabel.stringValue;
    self.settingsButton.accessibilityLabel = UVL(@"设置…");
    self.settingsButton.toolTip = self.settingsButton.accessibilityLabel;
    self.panelContent.userInterfaceLayoutDirection = UVIsRightToLeft() ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight;
    self.applicationsContent.userInterfaceLayoutDirection = self.panelContent.userInterfaceLayoutDirection;
    // The scroller stays on the right so a change in language never shifts faders.
    self.applicationsScroll.userInterfaceLayoutDirection = NSUserInterfaceLayoutDirectionLeftToRight;
    self.volumeSlider.userInterfaceLayoutDirection = NSUserInterfaceLayoutDirectionLeftToRight;
    self.masterLabel.frame = UVLocalizedRect(NSMakeRect(14, 10, 200, 18), 300);
    self.masterValueLabel.frame = UVLocalizedRect(NSMakeRect(230, 8, 56, 22), 300);
    UVLocalizeTextField(self.masterLabel, NO, NO);
    UVLocalizeTextField(self.masterValueLabel, YES, YES);
    UVLocalizeTextField(self.errorLabel, NO, NO);
    UVLocalizeTextField(self.emptyApplicationsLabel, NO, NO);
    UVLocalizeTextField(self.mixerHintLabel, NO, NO);
    self.masterLabel.stringValue = UVL(@"总音量");
    self.masterLabel.toolTip = self.masterLabel.stringValue;
    self.masterValueLabel.stringValue = UVPercentString(self.audio.volume);
    self.masterValueLabel.textColor = self.audio.muted ? NSColor.secondaryLabelColor : NSColor.labelColor;
    self.muteButton.frame = UVLocalizedRect(NSMakeRect(8, 32, 28, 28), 300);
    self.muteButton.state = self.audio.muted ? NSControlStateValueOn : NSControlStateValueOff;
    self.muteButton.contentTintColor = self.audio.muted ? UVMixerAccentColor() : NSColor.labelColor;
    self.volumeSlider.frame = UVLocalizedRect(NSMakeRect(40, 34, 246, 24), 300);
    self.volumeSlider.trackFillColor = self.audio.muted ? NSColor.tertiaryLabelColor : UVMixerAccentColor();
    self.masterHintLabel.stringValue = self.audio.muted ? UVL(@"总音量已静音") : UVL(@"所有应用随总音量调整");
    self.masterHintLabel.toolTip = self.masterHintLabel.stringValue;
    self.masterHintLabel.textColor = self.audio.muted ? UVMixerAccentColor() : NSColor.secondaryLabelColor;
    CGFloat retryWidth = MAX(44, self.retryButton.intrinsicContentSize.width);
    self.errorLabel.frame = UVLocalizedRect(NSMakeRect(14, 65, 300 - retryWidth - 36, 18), 300);
    self.retryButton.frame = UVLocalizedRect(NSMakeRect(300 - retryWidth - 12, 60, retryWidth, 26), 300);
    CGFloat sectionTop = needsStatus ? 104 : 76;
    self.masterDivider.frame = NSMakeRect(12, sectionTop - 10, 276, 1);
    [self updateApplicationRowsAtY:sectionTop];
    [self writeDiagnostics];
}

- (BOOL)trackingAnySlider {
    if (self.volumeSlider.trackingGesture) return YES;
    for (UVApplicationRow *row in self.applicationRows.allValues) if (row.slider.trackingGesture) return YES;
    return NO;
}

- (void)updateApplicationRowsAtY:(CGFloat)top {
    if (self.panelClosing) return;
    NSArray<NSDictionary *> *applications = self.audio.applications ?: @[];
    // Keep rows fixed during a drag, including if an application exits mid-gesture.
    if ([self trackingAnySlider]) return;
    NSMutableSet *ids = [NSMutableSet set];
    CGFloat y = 0;
    for (NSDictionary *application in applications) {
        NSString *identifier = application[@"id"];
        if (!identifier.length) continue;
        [ids addObject:identifier];
        UVApplicationRow *row = self.applicationRows[identifier];
        if (!row) {
            row = [[UVApplicationRow alloc] initWithFrame:NSMakeRect(0, y, 276, 48)];
            row.applicationID = identifier;
            __weak UVAppDelegate *weakSelf = self;
            row.slider.gestureEnded = ^{ [weakSelf updateUI]; };
            row.slider.target = self;
            row.slider.action = @selector(applicationVolumeChanged:);
            row.slider.accessibilityIdentifier = [@"applicationVolume." stringByAppendingString:identifier];
            row.muteButton.target = self;
            row.muteButton.action = @selector(applicationMuteChanged:);
            row.muteButton.accessibilityIdentifier = [@"applicationMute." stringByAppendingString:identifier];
            NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:application[@"bundleID"] ?: @""];
            row.icon.image = url ? [NSWorkspace.sharedWorkspace iconForFile:url.path] :
                [NSImage imageWithSystemSymbolName:@"app.dashed" accessibilityDescription:nil];
            [self.applicationsContent addSubview:row];
            self.applicationRows[identifier] = row;
        }
        [row applyLocalizedLayout];
        CGFloat rowTop = y;
        BOOL muted = [application[@"muted"] boolValue];
        BOOL active = [application[@"active"] boolValue];
        BOOL enabled = self.audio.running && self.audio.ownsDefaultOutput && [application[@"controllable"] boolValue];
        float volume = [application[@"volume"] floatValue];
        row.nameLabel.stringValue = application[@"name"] ?: identifier;
        row.nameLabel.toolTip = row.nameLabel.stringValue;
        row.slider.doubleValue = volume * 100;
        row.slider.enabled = enabled;
        row.slider.trackFillColor = muted || self.audio.muted ? NSColor.tertiaryLabelColor : UVMixerAccentColor();
        row.muteButton.enabled = enabled;
        row.slider.accessibilityLabel = [NSString stringWithFormat:UVL(@"%@ 音量"), UVIsolateText(row.nameLabel.stringValue)];
        row.valueLabel.stringValue = UVPercentString(volume);
        row.valueLabel.textColor = muted ? NSColor.secondaryLabelColor : NSColor.labelColor;
        BOOL applied = !application[@"applied"] || [application[@"applied"] boolValue];
        BOOL hasError = [application[@"error"] length] > 0;
        NSString *state = muted ? UVL(@"已静音") : active ? UVL(@"正在播放") : UVL(@"未在播放");
        if (!self.audio.running) state = UVL(@"启用音量控制后可调节");
        else if (hasError) state = UVL(@"独立控制未生效");
        else if (!enabled) state = active ? UVL(@"未输出到当前设备") : UVL(@"未在播放");
        else if (!applied) state = UVL(@"独立控制未生效");
        BOOL showsIssue = self.audio.running && (hasError || (enabled && !applied));
        row.stateLabel.hidden = !showsIssue;
        row.frame = NSMakeRect(0, rowTop, 276, showsIssue ? 64 : 48);
        y += row.frame.size.height;
        row.stateLabel.stringValue = state;
        row.slider.toolTip = [NSString stringWithFormat:@"%@ · %@", UVIsolateText(row.nameLabel.stringValue), hasError ? application[@"error"] : state];
        row.slider.accessibilityHelp = row.slider.toolTip;
        row.stateLabel.toolTip = hasError ? application[@"error"] : state;
        row.stateLabel.textColor = hasError ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
        NSString *symbol = !applied ? @"exclamationmark.triangle" : muted || volume == 0 ? @"speaker.slash.fill" : @"speaker.wave.2.fill";
        row.muteButton.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]];
        row.muteButton.state = muted && applied ? NSControlStateValueOn : NSControlStateValueOff;
        row.muteButton.contentTintColor = muted ? UVMixerAccentColor() : NSColor.labelColor;
        row.muteButton.accessibilityLabel = [NSString stringWithFormat:@"%@ · %@", UVIsolateText(row.nameLabel.stringValue), muted ? UVL(@"取消静音") : UVL(@"静音")];
        row.muteButton.toolTip = row.muteButton.accessibilityLabel;
    }
    for (NSString *identifier in self.applicationRows.allKeys) {
        if (![ids containsObject:identifier]) {
            UVApplicationRow *row = self.applicationRows[identifier];
            if (self.panel.firstResponder == row.slider) [self.panel makeFirstResponder:self.volumeSlider];
            [row removeFromSuperview];
            [self.applicationRows removeObjectForKey:identifier];
        }
    }
    self.applicationsLabel.stringValue = UVL(@"应用音量");
    self.resetApplicationsButton.title = @"";
    self.resetApplicationsButton.accessibilityLabel = UVL(@"全部恢复 100%");
    self.resetApplicationsButton.toolTip = self.resetApplicationsButton.accessibilityLabel;
    self.resetApplicationsButton.enabled = self.audio.running && self.audio.ownsDefaultOutput && applications.count > 0;
    CGFloat listHeight = !self.audio.running && applications.count == 0 ? 0 : MAX(40, MIN(240, y));
    self.applicationsScroll.hidden = applications.count == 0;
    self.applicationsScroll.frame = NSMakeRect(12, top, 276, listHeight);
    self.applicationsContent.frame = NSMakeRect(0, 0, 276, MAX(listHeight, y));
    self.emptyApplicationsLabel.hidden = applications.count != 0 || !self.audio.running;
    self.emptyApplicationsLabel.stringValue = self.audio.running ? UVL(@"未在播放") : [self shortStatus];
    self.emptyApplicationsLabel.toolTip = self.audio.running ? UVL(@"播放音乐或视频后，应用会显示在这里。") : UVL(@"启用音量控制后，播放音乐或视频以显示应用。");
    self.emptyApplicationsLabel.frame = NSMakeRect(18, top + 8, 264, 28);
    // Keep a failure associated with its source and clear it after an observed
    // backend failure has recovered, or the source has disappeared.
    if (self.applicationActionErrorID.length) {
        NSDictionary *source = nil;
        for (NSDictionary *application in applications)
            if ([application[@"id"] isEqual:self.applicationActionErrorID]) source = application;
        if ([source[@"error"] length]) self.applicationErrorObservedInBackend = YES;
        else if (!source || self.applicationErrorObservedInBackend) {
            self.applicationActionError = nil;
            self.applicationActionErrorID = nil;
            self.applicationErrorObservedInBackend = NO;
        }
    }
    NSString *errorMessage = self.audio.applicationSafetyError.length ? self.audio.applicationSafetyError : self.applicationActionError;
    self.mixerHintLabel.stringValue = errorMessage ?: @"";
    self.mixerHintLabel.hidden = !errorMessage.length;
    self.mixerHintLabel.textColor = NSColor.systemOrangeColor;
    CGFloat footer = top + listHeight + 6;
    CGFloat hintHeight = errorMessage.length ? MAX(32, [self.mixerHintLabel.cell cellSizeForBounds:NSMakeRect(0, 0, 272, CGFLOAT_MAX)].height) : 0;
    self.mixerHintLabel.frame = NSMakeRect(14, footer, 272, hintHeight);
    self.mixerHintLabel.toolTip = errorMessage;
    footer += hintHeight ? hintHeight + 10 : 0;
    self.footerDivider.frame = NSMakeRect(12, footer, 276, 1);
    self.browserVolumeButton.title = @"";
    self.browserVolumeButton.accessibilityLabel = UVL(@"网页音量…");
    self.browserVolumeButton.toolTip = self.browserVolumeButton.accessibilityLabel;
    self.browserVolumeButton.frame = UVLocalizedRect(NSMakeRect(10, footer + 3, 28, 28), 300);
    self.resetApplicationsButton.frame = UVLocalizedRect(NSMakeRect(230, footer + 3, 28, 28), 300);
    self.settingsButton.frame = UVLocalizedRect(NSMakeRect(262, footer + 3, 28, 28), 300);
    NSSize wantedSize = NSMakeSize(300, footer + 36);
    if (!NSEqualSizes(self.panel.contentView.bounds.size, wantedSize)) {
        [self.panel setContentSize:wantedSize];
        if (self.panel.visible) [self positionPanel];
    }
}

- (void)applicationVolumeChanged:(UVSlider *)sender {
    UVApplicationRow *row = (UVApplicationRow *)sender.superview;
    NSError *error = nil;
    BOOL changed = [self.audio setApplicationVolume:sender.floatValue / 100 forID:row.applicationID error:&error];
    if (changed) {
        // Only unmute when needed; normal dragging should reconcile routes once.
        for (NSDictionary *application in self.audio.applications) {
            if ([application[@"id"] isEqual:row.applicationID] && [application[@"muted"] boolValue]) {
                changed = [self.audio setApplicationMuted:NO forID:row.applicationID error:&error];
                break;
            }
        }
    }
    self.applicationActionError = changed ? nil : error.localizedDescription;
    self.applicationActionErrorID = changed ? nil : row.applicationID;
    self.applicationErrorObservedInBackend = NO;
    if (sender.trackingGesture) sender.changedDuringGesture = YES;
    if (!changed) {
        for (NSDictionary *application in self.audio.applications) {
            if ([application[@"id"] isEqual:row.applicationID]) {
                sender.doubleValue = [application[@"volume"] floatValue] * 100;
                break;
            }
        }
    }
    row.valueLabel.stringValue = UVPercentString(sender.doubleValue / 100);
    [self updateUI];
}

- (void)applicationMuteChanged:(NSButton *)sender {
    UVApplicationRow *row = (UVApplicationRow *)sender.superview;
    for (NSDictionary *application in self.audio.applications) {
        if (![application[@"id"] isEqual:row.applicationID]) continue;
        NSError *error = nil;
        BOOL changed = [self.audio setApplicationMuted:![application[@"muted"] boolValue] forID:row.applicationID error:&error];
        self.applicationActionError = changed ? nil : error.localizedDescription;
        self.applicationActionErrorID = changed ? nil : row.applicationID;
        self.applicationErrorObservedInBackend = NO;
        break;
    }
    [self updateUI];
}

- (void)resetApplications:(id)sender {
    (void)sender;
    [self.audio resetApplicationVolumes];
    self.applicationActionError = nil;
    self.applicationActionErrorID = nil;
    self.applicationErrorObservedInBackend = NO;
    [self updateUI];
}

- (void)showBrowserVolume:(id)sender {
    (void)sender;
    [self closePanel];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = UVL(@"单独控制网页音量");
    alert.informativeText = UVL(@"Chrome / Edge 116+：打开扩展管理页，开启开发者模式，选择“加载已解压的扩展程序”，加载下方文件夹。然后在要调节的网页点击扩展图标，启用标签页控制。每个标签页可独立调节，仍受本应用的总音量影响。Safari 暂只支持整个浏览器的音量。");
    [alert addButtonWithTitle:UVL(@"打开扩展文件夹")];
    [alert addButtonWithTitle:UVL(@"关闭")];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSURL *folder = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"BrowserExtension" isDirectory:YES];
        if (folder && [NSFileManager.defaultManager fileExistsAtPath:folder.path])
            [NSWorkspace.sharedWorkspace openURL:folder];
    }
}

- (void)poll:(NSTimer *)timer {
    (void)timer;
    self.tick++;
    if (self.tick % 4 == 0 && !self.performingStart &&
        (self.audio.running || (self.automaticDetectionEnabled && !self.monitoringDevices))) [self refreshDevices];
    if (self.tick % 4 == 0 && self.audio.running && !self.smokeTest && !self.mediaKeys.active) [self.mediaKeys start];
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
    if (self.audio.running) [self.mediaKeys start];
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
    self.settingsController.automaticDetectionChanged = ^{ [weakSelf automaticDetectionChanged]; };
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
    // Capture the trigger before dispatch; keyboard menu commands stay instant.
    BOOL animated = [self shouldAnimateInterface];
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPopoverAnimated:animated]; });
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
    NSNumber *deviceID = [self selectedDevice][@"id"];
    NSUInteger generation = ++self.startGeneration;
    [self dismissConnectionPrompt];
    [self updateUI];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.quitting || generation != self.startGeneration || ![uid isEqualToString:self.selectedUID]) return;
        self.knownDevices = [self.audio devices] ?: @[];
        if (![self selectedDevice] || (deviceID && ![deviceID isEqual:[self selectedDevice][@"id"]])) {
            self.performingStart = NO;
            [self refreshDevices];
            [self updateUI];
            return;
        }
        NSError *error = nil;
        [self.audio startDeviceUID:uid error:&error];
        self.performingStart = NO;
        if (self.audio.running && !self.smokeTest) [self.mediaKeys start];
        [self updateUI];
    });
}

- (void)retry:(id)sender {
    (void)sender;
    [self refreshDevices];
    if (![self selectedDevice]) { [self showOptionsMenu]; return; }
    [self dismissConnectionPrompt];
    [self startAudio];
}

- (void)chooseDevice:(NSMenuItem *)sender {
    NSString *uid = sender.representedObject;
    if (!uid.length || ([uid isEqualToString:self.selectedUID] && self.audio.running)) return;
    self.startGeneration++;
    self.performingStart = NO;
    [self dismissConnectionPrompt];
    [self.audio stop];
    self.selectedUID = uid;
    [self saveSelectedDevice];
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
        self.startGeneration++;
        [self dismissConnectionPrompt];
        [self.audio stop];
    } else {
        [self dismissConnectionPrompt];
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
    NSString *volumeTitle = self.audio.running ? [NSString stringWithFormat:UVL(@"音量 %@%@"), UVPercentString(self.audio.volume), self.audio.muted ? UVL(@" · 已静音") : @""] : [self shortStatus];
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
    if (self.panelClosing || [self trackingAnySlider]) return;
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

- (BOOL)shouldAnimateInterface {
    return UVShouldAnimateInterface(NSApp.currentEvent.type,
        NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);
}

- (void)setPanelShown:(BOOL)shown { [self setPanelShown:shown animated:[self shouldAnimateInterface]]; }

- (void)setPanelShown:(BOOL)shown animated:(BOOL)animated {
    NSUInteger generation = ++self.panelAnimationGeneration;
    BOOL wasVisible = self.panel.visible;
    self.panelWantedVisible = shown;
    self.panelClosing = !shown && wasVisible;
    if (shown) {
        if (!wasVisible) self.panel.alphaValue = animated ? 0 : 1;
        [self.panel makeKeyAndOrderFront:nil];
    }
    if (!animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0;
            self.panel.animator.alphaValue = shown ? 1 : 0;
        } completionHandler:nil];
        if (!shown) {
            [self.panel orderOut:nil];
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0;
                self.panel.animator.alphaValue = 1;
            } completionHandler:nil];
        }
        self.panelClosing = NO;
        [self writeDiagnostics];
        return;
    }
    __weak UVAppDelegate *weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = shown ? 0.12 : (wasVisible ? 0.09 : 0);
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1 :0.3 :1];
        self.panel.animator.alphaValue = shown ? 1 : 0;
    } completionHandler:^{
        UVAppDelegate *app = weakSelf;
        if (!app || app.panelAnimationGeneration != generation) return;
        if (!app.panelWantedVisible) {
            [app.panel orderOut:nil];
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0;
                app.panel.animator.alphaValue = 1;
            } completionHandler:nil];
        }
        app.panelClosing = NO;
        [app writeDiagnostics];
    }];
}

- (void)motionPreferenceChanged:(NSNotification *)notification {
    (void)notification;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion)
        [self setPanelShown:self.panelWantedVisible animated:NO];
}

- (void)showPopover { [self showPopoverAnimated:[self shouldAnimateInterface]]; }

- (void)showPopoverAnimated:(BOOL)animated {
    if (!self.statusItem.button) return;
    if (self.panelClosing) [self setPanelShown:YES animated:animated];
    [self.audio refreshApplications];
    [self updateUI];
    [self positionPanel];
    [NSApp activateIgnoringOtherApps:YES];
    [self setPanelShown:YES animated:animated];
    [self.panel makeFirstResponder:self.volumeSlider];
    self.volumeSlider.focusRingType = NSFocusRingTypeNone;
    // Status-item layout settles after activation, not necessarily in this turn.
    NSUInteger generation = self.panelAnimationGeneration;
    __weak UVAppDelegate *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UVAppDelegate *self = weakSelf;
        if (self.panelWantedVisible && self.panel.visible && generation == self.panelAnimationGeneration) { [self positionPanel]; [self writeDiagnostics]; }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UVAppDelegate *self = weakSelf;
        if (self.panelWantedVisible && self.panel.visible && generation == self.panelAnimationGeneration) { [self positionPanel]; [self writeDiagnostics]; }
    });
    [self writeDiagnostics];
}

- (void)closePanel {
    if (!self.panel.visible) return;
    BOOL animated = [self shouldAnimateInterface];
    if (self.panelClosing && animated) return;
    [self setPanelShown:NO animated:animated];
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) [self showOptionsMenu];
    else if (self.panelWantedVisible || (self.panel.visible && !self.panelClosing)) [self closePanel];
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

- (BOOL)windowShouldClose:(NSWindow *)window {
    if (window == self.connectionAlert.window) {
        [self declineDetectedDevice:nil];
        return NO;
    }
    return YES;
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
    self.startGeneration++;
    self.deviceRefreshGeneration++;
    [self dismissConnectionPrompt];
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
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    self.audio.stateChanged = nil;
    self.audio.devicesChanged = nil;
    [self.audio stopMonitoringDevices];
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
        @"automaticDetectionEnabled":@(self.automaticDetectionEnabled),
        @"deviceMonitoringActive":@(self.monitoringDevices),
        @"standby":@(!self.audio.running && !self.performingStart),
        @"connectionPromptVisible":@(self.connectionAlert.window.visible),
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
