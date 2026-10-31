// Graphical-session integration checks for the real menu-panel views and actions.
// No audio device is opened, permission requested, or preference persisted.
#define main UVApplicationMain
#import "../Sources/main.m"
#undef main
#include <assert.h>

@interface UVMixerTestAudio : UVAudioController
@property(nonatomic) NSArray<NSDictionary *> *snapshot;
@property(nonatomic) float testVolume;
@property(nonatomic) BOOL testMuted;
@property(nonatomic) BOOL testRunning;
@property(nonatomic) BOOL testOwnership;
@property(nonatomic) BOOL rejectChanges;
@property(nonatomic) NSUInteger resetCount;
@property(nonatomic, copy) NSString *testSafetyError;
@end

@implementation UVMixerTestAudio
- (instancetype)init {
    if ((self = [super init])) _testOwnership = YES;
    return self;
}
- (NSUserDefaults *)applicationDefaults { return nil; }
- (float)volume { return self.testVolume; }
- (void)setVolume:(float)value { self.testVolume = value; }
- (BOOL)muted { return self.testMuted; }
- (void)setMuted:(BOOL)value { self.testMuted = value; if (!value) self.testSafetyError = nil; }
- (NSString *)applicationSafetyError { return self.testSafetyError ?: @""; }
- (BOOL)running { return self.testRunning; }
- (BOOL)ownsDefaultOutput { return self.testRunning && self.testOwnership; }
- (NSString *)deviceName { return @"UI test speakers"; }
- (NSArray<NSDictionary *> *)devices { return @[]; }
- (NSArray<NSDictionary *> *)applications { return self.snapshot ?: @[]; }
- (void)refreshApplications {}
- (void)stop {}
- (BOOL)startMonitoringDevices { assert(!"UI tests must not monitor hardware."); return NO; }
- (void)stopMonitoringDevices {}
- (BOOL)startDeviceUID:(NSString *)uid error:(NSError **)error {
    assert(!"UI tests must not start audio.");
    return NO;
}
- (void)playFeedback { assert(!"UI tests must not play audio."); }
- (NSDictionary *)diagnostics { return @{}; }
- (BOOL)changeID:(NSString *)identifier key:(NSString *)key value:(id)value error:(NSError **)error {
    if (self.rejectChanges) {
        if (error) *error = [NSError errorWithDomain:@"MixerUITests" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Simulated application route failure"}];
        return NO;
    }
    NSMutableArray *next = [self.applications mutableCopy];
    NSUInteger index = [next indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger idx, BOOL *stop) {
        return [row[@"id"] isEqual:identifier];
    }];
    if (index == NSNotFound) {
        if (error) *error = [NSError errorWithDomain:@"MixerUITests" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"Application closed"}];
        return NO;
    }
    NSMutableDictionary *row = [next[index] mutableCopy];
    row[key] = value;
    next[index] = row;
    self.snapshot = next;
    return YES;
}
- (BOOL)setApplicationVolume:(float)volume forID:(NSString *)identifier error:(NSError **)error {
    return [self changeID:identifier key:@"volume" value:@(volume) error:error];
}
- (BOOL)setApplicationMuted:(BOOL)muted forID:(NSString *)identifier error:(NSError **)error {
    return [self changeID:identifier key:@"muted" value:@(muted) error:error];
}
- (void)resetApplicationVolumes {
    self.resetCount++;
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *row in self.applications) {
        NSMutableDictionary *reset = [row mutableCopy];
        reset[@"volume"] = @1;
        reset[@"muted"] = @NO;
        [next addObject:reset];
    }
    self.snapshot = next;
}
@end

@interface UVSettingsController (UIMatrixAccess)
- (void)applyLocalization;
- (void)resizeForLocalizedContent;
@end

@interface UVMixerTestSettings : UVSettingsController
@end
@implementation UVMixerTestSettings
- (void)refreshPreferences {
    // Layout fixtures never read/register a real login item or request permissions.
    [self setValue:@NO forKey:@"showsLoginDetail"];
    [[self valueForKey:@"loginStatusLabel"] setHidden:YES];
    [[self valueForKey:@"loginSettingsButton"] setHidden:YES];
    [self updateKeyboardActive:NO needsPermission:YES];
}
@end

@interface UVMixerScrollSpy : NSScrollView
@property(nonatomic) NSUInteger wheelEventCount;
@property(nonatomic) NSEvent *lastWheelEvent;
@end
@implementation UVMixerScrollSpy
- (void)scrollWheel:(NSEvent *)event {
    self.wheelEventCount++;
    self.lastWheelEvent = event;
}
@end

@interface UVMixerTestDelegate : UVAppDelegate
@property(nonatomic) BOOL testAnimateInterface;
@end
@implementation UVMixerTestDelegate
- (BOOL)shouldAnimateInterface { return self.testAnimateInterface; }
// Never run the production launch path (preferences, audio, keys, status socket).
- (void)applicationDidFinishLaunching:(NSNotification *)notification {}
- (void)saveVolumeState {}
- (void)saveSelectedDevice {}
- (void)playFeedback {}
- (void)writeDiagnostics {}
- (BOOL)automaticDetectionEnabled { return NO; }
- (void)refreshDevices {}
- (void)positionPanel {}
- (void)applicationDidResignActive:(NSNotification *)notification {}
- (void)windowDidResignKey:(NSNotification *)notification {}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { return NSTerminateNow; }
@end

static NSDictionary *AppRow(NSString *identifier, NSString *name, float volume, BOOL muted, BOOL active) {
    return @{@"id":identifier, @"bundleID":identifier, @"name":name, @"volume":@(volume),
             @"muted":@(muted), @"active":@(active), @"controllable":@YES, @"applied":@YES, @"error":@""};
}

static NSDictionary *FindRow(UVMixerTestAudio *audio, NSString *identifier) {
    for (NSDictionary *row in audio.applications) if ([row[@"id"] isEqual:identifier]) return row;
    assert(!"Expected application is missing.");
    return nil;
}

static void AssertNear(double actual, double expected) {
    if (fabs(actual - expected) >= 0.0001)
        fprintf(stderr, "Expected %.4f, received %.4f\n", expected, actual);
    assert(fabs(actual - expected) < 0.0001);
}

static void TestIndependentActions(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    audio.snapshot = @[AppRow(@"com.apple.Music", @"Music", 0.8f, YES, YES),
                       AppRow(@"com.google.Chrome", @"Google Chrome", 0.6f, NO, YES)];
    [app updateUI];
    assert(app.applicationRows.count == 2 && app.emptyApplicationsLabel.hidden);
    UVApplicationRow *music = app.applicationRows[@"com.apple.Music"];
    UVApplicationRow *chrome = app.applicationRows[@"com.google.Chrome"];
    AssertNear(music.slider.doubleValue, 80);
    assert(music.slider.enabled && music.muteButton.enabled);
    assert([music.stateLabel.stringValue isEqual:UVL(@"已静音")]);

    [music.slider setUserValue:35];
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 0.35);
    AssertNear([FindRow(audio, @"com.google.Chrome")[@"volume"] doubleValue], 0.6);
    AssertNear(audio.volume, 0.4);
    assert(![FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    assert(!audio.muted && [music.valueLabel.stringValue isEqual:UVPercentString(0.35)]);

    [music.muteButton performClick:nil];
    assert([FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    assert(!audio.muted && ![FindRow(audio, @"com.google.Chrome")[@"muted"] boolValue]);
    [app.volumeSlider setUserValue:65];
    AssertNear(audio.volume, 0.65);
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 0.35);
    AssertNear([FindRow(audio, @"com.google.Chrome")[@"volume"] doubleValue], 0.6);
    assert([FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    [app.muteButton performClick:nil];
    assert(audio.muted && [FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    assert(![FindRow(audio, @"com.google.Chrome")[@"muted"] boolValue]);
    [app.muteButton performClick:nil];
    assert(!audio.muted);
    assert(app.applicationRows[@"com.apple.Music"] == music);
    assert(app.applicationRows[@"com.google.Chrome"] == chrome);
    [app.feedbackTimer invalidate]; app.feedbackTimer = nil;
}

static void TestFailureAndGesture(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    UVApplicationRow *music = app.applicationRows[@"com.apple.Music"];
    UVApplicationRow *chrome = app.applicationRows[@"com.google.Chrome"];
    audio.rejectChanges = YES;
    [music.slider setUserValue:90];
    AssertNear(music.slider.doubleValue, 35);
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 0.35);
    assert([music.valueLabel.stringValue isEqual:UVPercentString(0.35)]);
    assert([app.applicationActionError isEqual:@"Simulated application route failure"]);
    assert([app.mixerHintLabel.stringValue isEqual:app.applicationActionError]);
    [music.muteButton performClick:nil];
    assert([FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    audio.rejectChanges = NO;

    music.slider.trackingGesture = YES;
    music.slider.changedDuringGesture = NO;
    [music.slider setUserValue:45];
    assert(music.slider.changedDuringGesture && music.slider.gestureEnded);
    assert(!app.applicationActionError.length);
    NSRect originalFrame = music.frame;
    NSSize originalSize = app.panel.contentView.bounds.size;
    // Remove the other app and insert one above the row being dragged.
    audio.snapshot = @[AppRow(@"com.apple.Safari", @"Safari", 0.7f, NO, NO),
                       FindRow(audio, @"com.apple.Music")];
    [app updateUI];
    assert(app.applicationRows[@"com.apple.Music"] == music);
    assert(app.applicationRows[@"com.google.Chrome"] == chrome);
    assert(!app.applicationRows[@"com.apple.Safari"]);
    assert(NSEqualRects(music.frame, originalFrame));
    assert(NSEqualSizes(app.panel.contentView.bounds.size, originalSize));
    music.slider.trackingGesture = NO;
    music.slider.gestureEnded();
    assert(app.applicationRows[@"com.apple.Music"] == music);
    assert(!app.applicationRows[@"com.google.Chrome"] && chrome.superview == nil);
    assert(app.applicationRows[@"com.apple.Safari"]);
    assert(music.frame.origin.y > originalFrame.origin.y);
    assert([music.stateLabel.stringValue isEqual:UVL(@"正在播放")]);
    AssertNear(music.slider.doubleValue, 45);
}

static NSEvent *KeyboardEvent(UVSlider *slider, unichar key, NSEventModifierFlags modifiers) {
    NSString *characters = [NSString stringWithCharacters:&key length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
                          timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:slider.window.windowNumber
                            context:nil characters:characters charactersIgnoringModifiers:characters
                          isARepeat:NO keyCode:0];
}

static void TestKeyboardAndDisabledControls(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    NSArray *savedSnapshot = audio.snapshot;
    float savedMaster = audio.volume;
    BOOL savedMuted = audio.muted;
    UVApplicationRow *music = app.applicationRows[@"com.apple.Music"];
    assert(music);
    [music.slider setUserValue:50];
    [music.slider keyDown:KeyboardEvent(music.slider, NSLeftArrowFunctionKey, 0)];
    AssertNear(music.slider.doubleValue, 49);
    [music.slider keyDown:KeyboardEvent(music.slider, NSRightArrowFunctionKey, 0)];
    AssertNear(music.slider.doubleValue, 50);
    [music.slider keyDown:KeyboardEvent(music.slider, NSUpArrowFunctionKey, 0)];
    AssertNear(music.slider.doubleValue, 51);
    [music.slider keyDown:KeyboardEvent(music.slider, NSDownArrowFunctionKey, 0)];
    AssertNear(music.slider.doubleValue, 50);
    [music.slider keyDown:KeyboardEvent(music.slider, NSRightArrowFunctionKey, NSEventModifierFlagShift)];
    AssertNear(music.slider.doubleValue, 60);
    [music.slider keyDown:KeyboardEvent(music.slider, NSLeftArrowFunctionKey, NSEventModifierFlagShift)];
    AssertNear(music.slider.doubleValue, 50);
    [music.slider keyDown:KeyboardEvent(music.slider, NSHomeFunctionKey, 0)];
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 0);
    [music.slider keyDown:KeyboardEvent(music.slider, NSDownArrowFunctionKey, NSEventModifierFlagShift)];
    AssertNear(music.slider.doubleValue, 0);
    [music.slider keyDown:KeyboardEvent(music.slider, NSEndFunctionKey, 0)];
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 1);
    [music.slider keyDown:KeyboardEvent(music.slider, NSUpArrowFunctionKey, NSEventModifierFlagShift)];
    AssertNear(music.slider.doubleValue, 100);
    AssertNear(audio.volume, savedMaster);
    assert(music.slider.focusRingType == NSFocusRingTypeDefault);

    // Exercise the panel's Escape route without showing or dismissing a real window.
    __block NSUInteger dismissals = 0;
    dispatch_block_t originalDismissed = app.panel.dismissed;
    app.panel.dismissed = ^{ dismissals++; };
    [music.slider keyDown:KeyboardEvent(music.slider, 0x1b, 0)];
    assert(dismissals == 1);
    app.panel.dismissed = originalDismissed;
    [app.volumeSlider keyDown:KeyboardEvent(app.volumeSlider, NSHomeFunctionKey, 0)];
    AssertNear(audio.volume, 0);
    [app.volumeSlider keyDown:KeyboardEvent(app.volumeSlider, NSEndFunctionKey, 0)];
    AssertNear(audio.volume, 1);
    [app.volumeSlider keyDown:KeyboardEvent(app.volumeSlider, NSLeftArrowFunctionKey, NSEventModifierFlagShift)];
    AssertNear(audio.volume, 0.9);
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 1);

    audio.testRunning = NO;
    [app updateUI];
    [music.slider setUserValue:12];
    [music.slider keyDown:KeyboardEvent(music.slider, NSHomeFunctionKey, 0)];
    [music.muteButton performClick:nil];
    [app.volumeSlider setUserValue:12];
    [app.volumeSlider keyDown:KeyboardEvent(app.volumeSlider, NSHomeFunctionKey, 0)];
    [app.muteButton performClick:nil];
    AssertNear(audio.volume, 0.9);
    AssertNear([FindRow(audio, @"com.apple.Music")[@"volume"] doubleValue], 1);
    assert(![FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    assert(!audio.muted);
    audio.testRunning = YES;
    audio.snapshot = savedSnapshot;
    audio.volume = savedMaster;
    audio.muted = savedMuted;
    [app.feedbackTimer invalidate]; app.feedbackTimer = nil;
    [app updateUI];
}

static NSEvent *ScrollEvent(CGScrollEventUnit unit, int32_t vertical, int32_t horizontal, CGEventFlags flags) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, unit, 2, vertical, horizontal);
    assert(event);
    CGEventSetFlags(event, flags);
    NSEvent *result = [NSEvent eventWithCGEvent:event];
    CFRelease(event);
    assert(result && result.type == NSEventTypeScrollWheel);
    return result;
}

static void TestScrollAndRouteOwnership(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    NSArray *savedSnapshot = audio.snapshot;
    float savedMaster = audio.volume;
    BOOL savedMuted = audio.muted;
    NSScrollView *originalScroll = app.applicationsScroll;
    UVMixerScrollSpy *spy = [[UVMixerScrollSpy alloc] initWithFrame:originalScroll.frame];
    originalScroll.documentView = nil;
    spy.documentView = app.applicationsContent;
    [app.panelContent replaceSubview:originalScroll with:spy];
    app.applicationsScroll = spy;
    UVApplicationRow *music = app.applicationRows[@"com.apple.Music"];
    [music.slider setUserValue:50];
    assert(music.slider.enclosingScrollView == spy);
    NSEvent *vertical = ScrollEvent(kCGScrollEventUnitLine, 3, 0, 0);
    [music.slider scrollWheel:vertical];
    assert(spy.wheelEventCount == 1 && spy.lastWheelEvent == vertical);
    AssertNear(music.slider.doubleValue, 50);
    NSEvent *horizontal = ScrollEvent(kCGScrollEventUnitLine, 0, 5, 0);
    [music.slider scrollWheel:horizontal];
    assert(spy.wheelEventCount == 2 && spy.lastWheelEvent == horizontal);
    AssertNear(music.slider.doubleValue, 50);
    NSEvent *precise = ScrollEvent(kCGScrollEventUnitPixel, 20, 0, 0);
    assert(precise.hasPreciseScrollingDeltas);
    [music.slider scrollWheel:precise];
    assert(spy.wheelEventCount == 3);
    AssertNear(music.slider.doubleValue, 50);
    [music.slider scrollWheel:ScrollEvent(kCGScrollEventUnitLine, 3, 0, kCGEventFlagMaskAlternate)];
    AssertNear(music.slider.doubleValue, 53);
    [music.slider scrollWheel:ScrollEvent(kCGScrollEventUnitLine, 0, -2, kCGEventFlagMaskAlternate)];
    AssertNear(music.slider.doubleValue, 51);
    [music.slider scrollWheel:ScrollEvent(kCGScrollEventUnitPixel, 20, 0, kCGEventFlagMaskAlternate)];
    AssertNear(music.slider.doubleValue, 54);
    assert(spy.wheelEventCount == 3);
    AssertNear(audio.volume, savedMaster);
    // Master has no enclosing list and remains directly scrollable.
    [app.volumeSlider scrollWheel:vertical];
    AssertNear(audio.volume, savedMaster + 0.03);
    AssertNear(music.slider.doubleValue, 54);
    assert(spy.wheelEventCount == 3);

    audio.testOwnership = NO; // Health monitoring has not stopped the route yet.
    [app updateUI];
    assert(audio.running && !audio.ownsDefaultOutput);
    assert(!app.volumeSlider.enabled && !app.muteButton.enabled && !app.resetApplicationsButton.enabled);
    assert(!music.slider.enabled && !music.muteButton.enabled);
    [app.volumeSlider scrollWheel:vertical];
    [app.volumeSlider keyDown:KeyboardEvent(app.volumeSlider, NSHomeFunctionKey, 0)];
    [app.muteButton performClick:nil];
    [music.slider scrollWheel:ScrollEvent(kCGScrollEventUnitLine, 10, 0, kCGEventFlagMaskAlternate)];
    [music.slider keyDown:KeyboardEvent(music.slider, NSHomeFunctionKey, 0)];
    [music.muteButton performClick:nil];
    NSUInteger resets = audio.resetCount;
    [app.resetApplicationsButton performClick:nil];
    assert(audio.resetCount == resets && !audio.muted);
    AssertNear(audio.volume, savedMaster + 0.03);
    AssertNear(music.slider.doubleValue, 54);
    [music.slider scrollWheel:vertical];
    assert(spy.wheelEventCount == 4); // Disabled faders still permit list scrolling.
    audio.testOwnership = YES;
    audio.snapshot = savedSnapshot;
    audio.volume = savedMaster;
    audio.muted = savedMuted;
    [app.feedbackTimer invalidate]; app.feedbackTimer = nil;
    spy.documentView = nil;
    originalScroll.documentView = app.applicationsContent;
    [app.panelContent replaceSubview:spy with:originalScroll];
    app.applicationsScroll = originalScroll;
    [app updateUI];
    assert(app.volumeSlider.enabled && music.slider.enabled);
}

static void AssertAccessible(NSControl *control) {
    assert(control && !control.hidden && control.frame.size.width > 0 && control.frame.size.height > 0);
    NSString *name = control.accessibilityLabel ?: control.accessibilityTitle;
    if (!name.length && [control isKindOfClass:NSButton.class]) name = ((NSButton *)control).title;
    if (!name.length) fprintf(stderr, "Unnamed control: %s\n", control.accessibilityIdentifier.UTF8String);
    assert(name.length && control.accessibilityIdentifier.length);
    assert(control.target && control.action);
    assert(NSContainsRect(control.superview.bounds, control.frame));
}

static void TestAccessibility(UVMixerTestDelegate *app) {
    for (NSControl *control in @[app.volumeSlider, app.muteButton, app.resetApplicationsButton,
                                app.browserVolumeButton, app.settingsButton]) AssertAccessible(control);
    for (UVApplicationRow *row in app.applicationRows.allValues) {
        AssertAccessible(row.slider);
        AssertAccessible(row.muteButton);
        if (row.slider.enabled) assert(row.slider.acceptsFirstResponder);
        assert([row.slider.accessibilityLabel containsString:row.nameLabel.stringValue]);
        assert([row.muteButton.accessibilityLabel containsString:row.nameLabel.stringValue]);
        assert(row.stateLabel.toolTip.length);
        assert([row.slider.accessibilityHelp containsString:row.stateLabel.toolTip]);
        assert([row.slider.toolTip isEqual:row.slider.accessibilityHelp]);
        assert(NSContainsRect(row.bounds, row.nameLabel.frame));
        assert(NSContainsRect(row.bounds, row.valueLabel.frame));
        assert(!NSIntersectsRect(row.nameLabel.frame, row.valueLabel.frame));
    }
}

static NSArray<NSDictionary *> *SnapshotWithChanges(UVMixerTestAudio *audio, NSString *identifier, NSDictionary *changes) {
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *row in audio.applications) {
        NSMutableDictionary *changed = [row mutableCopy];
        if ([row[@"id"] isEqual:identifier]) [changed addEntriesFromDictionary:changes];
        [next addObject:changed];
    }
    return next;
}

static void TestErrorLifecycle(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    NSArray *savedSnapshot = audio.snapshot;
    BOOL savedMuted = audio.muted;
    NSUInteger savedResets = audio.resetCount;
    UVApplicationRow *music = app.applicationRows[@"com.apple.Music"];
    audio.rejectChanges = YES;
    [music.slider setUserValue:53];
    assert([app.applicationActionErrorID isEqual:@"com.apple.Music"]);
    assert(!app.applicationErrorObservedInBackend && !app.mixerHintLabel.hidden);
    [app updateUI];
    assert(app.applicationActionError.length); // Do not clear a just-returned error prematurely.
    audio.snapshot = SnapshotWithChanges(audio, @"com.apple.Music", @{@"error":@"Simulated backend failure", @"applied":@NO});
    [app updateUI];
    assert(app.applicationErrorObservedInBackend);
    assert([music.stateLabel.stringValue isEqual:UVL(@"独立控制未生效")]);
    assert([music.stateLabel.toolTip isEqual:@"Simulated backend failure"]);
    audio.snapshot = savedSnapshot;
    [app updateUI];
    assert(!app.applicationActionError.length && !app.applicationActionErrorID.length);
    assert(!app.applicationErrorObservedInBackend && app.mixerHintLabel.hidden);

    [music.slider setUserValue:53];
    assert(app.applicationActionError.length);
    audio.snapshot = [audio.snapshot filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
        return ![row[@"id"] isEqual:@"com.apple.Music"];
    }]];
    [app updateUI];
    assert(!app.applicationRows[@"com.apple.Music"]);
    assert(!app.applicationActionError.length && !app.applicationActionErrorID.length);
    assert(app.mixerHintLabel.hidden);
    audio.rejectChanges = NO;
    audio.snapshot = savedSnapshot;

    // The safety warning survives resetting app gains; only a deliberate master
    // unmute clears the fallback, and it must not unmute individual applications.
    audio.snapshot = SnapshotWithChanges(audio, @"com.apple.Music", @{@"muted":@YES});
    audio.muted = YES;
    audio.testSafetyError = UVL(@"应用静音暂时失效，已静音总音量。请重试后手动取消总静音。");
    app.applicationActionError = @"Less important application error";
    [app updateUI];
    assert([app.mixerHintLabel.stringValue isEqual:audio.testSafetyError]);
    [app.resetApplicationsButton performClick:nil];
    assert(audio.muted && !app.mixerHintLabel.hidden && audio.testSafetyError.length);
    audio.snapshot = SnapshotWithChanges(audio, @"com.apple.Music", @{@"muted":@YES});
    [app.muteButton performClick:nil];
    assert(!audio.muted && !audio.testSafetyError.length && app.mixerHintLabel.hidden);
    assert([FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
    audio.snapshot = savedSnapshot;
    audio.muted = savedMuted;
    audio.resetCount = savedResets;
    [app updateUI];
}

static void TestResetAndLayout(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    NSMutableArray *many = [NSMutableArray array];
    for (NSUInteger index = 0; index < 9; index++) {
        [many addObject:AppRow([NSString stringWithFormat:@"test.application.%lu", (unsigned long)index],
                              [NSString stringWithFormat:@"Application %lu", (unsigned long)index + 1],
                              0.3f, YES, YES)];
    }
    audio.snapshot = many;
    [app updateUI];
    assert(app.applicationRows.count == 9);
    AssertNear(app.applicationsScroll.frame.size.height, 240);
    assert(app.applicationsContent.frame.size.height > app.applicationsScroll.frame.size.height);
    AssertNear(app.applicationsContent.frame.size.height, 9 * 48);
    AssertNear(app.panel.contentView.bounds.size.width, 300);
    AssertNear(app.applicationsScroll.frame.size.width, 276);
    assert(NSMaxY(app.browserVolumeButton.frame) < app.panel.contentView.bounds.size.height);
    assert(app.applicationsLabel.hidden);

    audio.muted = YES;
    [app.resetApplicationsButton performClick:nil];
    assert(audio.resetCount == 1 && audio.muted);
    AssertNear(audio.volume, 0.65);
    for (NSDictionary *row in audio.applications) {
        AssertNear([row[@"volume"] doubleValue], 1);
        assert(![row[@"muted"] boolValue]);
    }
    // Stopping master control disables every app control; existing values remain.
    audio.testRunning = NO;
    [app updateUI];
    assert(!app.volumeSlider.enabled && !app.muteButton.enabled);
    assert(!app.resetApplicationsButton.enabled && !app.errorLabel.hidden);
    for (UVApplicationRow *row in app.applicationRows.allValues) {
        assert(!row.slider.enabled && !row.muteButton.enabled);
        assert([row.stateLabel.stringValue isEqual:UVL(@"启用音量控制后可调节")]);
    }
    audio.snapshot = @[];
    [app updateUI];
    assert(app.applicationRows.count == 0 && app.emptyApplicationsLabel.hidden);
    assert(app.applicationsScroll.hidden);
    AssertNear(app.applicationsScroll.frame.size.height, 0);
    assert(!app.resetApplicationsButton.enabled);
}

static void AssertDisjointViews(NSArray<NSView *> *views) {
    for (NSUInteger index = 0; index < views.count; index++) {
        NSView *view = views[index];
        if (view.hidden) continue;
        assert(NSContainsRect(view.superview.bounds, view.frame));
        for (NSUInteger other = index + 1; other < views.count; other++) {
            NSView *peer = views[other];
            if (peer.hidden || peer.superview != view.superview) continue;
            if (NSIntersectsRect(view.frame, peer.frame)) {
                fprintf(stderr, "Overlapping views: %s %s / %s %s\n", NSStringFromClass(view.class).UTF8String,
                        NSStringFromRect(view.frame).UTF8String, NSStringFromClass(peer.class).UTF8String,
                        NSStringFromRect(peer.frame).UTF8String);
                assert(!"Visible controls and labels must not overlap.");
            }
        }
    }
}

static void AssertLabelFits(NSTextField *label) {
    if (label.hidden || !label.stringValue.length) return;
    assert(NSContainsRect(label.superview.bounds, label.frame));
    if (label.lineBreakMode == NSLineBreakByTruncatingTail ||
        label.lineBreakMode == NSLineBreakByTruncatingMiddle ||
        label.lineBreakMode == NSLineBreakByTruncatingHead) {
        assert(label.toolTip.length);
        return; // Intentional truncation has a complete, discoverable alternative.
    }
    NSSize needed = [label.cell cellSizeForBounds:NSMakeRect(0, 0, label.frame.size.width, CGFLOAT_MAX)];
    if (needed.height > label.frame.size.height + 1) {
        fprintf(stderr, "Clipped label: %s (needs %.1f, has %.1f)\n", label.stringValue.UTF8String,
                needed.height, label.frame.size.height);
        assert(!"Localized label must fit vertically.");
    }
}

static void TestProductLayout(UVMixerTestDelegate *app) {
    AssertNear(app.panel.contentView.bounds.size.width, 300);
    AssertNear(app.applicationsScroll.frame.size.width, 276);
    assert(app.applicationsScroll.frame.size.height <= 240);
    AssertDisjointViews(@[app.deviceLabel, app.settingsButton, app.masterLabel, app.masterValueLabel,
                          app.masterHintLabel, app.volumeSlider, app.muteButton]);
    AssertDisjointViews(@[app.applicationsLabel, app.resetApplicationsButton]);
    AssertDisjointViews(@[app.browserVolumeButton, app.resetApplicationsButton, app.settingsButton,
                          app.browserDetailLabel, app.mixerHintLabel]);
    assert(app.deviceLabel.hidden && app.masterHintLabel.hidden && app.browserDetailLabel.hidden);
    assert(app.applicationsLabel.hidden);
    assert(!app.browserVolumeButton.title.length && app.browserVolumeButton.image);
    for (NSTextField *label in @[app.deviceLabel, app.masterLabel, app.masterValueLabel, app.masterHintLabel,
         app.applicationsLabel, app.browserDetailLabel, app.emptyApplicationsLabel, app.mixerHintLabel])
        AssertLabelFits(label);
    for (UVApplicationRow *row in app.applicationRows.allValues) {
        AssertDisjointViews(@[row.icon, row.nameLabel, row.valueLabel, row.stateLabel, row.slider, row.muteButton]);
        AssertLabelFits(row.nameLabel);
        AssertLabelFits(row.valueLabel);
        AssertLabelFits(row.stateLabel);
    }
    assert(!app.resetApplicationsButton.title.length && app.resetApplicationsButton.image);
    assert(!app.settingsButton.title.length && app.settingsButton.image);
    assert([app.resetApplicationsButton.accessibilityLabel isEqual:UVL(@"全部恢复 100%")]);
    assert([app.settingsButton.accessibilityLabel isEqual:UVL(@"设置…")]);
}

static void SetVisualScenario(UVMixerTestDelegate *app, UVMixerTestAudio *audio, NSString *scenario) {
    app.applicationActionErrorID = nil;
    app.applicationErrorObservedInBackend = NO;
    audio.testRunning = ![scenario isEqual:@"stopped"];
    audio.muted = [scenario isEqual:@"muted"];
    audio.volume = 0.42f;
    audio.snapshot = @[AppRow(@"com.apple.Music", @"Music", 0.7f, audio.muted, YES),
                       AppRow(@"com.google.Chrome", @"Google Chrome", 0.45f, NO, YES),
                       AppRow(@"com.apple.Safari", @"Safari", 0.8f, YES, NO)];
    if ([scenario isEqual:@"empty"]) audio.snapshot = @[];
    if ([scenario isEqual:@"many"]) {
        NSMutableArray *many = [audio.snapshot mutableCopy];
        for (NSUInteger index = 4; index <= 10; index++) {
            [many addObject:AppRow([NSString stringWithFormat:@"test.application.%lu", (unsigned long)index],
                [NSString stringWithFormat:@"Application %lu — a longer application name", (unsigned long)index],
                0.3f, NO, YES)];
        }
        audio.snapshot = many;
    }
    if ([scenario isEqual:@"error"]) {
        NSMutableDictionary *failedRow = [audio.snapshot.firstObject mutableCopy];
        failedRow[@"error"] = UVL(@"无法建立音频回放。");
        failedRow[@"applied"] = @NO;
        audio.snapshot = @[failedRow, audio.snapshot[1], audio.snapshot[2]];
        app.applicationActionError = UVL(@"音频通道未就绪，或音频格式不受支持。请关闭其他音频处理软件后重试。");
    } else app.applicationActionError = nil;
    [app updateUI];
}

static void TestUnavailableSourceStates(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    audio.testRunning = YES;
    audio.muted = NO;
    app.applicationActionError = nil;
    app.applicationActionErrorID = nil;
    NSDictionary *base = AppRow(@"test.route-state", @"Audio source", 0.7f, NO, NO);
    NSMutableDictionary *row = [base mutableCopy];
    row[@"controllable"] = @NO;
    row[@"applied"] = @NO;
    audio.snapshot = @[row];
    [app updateUI];
    UVApplicationRow *view = app.applicationRows[@"test.route-state"];
    assert(!view.slider.enabled && !view.muteButton.enabled);
    assert([view.stateLabel.stringValue isEqual:UVL(@"未在播放")]);
    row = [row mutableCopy];
    row[@"active"] = @YES;
    audio.snapshot = @[row];
    [app updateUI];
    assert([view.stateLabel.stringValue isEqual:UVL(@"未输出到当前设备")]);
    row = [row mutableCopy];
    row[@"controllable"] = @YES;
    audio.snapshot = @[row];
    [app updateUI];
    assert(view.slider.enabled && view.muteButton.enabled);
    assert([view.stateLabel.stringValue isEqual:UVL(@"独立控制未生效")]);
    row = [row mutableCopy];
    row[@"applied"] = @YES;
    audio.snapshot = @[row];
    [app updateUI];
    assert([view.stateLabel.stringValue isEqual:UVL(@"正在播放")]);
    TestProductLayout(app);
    TestAccessibility(app);
}

static void TestProductStates(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    for (NSString *scenario in @[@"playing", @"empty", @"many", @"stopped", @"error", @"muted"]) {
        SetVisualScenario(app, audio, scenario);
        TestProductLayout(app);
        TestAccessibility(app);
        if ([scenario isEqual:@"empty"]) {
            assert(!app.emptyApplicationsLabel.hidden && !app.applicationRows.count);
            assert(app.applicationsScroll.hidden);
            AssertNear(app.applicationsScroll.frame.size.height, 40);
        } else if ([scenario isEqual:@"many"]) {
            assert(app.applicationRows.count == 10);
            AssertNear(app.applicationsScroll.frame.size.height, 240);
        } else if ([scenario isEqual:@"stopped"]) {
            assert(!app.volumeSlider.enabled && !app.errorLabel.hidden);
        } else if ([scenario isEqual:@"error"]) {
            assert(!app.mixerHintLabel.hidden && app.mixerHintLabel.stringValue.length);
            UVApplicationRow *failed = app.applicationRows[@"com.apple.Music"];
            assert(failed.stateLabel.stringValue.length && !failed.stateLabel.hidden);
            AssertNear(failed.frame.size.height, 64);
        } else if ([scenario isEqual:@"muted"]) {
            assert(app.masterHintLabel.hidden);
            assert([app.muteButton.accessibilityLabel isEqual:UVL(@"取消静音")]);
            assert(audio.muted && [FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
            [app.muteButton performClick:nil];
            assert(!audio.muted && [FindRow(audio, @"com.apple.Music")[@"muted"] boolValue]);
            assert(![FindRow(audio, @"com.google.Chrome")[@"muted"] boolValue]);
        } else {
            assert(app.mixerHintLabel.hidden);
            AssertNear(app.panel.contentView.bounds.size.height, 262);
            for (UVApplicationRow *row in app.applicationRows.allValues) {
                AssertNear(row.frame.size.height, 48);
                assert(row.stateLabel.hidden);
            }
        }
    }
}

static void SetTestLanguage(NSString *language) {
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"USBVolume.language":language} forName:NSArgumentDomain];
    UVRefreshLanguage();
}

static void TestRuntimeLanguageAndLongNames(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    NSString *language = UVCurrentLanguage();
    NSArray *savedSnapshot = audio.snapshot;
    NSString *longName = @"A very long application name — مشغل الموسيقى — 日本語 — 2026";
    audio.snapshot = @[AppRow(@"test.long-name", longName, 1, NO, YES)];
    [app updateUI];
    UVApplicationRow *original = app.applicationRows[@"test.long-name"];
    for (NSString *code in @[@"en", @"ar", @"fr", language]) {
        SetTestLanguage(code);
        [app updateUI];
        UVApplicationRow *row = app.applicationRows[@"test.long-name"];
        assert(row == original && [row.nameLabel.toolTip isEqual:longName]);
        BOOL rtl = [code isEqual:@"ar"];
        assert(app.panelContent.userInterfaceLayoutDirection == (rtl ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight));
        assert(row.nameLabel.alignment == (rtl ? NSTextAlignmentRight : NSTextAlignmentLeft));
        assert(app.masterLabel.alignment == (rtl ? NSTextAlignmentRight : NSTextAlignmentLeft));
        assert((NSMinX(row.icon.frame) > NSMinX(row.nameLabel.frame)) == rtl);
        assert((NSMinX(app.browserVolumeButton.frame) > NSMinX(app.settingsButton.frame)) == rtl);
        assert(row.slider.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionLeftToRight);
        assert(app.volumeSlider.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionLeftToRight);
        assert([row.valueLabel.stringValue isEqual:UVPercentString(1)]);
        assert([row.slider.accessibilityLabel containsString:UVIsolateText(longName)]);
        TestProductLayout(app);
        TestAccessibility(app);
        // Repeated refreshes must not mirror already-mirrored frames a second time.
        NSRect labelFrame = row.nameLabel.frame;
        [app updateUI];
        assert(NSEqualRects(labelFrame, row.nameLabel.frame));
    }
    audio.snapshot = savedSnapshot;
    [app updateUI];
}

static void TestSettingsLocalizedLayout(void) {
    UVMixerTestSettings *settings = [UVMixerTestSettings new];
    NSView *content = settings.window.contentView;
    for (NSNumber *detail in @[@NO, @YES]) {
        [settings setValue:detail forKey:@"showsLoginDetail"];
        NSTextField *loginStatus = [settings valueForKey:@"loginStatusLabel"];
        loginStatus.stringValue = UVL(@"待系统允许，尚未生效");
        loginStatus.hidden = !detail.boolValue;
        [[settings valueForKey:@"loginSettingsButton"] setHidden:!detail.boolValue];
        NSLayoutConstraint *top = [settings valueForKey:@"feedbackTop"];
        top.constant = detail.boolValue ? 56 : 24;
        [settings resizeForLocalizedContent];
        [content layoutSubtreeIfNeeded];
        AssertDisjointViews(content.subviews);
        for (NSView *view in content.subviews) {
            if (view.hidden) continue;
            if ([view isKindOfClass:NSButton.class]) {
                NSButton *button = (NSButton *)view;
                if (button.intrinsicContentSize.width > button.frame.size.width + 1) {
                    fprintf(stderr, "Clipped settings control: %s (needs %.1f, has %.1f)\n",
                        button.title.UTF8String, button.intrinsicContentSize.width, button.frame.size.width);
                    assert(!"Localized settings button title is clipped.");
                }
            } else if ([view isKindOfClass:NSTextField.class]) {
                NSTextField *label = (NSTextField *)view;
                CGFloat height = ceil([label.stringValue boundingRectWithSize:NSMakeSize(label.frame.size.width, CGFLOAT_MAX)
                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                    attributes:@{NSFontAttributeName:label.font}].size.height);
                if (height > label.frame.size.height + 1) {
                    fprintf(stderr, "Clipped settings label: %s (needs %.1f, has %.1f)\n",
                        label.stringValue.UTF8String, height, label.frame.size.height);
                    assert(!"Localized settings label is clipped.");
                }
            }
        }
        NSView *loginSwitch = [settings valueForKey:@"loginSwitch"];
        NSView *loginLabel = [settings valueForKey:@"loginLabel"];
        assert((NSMinX(loginSwitch.frame) < NSMinX(loginLabel.frame)) == UVIsRightToLeft());
    }
    NSString *originalLanguage = UVCurrentLanguage();
    for (NSString *language in @[@"en", @"ar", originalLanguage]) {
        SetTestLanguage(language); // The real language-change observer updates the same window.
        [content layoutSubtreeIfNeeded];
        NSView *loginSwitch = [settings valueForKey:@"loginSwitch"];
        NSView *loginLabel = [settings valueForKey:@"loginLabel"];
        assert((NSMinX(loginSwitch.frame) < NSMinX(loginLabel.frame)) == UVIsRightToLeft());
        AssertDisjointViews(content.subviews);
    }
    [settings.window close];
}

static void DrainUIFor(NSTimeInterval duration) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    while (deadline.timeIntervalSinceNow > 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
}

static void WaitForPanelState(UVMixerTestDelegate *app, BOOL shown) {
    // Allow superseded 120 ms callbacks to run before accepting the final state.
    // Then tolerate a delayed AppKit completion on a busy graphical session.
    DrainUIFor(0.15);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (deadline.timeIntervalSinceNow > 0 &&
           (app.panel.visible != shown || app.panelClosing || fabs(app.panel.alphaValue - 1) >= 0.0001))
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    assert(app.panel.visible == shown && app.panelWantedVisible == shown && !app.panelClosing);
    AssertNear(app.panel.alphaValue, 1);
}

static void TestMotionPolicy(void) {
    for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp),
         @(NSEventTypeRightMouseDown), @(NSEventTypeRightMouseUp),
         @(NSEventTypeOtherMouseDown), @(NSEventTypeOtherMouseUp)]) {
        assert(UVShouldAnimateInterface(type.unsignedIntegerValue, NO));
        assert(!UVShouldAnimateInterface(type.unsignedIntegerValue, YES));
    }
    for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp), @(NSEventTypeFlagsChanged),
         @(NSEventTypeApplicationDefined), @(NSEventTypeScrollWheel), @(NSEventTypeMouseMoved), @0]) {
        assert(!UVShouldAnimateInterface(type.unsignedIntegerValue, NO));
        assert(!UVShouldAnimateInterface(type.unsignedIntegerValue, YES));
    }
}

static void TestPanelAnimationCancellation(UVMixerTestDelegate *app, UVMixerTestAudio *audio) {
    NSDictionary *originalRows = [app.applicationRows copy];
    NSMutableDictionary *originalFrames = [NSMutableDictionary dictionary];
    for (NSString *identifier in originalRows)
        originalFrames[identifier] = [NSValue valueWithRect:app.applicationRows[identifier].frame];
    NSRect originalFrame = app.panel.frame;
    NSInteger originalLevel = app.panel.level;
    // Exercise real AppKit animations offscreen, without flashing a test panel.
    [app.panel setFrameOrigin:NSMakePoint(-10000, -10000)];
    app.panel.level = NSNormalWindowLevel;
    app.testAnimateInterface = YES;
    NSUInteger generation = app.panelAnimationGeneration;
    [app setPanelShown:YES];
    assert(app.panelAnimationGeneration > generation && app.panelWantedVisible && app.panel.visible);
    WaitForPanelState(app, YES);
    [app closePanel];
    assert(!app.panelWantedVisible && app.panelClosing);
    WaitForPanelState(app, NO);

    // An old closing callback must never hide a newly reopened panel.
    [app setPanelShown:YES];
    DrainUIFor(0.025);
    [app setPanelShown:NO];
    NSUInteger closingGeneration = app.panelAnimationGeneration;
    [app setPanelShown:YES];
    assert(app.panelAnimationGeneration > closingGeneration);
    WaitForPanelState(app, YES);
    [app setPanelShown:NO];
    [app setPanelShown:YES];
    [app setPanelShown:NO];
    WaitForPanelState(app, NO);

    // Keyboard/reduced-motion policy settles synchronously, including while a
    // prior mouse fade is pending. Its stale completion cannot change visibility.
    app.testAnimateInterface = NO;
    [app setPanelShown:YES];
    assert(app.panelWantedVisible && app.panel.visible && !app.panelClosing);
    AssertNear(app.panel.alphaValue, 1);
    [app setPanelShown:NO];
    assert(!app.panelWantedVisible && !app.panel.visible && !app.panelClosing);
    AssertNear(app.panel.alphaValue, 1);
    app.testAnimateInterface = YES;
    [app setPanelShown:YES];
    [app setPanelShown:NO];
    app.testAnimateInterface = NO;
    [app setPanelShown:YES];
    AssertNear(app.panel.alphaValue, 1);
    WaitForPanelState(app, YES);
    [app setPanelShown:NO];
    assert(!app.panel.visible && !app.panelClosing);

    // Escape / reduced motion must interrupt an already-running close through
    // the actual closePanel entry point, rather than waiting for its fade timer.
    [app setPanelShown:YES];
    app.testAnimateInterface = YES;
    [app closePanel];
    assert(app.panelClosing && app.panel.visible);
    NSUInteger interruptedGeneration = app.panelAnimationGeneration;
    app.testAnimateInterface = NO;
    [app closePanel];
    assert(app.panelAnimationGeneration > interruptedGeneration);
    assert(!app.panelWantedVisible && !app.panel.visible && !app.panelClosing);
    AssertNear(app.panel.alphaValue, 1); // Must already be final, without draining the run loop.
    WaitForPanelState(app, NO);

    // A process-list update during dismissal must not resize the fading panel
    // or rebuild/reposition its rows. Reopening applies the pending snapshot.
    NSArray *savedSnapshot = audio.snapshot;
    [app setPanelShown:YES];
    NSRect closingFrame = app.panel.frame;
    app.testAnimateInterface = YES;
    [app closePanel];
    assert(app.panelClosing);
    NSMutableArray *newSnapshot = [savedSnapshot mutableCopy];
    for (NSUInteger index = 0; index < 8; index++) {
        [newSnapshot addObject:AppRow([NSString stringWithFormat:@"test.arrival.%lu", (unsigned long)index],
                                    @"Arriving application", 0.4f, NO, YES)];
    }
    audio.snapshot = newSnapshot;
    [app updateUI];
    [app updateApplicationRowsAtY:76];
    assert(NSEqualRects(app.panel.frame, closingFrame));
    assert(app.applicationRows.count == originalRows.count);
    for (NSString *identifier in originalRows) {
        assert(app.applicationRows[identifier] == originalRows[identifier]);
        assert(NSEqualRects(app.applicationRows[identifier].frame, [originalFrames[identifier] rectValue]));
    }
    [app setPanelShown:YES];
    assert(!app.panelClosing);
    [app updateUI];
    assert(app.applicationRows.count == newSnapshot.count);
    assert(app.panel.frame.size.height > closingFrame.size.height);
    for (NSString *identifier in originalRows) assert(app.applicationRows[identifier] == originalRows[identifier]);
    WaitForPanelState(app, YES);
    audio.snapshot = savedSnapshot;
    [app updateUI];
    app.testAnimateInterface = NO;
    [app closePanel];
    assert(!app.panel.visible && !app.panelClosing);

    // Opening and closing must not rebuild or reposition the application rows.
    assert(app.applicationRows.count == originalRows.count);
    for (NSString *identifier in originalRows) {
        assert(app.applicationRows[identifier] == originalRows[identifier]);
        assert(NSEqualRects(app.applicationRows[identifier].frame, [originalFrames[identifier] rectValue]));
    }
    app.panel.level = originalLevel;
    [app.panel setFrame:originalFrame display:NO];
}

static void RemoveClickMonitors(UVMixerTestDelegate *app) {
    if (app.localClickMonitor) [NSEvent removeMonitor:app.localClickMonitor];
    if (app.globalClickMonitor) [NSEvent removeMonitor:app.globalClickMonitor];
    app.localClickMonitor = nil;
    app.globalClickMonitor = nil;
}

static BOOL WriteNativeScreenshot(UVMixerTestDelegate *app, NSString *path) {
    NSView *content = app.panel.contentView;
    [app updateUI];
    [content layoutSubtreeIfNeeded];
    [app.panel display];
    NSBitmapImageRep *bitmap = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError *error = nil;
    if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "Screenshot failed: %s\n", error.localizedDescription.UTF8String ?: "No image data");
        return NO;
    }
    printf("Native mixer screenshot: %s (active application, key panel)\n", path.UTF8String);
    return YES;
}

static void StopScreenshotRunLoop(void) {
    [NSApp stop:nil];
    // stop: called by a timer needs an event to wake NSApplication's event fetch.
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
        modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
        subtype:0 data1:0 data2:0];
    [NSApp postEvent:wake atStart:NO];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL show = NO;
        BOOL skipMotion = NO;
        NSString *screenshotPath = nil;
        NSString *language = @"en";
        NSString *appearance = @"light";
        NSString *scenario = @"playing";
        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqual:@"--show"]) show = YES;
            else if ([argument isEqual:@"--skip-motion"]) skipMotion = YES;
            else if ([argument isEqual:@"--screenshot"] && index + 1 < argc)
                screenshotPath = [NSString stringWithUTF8String:argv[++index]];
            else if ([argument isEqual:@"--language"] && index + 1 < argc)
                language = [NSString stringWithUTF8String:argv[++index]];
            else if ([argument isEqual:@"--appearance"] && index + 1 < argc)
                appearance = [NSString stringWithUTF8String:argv[++index]];
            else if ([argument isEqual:@"--scenario"] && index + 1 < argc)
                scenario = [NSString stringWithUTF8String:argv[++index]];
            else { fprintf(stderr, "Usage: MixerUIState [--show] [--language en|zh-Hans|…] [--appearance light|dark] [--scenario playing|empty|many|stopped|error|muted] [--screenshot /path/to/mixer.png]\n"); return 2; }
        }
        if (![@[@"light", @"dark"] containsObject:appearance] ||
            ![@[@"playing", @"empty", @"many", @"stopped", @"error", @"muted"] containsObject:scenario] ||
            ![[UVAvailableLanguages() valueForKey:@"code"] containsObject:language]) {
            fprintf(stderr, "Unknown language, appearance, or scenario.\n");
            return 2;
        }
        // Argument-domain overrides are in-memory and do not alter app preferences.
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"USBVolume.language":language}
                                                       forName:NSArgumentDomain];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSApp.appearance = [NSAppearance appearanceNamed:[appearance isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        UVMixerTestAudio *audio = [UVMixerTestAudio new];
        audio.testRunning = YES;
        audio.volume = 0.4f;
        UVMixerTestDelegate *app = [UVMixerTestDelegate new];
        app.audio = audio;
        app.knownDevices = @[@{@"uid":@"ui-test", @"name":@"UI test speakers", @"isUSB":@YES, @"id":@1}];
        app.selectedUID = @"ui-test";
        NSApp.delegate = app;
        [app buildPanel];
        RemoveClickMonitors(app);
        [app updateUI];
        TestIndependentActions(app, audio);
        TestFailureAndGesture(app, audio);
        TestKeyboardAndDisabledControls(app, audio);
        TestScrollAndRouteOwnership(app, audio);
        TestAccessibility(app);
        TestErrorLifecycle(app, audio);
        TestResetAndLayout(app, audio);
        TestProductStates(app, audio);
        TestUnavailableSourceStates(app, audio);
        TestRuntimeLanguageAndLongNames(app, audio);
        TestSettingsLocalizedLayout();
        TestMotionPolicy();
        if (!skipMotion) TestPanelAnimationCancellation(app, audio);
        NSString *effectiveAppearance = [app.panel.effectiveAppearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        assert([effectiveAppearance isEqual:[appearance isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua]);
        assert([UVCurrentLanguage() isEqual:language]);
        printf("Mixer UI state [%s, %s]: passed (independent actions, failure rollback, stable rows, gestures, keyboard, scroll, ownership, accessibility, reset, layout, standby, motion policy).\n", language.UTF8String, appearance.UTF8String);
        fflush(stdout);
        if (show || screenshotPath.length) {
            SetVisualScenario(app, audio, scenario);
            app.panel.title = @"USB Volume Mixer · UI test";
            [app.panel center];
            [NSApp activateIgnoringOtherApps:YES];
            [app.panel makeKeyAndOrderFront:nil];
            [app.panel makeFirstResponder:app.volumeSlider];
            // A normal application menu makes the visual fixture easy to quit.
            NSMenu *menu = [NSMenu new];
            NSMenuItem *root = [NSMenuItem new];
            NSMenu *testMenu = [[NSMenu alloc] initWithTitle:@"USB Volume UI Test"];
            [testMenu addItemWithTitle:@"Quit UI Test" action:@selector(terminate:) keyEquivalent:@"q"];
            root.submenu = testMenu;
            [menu addItem:root];
            NSApp.mainMenu = menu;
            __block BOOL screenshotWritten = NO;
            if (screenshotPath.length) {
                __block NSUInteger attempts = 0;
                __block NSUInteger activeTicks = 0;
                // cacheDisplay preserves native control rendering, including its
                // inactive gray state. Wait for NSApplication to launch, process
                // activation events, and make this panel key before exporting.
                [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
                    attempts++;
                    if (NSApp.active && app.panel.keyWindow) activeTicks++;
                    else activeTicks = 0;
                    if (activeTicks >= 2) {
                        [timer invalidate];
                        screenshotWritten = WriteNativeScreenshot(app, screenshotPath);
                        if (!show) StopScreenshotRunLoop();
                    } else if (attempts >= 40) {
                        [timer invalidate];
                        fprintf(stderr, "Screenshot failed: UI fixture did not become active with a key panel.\n");
                        if (!show) StopScreenshotRunLoop();
                    }
                }];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp activateIgnoringOtherApps:YES];
                [app.panel makeKeyAndOrderFront:nil];
            });
            [NSApp run];
            if (screenshotPath.length && !screenshotWritten) return 1;
        }
        [app.feedbackTimer invalidate];
        [app.panel orderOut:nil];
        app.panel.delegate = nil;
        NSApp.delegate = nil;
    }
    return 0;
}
