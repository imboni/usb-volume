// Exercise device-arrival decisions with in-memory routes. These tests do not
// launch the application, access audio hardware, request permissions, or write
// preferences. The real delegate runs against fake audio, keys, and prompts.
#define main UVApplicationMain
#import "../Sources/main.m"
#undef main
#include <assert.h>

@interface UVDetectionTestAudio : UVAudioController
@property(nonatomic) NSArray<NSDictionary *> *snapshot;
@property(nonatomic) BOOL testRunning;
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) NSUInteger stopCount;
@property(nonatomic) NSUInteger monitoringStarts;
@property(nonatomic) NSUInteger monitoringStops;
@property(nonatomic, copy) NSString *startedUID;
@end

@implementation UVDetectionTestAudio
- (NSArray<NSDictionary *> *)devices { return self.snapshot ?: @[]; }
- (BOOL)running { return self.testRunning; }
- (BOOL)ownsDefaultOutput { return self.testRunning; }
- (BOOL)startDeviceUID:(NSString *)uid error:(NSError **)error {
    (void)error;
    self.startCount++;
    self.startedUID = uid;
    self.testRunning = YES;
    return YES;
}
- (void)stop { self.stopCount++; self.testRunning = NO; }
- (BOOL)startMonitoringDevices { self.monitoringStarts++; return YES; }
- (void)stopMonitoringDevices { self.monitoringStops++; }
@end

@interface UVDetectionTestKeys : UVMediaKeys
@property(nonatomic) BOOL testActive;
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) NSUInteger stopCount;
@end

@implementation UVDetectionTestKeys
- (BOOL)active { return self.testActive; }
- (BOOL)needsPermission { return NO; }
- (BOOL)start { self.startCount++; self.testActive = YES; return YES; }
- (void)stop { self.stopCount++; self.testActive = NO; }
- (void)requestPermission { assert(!"Device detection must not request permission."); }
@end

@interface UVDetectionTestDelegate : UVAppDelegate
@property(nonatomic) BOOL detectionEnabled;
@property(nonatomic) NSUInteger promptCount;
@property(nonatomic) NSUInteger preferenceSaves;
@property(nonatomic) NSUInteger pauseConfirmations;
@property(nonatomic, copy) NSString *promptedUID;
@end

@implementation UVDetectionTestDelegate
- (BOOL)automaticDetectionEnabled { return self.detectionEnabled; }
- (void)saveSelectedDevice { self.preferenceSaves++; }
- (void)presentConnectionPromptForDevice:(NSDictionary *)device {
    self.promptCount++;
    self.promptedUID = device[@"uid"];
}
- (void)updateUI {}
- (void)closePanel {}
- (BOOL)confirmRestoringOutputForQuit:(BOOL)quit {
    assert(!quit);
    self.pauseConfirmations++;
    return YES;
}
@end

static NSDictionary *DeviceWithID(NSString *uid, BOOL usb, NSUInteger deviceID) {
    return @{@"id":@(deviceID), @"uid":uid, @"name":uid, @"isUSB":@(usb)};
}

static NSDictionary *Device(NSString *uid, BOOL usb) {
    return DeviceWithID(uid, usb, 1);
}

static UVDetectionTestDelegate *App(NSArray<NSDictionary *> *devices) {
    UVDetectionTestDelegate *app = [UVDetectionTestDelegate new];
    UVDetectionTestAudio *audio = [UVDetectionTestAudio new];
    audio.snapshot = devices;
    app.audio = audio;
    app.mediaKeys = [UVDetectionTestKeys new];
    app.detectionEnabled = YES;
    app.observedUSBUIDs = [NSSet set];
    return app;
}

static UVDetectionTestAudio *Audio(UVDetectionTestDelegate *app) {
    return (UVDetectionTestAudio *)app.audio;
}

static UVDetectionTestKeys *Keys(UVDetectionTestDelegate *app) {
    return (UVDetectionTestKeys *)app.mediaKeys;
}

static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
    assert(drained && "Queued starts did not finish within the test deadline.");
}

static void TestArrivalAndDecline(void) {
    NSDictionary *builtIn = Device(@"built-in", NO);
    NSDictionary *display = Device(@"display", NO);
    NSDictionary *speaker = Device(@"usb-a", YES);
    UVDetectionTestDelegate *app = App(@[builtIn, display]);
    [app refreshDevices];
    assert(app.promptCount == 0 && app.pendingDeviceUID == nil);
    Audio(app).snapshot = @[builtIn, display, speaker];
    [app refreshDevices];
    assert(app.promptCount == 1 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    assert(Audio(app).startCount == 0 && app.selectedUID == nil);
    [app declineDetectedDevice:nil];
    [app refreshDevices];
    [app refreshDevices];
    assert(app.promptCount == 1 && Audio(app).startCount == 0);
    Audio(app).snapshot = @[builtIn, display];
    [app refreshDevices];
    Audio(app).snapshot = @[builtIn, display, speaker];
    [app refreshDevices];
    assert(app.promptCount == 2 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    assert(Audio(app).startCount == 0);
}

static void TestAcceptanceStartsOnce(void) {
    UVDetectionTestDelegate *app = App(@[Device(@"usb-a", YES)]);
    [app refreshDevices];
    assert(Audio(app).startCount == 0);
    [app enableDetectedDevice:nil];
    assert(app.performingStart && Audio(app).startCount == 0);
    assert(app.preferenceSaves == 1 && [app.selectedUID isEqual:@"usb-a"]);
    assert(app.pendingDeviceUID == nil);
    DrainMainQueue();
    assert(!app.performingStart && Audio(app).running);
    assert(Audio(app).startCount == 1 && [Audio(app).startedUID isEqual:@"usb-a"]);
    assert(Keys(app).startCount == 1);
    [app enableDetectedDevice:nil];
    [app refreshDevices];
    DrainMainQueue();
    assert(Audio(app).startCount == 1 && app.promptCount == 1);
}

static void TestDisconnectedPromptCannotStart(void) {
    UVDetectionTestDelegate *app = App(@[Device(@"usb-a", YES)]);
    [app refreshDevices];
    Audio(app).snapshot = @[];
    // Simulate acceptance before a device notification has refreshed the UI.
    [app enableDetectedDevice:nil];
    DrainMainQueue();
    assert(app.pendingDeviceUID == nil && !app.performingStart);
    assert(Audio(app).startCount == 0 && app.preferenceSaves == 0);
    assert(Keys(app).startCount == 0);
}

static void TestDetectionPreference(void) {
    UVDetectionTestDelegate *app = App(@[Device(@"usb-a", YES)]);
    [app refreshDevices];
    app.detectionEnabled = NO;
    [app automaticDetectionChanged];
    assert(app.pendingDeviceUID == nil && !app.monitoringDevices);
    assert(Audio(app).monitoringStops == 1);
    [app enableDetectedDevice:nil];
    [app refreshDevices];
    DrainMainQueue();
    assert(app.promptCount == 1 && Audio(app).startCount == 0);
    app.detectionEnabled = YES;
    [app automaticDetectionChanged];
    assert(app.monitoringDevices && Audio(app).monitoringStarts == 1);
    assert(app.promptCount == 2 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    assert(Audio(app).startCount == 0);
}

static void TestActiveRouteAndDisconnection(void) {
    NSDictionary *a = Device(@"usb-a", YES);
    NSDictionary *b = Device(@"usb-b", YES);
    UVDetectionTestDelegate *app = App(@[a]);
    app.selectedUID = @"usb-a";
    app.observedUSBUIDs = [NSSet setWithObject:@"usb-a"];
    Audio(app).testRunning = YES;
    Keys(app).testActive = YES;
    app.mediaKeys.enabled = YES;
    app.mediaKeyRouteOwned = YES;
    Audio(app).snapshot = @[a, b];
    [app refreshDevices];
    assert(app.promptCount == 0 && Audio(app).running && [app.selectedUID isEqual:@"usb-a"]);
    assert(Audio(app).stopCount == 0 && Audio(app).startCount == 0);
    // Disconnect safety also applies with connection prompting disabled.
    app.detectionEnabled = NO;
    Audio(app).snapshot = @[b];
    [app refreshDevices];
    assert(!Audio(app).running && Audio(app).stopCount == 1);
    assert(!Keys(app).active && Keys(app).stopCount == 1);
    assert(!app.mediaKeys.enabled && !app.mediaKeyRouteOwned);
    assert(app.promptCount == 0 && Audio(app).startCount == 0);
}

static void TestPauseDoesNotRestart(void) {
    UVDetectionTestDelegate *app = App(@[Device(@"usb-a", YES)]);
    app.selectedUID = @"usb-a";
    app.observedUSBUIDs = [NSSet setWithObject:@"usb-a"];
    Audio(app).testRunning = YES;
    [app refreshDevices];
    [app toggleAudio:nil];
    assert(app.pauseConfirmations == 1 && !Audio(app).running);
    assert(Audio(app).stopCount == 1);
    [app refreshDevices];
    [app refreshDevices];
    for (NSUInteger index = 0; index < 8; index++) [app poll:nil];
    DrainMainQueue();
    assert(app.promptCount == 0 && Audio(app).startCount == 0 && Keys(app).startCount == 0);
}

static void TestQueuedStartRechecksPresence(void) {
    UVDetectionTestDelegate *app = App(@[Device(@"usb-a", YES)]);
    app.detectionEnabled = NO;
    app.selectedUID = @"usb-a";
    [app refreshDevices];
    [app startAudio];
    assert(app.performingStart);
    Audio(app).snapshot = @[];
    // Do not refresh explicitly: the delayed start itself must notice removal.
    DrainMainQueue();
    assert(!app.performingStart && !Audio(app).running && Audio(app).startCount == 0);
    assert(Keys(app).startCount == 0);

    Audio(app).snapshot = @[Device(@"usb-a", YES)];
    [app refreshDevices];
    [app startAudio];
    Audio(app).snapshot = @[];
    [app refreshDevices];
    DrainMainQueue();
    assert(!app.performingStart && Audio(app).startCount == 0);
}

static void TestQueuedStartCannotReplaceNewSelection(void) {
    UVDetectionTestDelegate *app = App(@[Device(@"usb-a", YES), Device(@"usb-b", YES)]);
    app.detectionEnabled = NO;
    app.selectedUID = @"usb-a";
    [app refreshDevices];
    [app startAudio];
    NSMenuItem *choice = [[NSMenuItem alloc] initWithTitle:@"USB B" action:nil keyEquivalent:@""];
    choice.representedObject = @"usb-b";
    [app chooseDevice:choice];
    DrainMainQueue();
    assert(Audio(app).startCount == 1 && [Audio(app).startedUID isEqual:@"usb-b"]);
    assert([app.selectedUID isEqual:@"usb-b"] && !app.performingStart);
    assert(Keys(app).startCount == 1);
}

static void TestStandbyDoesNotStartKeyboardTap(void) {
    UVDetectionTestDelegate *app = App(@[]);
    for (NSUInteger index = 0; index < 12; index++) [app poll:nil];
    assert(app.promptCount == 0 && Audio(app).startCount == 0 && Keys(app).startCount == 0);
    app.detectionEnabled = NO;
    Audio(app).snapshot = @[Device(@"usb-a", YES)];
    for (NSUInteger index = 0; index < 12; index++) [app poll:nil];
    assert(app.promptCount == 0 && Audio(app).startCount == 0 && Keys(app).startCount == 0);
}

static void TestReplacedActiveDeviceStopsAndOffersAgain(void) {
    UVDetectionTestDelegate *app = App(@[DeviceWithID(@"usb-a", YES, 10)]);
    [app refreshDevices];
    [app enableDetectedDevice:nil];
    DrainMainQueue();
    assert(Audio(app).running && Audio(app).startCount == 1);
    // A quick unplug/replug can preserve the UID without exposing an empty
    // snapshot. The changed HAL object must invalidate the old audio route.
    Audio(app).snapshot = @[DeviceWithID(@"usb-a", YES, 11)];
    [app refreshDevices];
    assert(!Audio(app).running && Audio(app).stopCount == 1);
    assert(!Keys(app).active && Keys(app).stopCount == 1);
    assert(app.promptCount == 2 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    assert([app.pendingDeviceID isEqual:@11]);
    DrainMainQueue();
    assert(Audio(app).startCount == 1); // replacement still requires consent
}

static void TestReplacedPromptNeedsFreshConfirmation(void) {
    UVDetectionTestDelegate *app = App(@[DeviceWithID(@"usb-a", YES, 10)]);
    [app refreshDevices];
    NSUInteger oldGeneration = app.connectionPromptGeneration;
    Audio(app).snapshot = @[DeviceWithID(@"usb-a", YES, 11)];
    // An old confirmation arrives before the replacement notification. The
    // handler's refresh must offer the new instance, without accepting it.
    [app enableDetectedDevice:nil];
    DrainMainQueue();
    assert(app.connectionPromptGeneration != oldGeneration);
    assert(app.promptCount == 2 && [app.pendingDeviceID isEqual:@11]);
    assert(Audio(app).startCount == 0 && app.preferenceSaves == 0);
    assert(!app.performingStart && Keys(app).startCount == 0);
    // A sender from an obsolete window is not allowed to accept or decline
    // the current offer. No AppKit window is created for this check.
    NSObject *obsoleteButton = [NSObject new];
    [app enableDetectedDevice:obsoleteButton];
    [app declineDetectedDevice:obsoleteButton];
    assert(app.promptCount == 2 && [app.pendingDeviceID isEqual:@11]);
    assert(Audio(app).startCount == 0 && app.preferenceSaves == 0);
    [app enableDetectedDevice:nil];
    DrainMainQueue();
    assert(Audio(app).startCount == 1 && Audio(app).running);
    assert(app.preferenceSaves == 1 && app.pendingDeviceUID == nil);
}

static void TestQueuedStartRejectsReplacedInstance(void) {
    UVDetectionTestDelegate *app = App(@[DeviceWithID(@"usb-a", YES, 10)]);
    [app refreshDevices];
    [app enableDetectedDevice:nil];
    assert(app.performingStart && Audio(app).startCount == 0);
    Audio(app).snapshot = @[DeviceWithID(@"usb-a", YES, 11)];
    DrainMainQueue();
    assert(!app.performingStart && !Audio(app).running);
    assert(Audio(app).startCount == 0 && Keys(app).startCount == 0);
    assert(app.promptCount == 2 && [app.pendingDeviceID isEqual:@11]);
    [app enableDetectedDevice:nil];
    DrainMainQueue();
    assert(Audio(app).startCount == 1 && Audio(app).running);
}

static void TestNewArrivalWaitsBehindExistingPrompt(void) {
    NSDictionary *a = DeviceWithID(@"usb-a", YES, 10);
    NSDictionary *b = DeviceWithID(@"usb-b", YES, 20);
    UVDetectionTestDelegate *app = App(@[a]);
    [app refreshDevices];
    assert(app.promptCount == 1 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    Audio(app).snapshot = @[a, b];
    [app refreshDevices];
    assert(app.promptCount == 1 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    assert([app.unofferedDeviceUIDs containsObject:@"usb-b"]);
    [app declineDetectedDevice:nil];
    assert(app.promptCount == 2 && [app.pendingDeviceUID isEqual:@"usb-b"]);
    [app declineDetectedDevice:nil];
    [app refreshDevices];
    [app refreshDevices];
    assert(app.promptCount == 2 && app.pendingDeviceUID == nil);
    assert(app.unofferedDeviceUIDs.count == 0 && Audio(app).startCount == 0);
}

static void TestRememberedDeviceHasFirstOffer(void) {
    UVDetectionTestDelegate *app = App(@[
        DeviceWithID(@"usb-b", YES, 20),
        DeviceWithID(@"usb-z-remembered", YES, 30),
        DeviceWithID(@"usb-a", YES, 10)
    ]);
    app.selectedUID = @"usb-z-remembered";
    [app refreshDevices];
    assert(app.promptCount == 1 && [app.pendingDeviceUID isEqual:@"usb-z-remembered"]);
    assert(Audio(app).startCount == 0);
    [app declineDetectedDevice:nil];
    assert(app.promptCount == 2 && [app.pendingDeviceUID isEqual:@"usb-a"]);
    [app declineDetectedDevice:nil];
    assert(app.promptCount == 3 && [app.pendingDeviceUID isEqual:@"usb-b"]);
    [app declineDetectedDevice:nil];
    [app refreshDevices];
    assert(app.promptCount == 3 && app.pendingDeviceUID == nil);
    assert(Audio(app).startCount == 0 && app.preferenceSaves == 0);
}

int main(void) {
    @autoreleasepool {
        TestArrivalAndDecline();
        TestAcceptanceStartsOnce();
        TestDisconnectedPromptCannotStart();
        TestDetectionPreference();
        TestActiveRouteAndDisconnection();
        TestPauseDoesNotRestart();
        TestQueuedStartRechecksPresence();
        TestQueuedStartCannotReplaceNewSelection();
        TestStandbyDoesNotStartKeyboardTap();
        TestReplacedActiveDeviceStopsAndOffersAgain();
        TestReplacedPromptNeedsFreshConfirmation();
        TestQueuedStartRejectsReplacedInstance();
        TestNewArrivalWaitsBehindExistingPrompt();
        TestRememberedDeviceHasFirstOffer();
        puts("Device detection state: passed (USB arrivals, consent, reconnect, preferences, route safety, queued starts, standby, instance replacement, prompt queue).");
    }
    return 0;
}
