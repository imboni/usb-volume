// Exercise actual route planning, persistence and PCM gain with a fake HAL.
// No audio hardware, permission prompt or user preferences are accessed.
#import "../Sources/AudioController.m"
#include <assert.h>

@interface UVMemoryDefaults : NSUserDefaults
@property(nonatomic) NSMutableDictionary *values;
@end
@implementation UVMemoryDefaults
- (NSDictionary *)dictionaryForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)object forKey:(NSString *)key { self.values[key] = object; }
@end
static UVMemoryDefaults *testDefaults;
static NSMutableArray<NSString *> *events;

@interface UVFakeApplicationRoute : UVApplicationRoute
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL healthy;
@property(nonatomic) BOOL failActivation;
- (float)renderGain;
- (float)renderFirstSample;
@end
@implementation UVFakeApplicationRoute
- (BOOL)healthyAtRate:(double)rate { (void)rate; return self.healthy && !self.stopped; }
- (BOOL)activateMuting:(NSError **)error {
    if (self.failActivation && error) *error = Failure(@"无法建立音频回放。", -52);
    return !self.failActivation;
}
- (float)renderGain {
    float samples[2048], output[2048];
    for (NSUInteger i = 0; i < 2048; i++) samples[i] = 1;
    AudioBufferList input = {1, {{2, sizeof(samples), samples}}};
    AudioBufferList result = {1, {{2, sizeof(output), output}}};
    VDProcess(self.dsp, &input, &result);
    return output[2047];
}
- (float)renderFirstSample {
    float input[2] = {1, 1}, output[2];
    AudioBufferList in = {1, {{2, sizeof(input), input}}};
    AudioBufferList out = {1, {{2, sizeof(output), output}}};
    VDProcess(self.dsp, &in, &out);
    return output[0];
}
- (void)stop {
    if (!self.stopped) [events addObject:@"stop"];
    self.stopped = YES;
    [super stop];
}
@end

@interface UVApplicationTestAudio : UVAudioController
@property(nonatomic) NSArray<NSDictionary *> *discovery;
@property(nonatomic) NSMutableArray<UVFakeApplicationRoute *> *created;
@property(nonatomic) NSArray<NSNumber *> *excluded;
@property(nonatomic) BOOL failDiscovery;
@property(nonatomic) BOOL failPrepare;
@property(nonatomic) BOOL failActivation;
@property(nonatomic) BOOL failExclusions;
@property(nonatomic) NSSet<NSNumber *> *failedProcesses;
@property(nonatomic) NSTimeInterval clock;
@end
@implementation UVApplicationTestAudio
- (NSUserDefaults *)applicationDefaults { return testDefaults; }
- (NSTimeInterval)routingTime { return self.clock; }
- (NSArray<NSDictionary *> *)discoverApplications { return self.failDiscovery ? nil : self.discovery ?: @[]; }
- (UVApplicationRoute *)prepareApplicationRoute:(NSArray<NSNumber *> *)processes error:(NSError **)error {
    [events addObject:@"prepare"];
    if (self.failPrepare || [self.failedProcesses intersectsSet:[NSSet setWithArray:processes]]) {
        if (error) *error = Failure(@"无法建立音频回放。", -50);
        return nil;
    }
    UVFakeApplicationRoute *route = [UVFakeApplicationRoute new];
    route.processes = processes;
    route.healthy = YES;
    route.failActivation = self.failActivation;
    route.dsp = VDCreate(48000, 0);
    [self.created addObject:route];
    return route;
}
- (BOOL)setMasterExclusions:(NSArray<NSNumber *> *)processes error:(NSError **)error {
    [events addObject:@"exclude"];
    if (self.failExclusions) {
        if (error) *error = Failure(@"无法建立音频回放。", -51);
        return NO;
    }
    self.excluded = processes;
    return YES;
}
@end

static NSDictionary *Source(NSString *identifier, NSArray<NSNumber *> *processes) {
    return @{@"id":identifier, @"name":identifier, @"bundleID":identifier,
             @"active":@YES, @"processes":processes};
}
static UVApplicationTestAudio *Audio(void) {
    UVApplicationTestAudio *audio = [UVApplicationTestAudio new];
    audio.created = [NSMutableArray array];
    audio.clock = 100;
    [audio setValue:@YES forKey:@"running"];
    [audio setValue:@999 forKey:@"ownProcess"];
    [audio setValue:@48000 forKey:@"sampleRate"];
    audio.volume = 0.5;
    audio.discovery = @[Source(@"music", @[@10]), Source(@"browser", @[@20, @21])];
    [audio refreshApplications];
    return audio;
}
static void Close(float actual, float expected) { assert(fabsf(actual - expected) < 0.00001f); }

int main(void) {
    @autoreleasepool {
        // An embedded browser helper resolves to the parent app, while a
        // shared system service with no .app path does not get guessed as Safari.
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        NSURL *outer = [directory URLByAppendingPathComponent:@"Browser.app"];
        NSURL *inner = [outer URLByAppendingPathComponent:@"Contents/Frameworks/Helper.app"];
        NSFileManager *files = NSFileManager.defaultManager;
        assert([files createDirectoryAtURL:[inner URLByAppendingPathComponent:@"Contents"] withIntermediateDirectories:YES attributes:nil error:nil]);
        assert(([@{@"CFBundleIdentifier":@"test.browser", @"CFBundleName":@"Browser"}
            writeToURL:[outer URLByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]));
        assert([@{@"CFBundleIdentifier":@"test.browser.helper"}
            writeToURL:[inner URLByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]);
        assert([ApplicationBundle(inner).bundleIdentifier isEqual:@"test.browser"]);
        assert(!ApplicationBundle([NSURL fileURLWithPath:@"/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc"]));
        [files removeItemAtURL:directory error:nil];
        testDefaults = [UVMemoryDefaults new]; testDefaults.values = [NSMutableDictionary dictionary];
        events = [NSMutableArray array];
        UVApplicationTestAudio *audio = Audio();
        assert(audio.applications.count == 2 && audio.created.count == 0);
        assert([audio.applications[0][@"volume"] floatValue] == 1);
        assert([audio setApplicationVolume:0.5 forID:@"music" error:nil]);
        assert(audio.created.count == 1);
        assert(([events isEqual:@[@"prepare", @"exclude"]]));
        UVFakeApplicationRoute *music = audio.created.lastObject;
        Close([music renderGain], 0.0625); // (master 0.5)^2 * (app 0.5)^2
        assert(([audio.excluded isEqual:@[@10, @999]]));
        assert([audio setApplicationVolume:0.25 forID:@"browser" error:nil]);
        UVFakeApplicationRoute *browser = audio.created.lastObject;
        Close([browser renderGain], 0.015625);
        Close([music renderGain], 0.0625); // another app is unaffected
        audio.volume = 0.8;
        Close([music renderGain], 0.16);
        Close([browser renderGain], 0.04);
        audio.muted = YES;
        Close([music renderGain], 0); Close([browser renderGain], 0);
        audio.muted = NO;
        assert([audio setApplicationMuted:YES forID:@"music" error:nil]);
        Close([music renderGain], 0); Close([browser renderGain], 0.04);
        assert([audio setApplicationMuted:NO forID:@"music" error:nil]);
        Close([music renderGain], 0.16);
        assert([audio setApplicationVolume:NAN forID:@"music" error:nil]);
        Close([music renderGain], 0);
        assert([audio setApplicationVolume:2 forID:@"music" error:nil]);
        Close([music renderGain], 0.64);
        assert(audio.created.count == 2); // slider/100%/mute never rebuild a route
        NSError *error = nil;
        assert(![audio setApplicationVolume:0.1 forID:@"gone" error:&error] && error);
        NSDictionary *saved = testDefaults.values[UVApplicationPreferences];
        assert([saved[@"browser"][@"volume"] floatValue] == 0.25);

        // Process restart replaces the route, including all browser helpers.
        [events removeAllObjects];
        audio.discovery = @[Source(@"music", @[@10]), Source(@"browser", @[@22, @23])];
        [audio refreshApplications];
        assert(([events isEqual:@[@"prepare", @"exclude", @"stop"]]));
        assert(browser.stopped);
        browser = audio.created.lastObject;
        assert(([audio.excluded isEqual:@[@10, @22, @23, @999]]));
        Close([browser renderGain], 0.04);

        // A vanished application returns its process IDs to the master BEFORE
        // its old tap is stopped. Other application settings remain intact.
        [events removeAllObjects];
        audio.discovery = @[Source(@"browser", @[@22, @23])];
        [audio refreshApplications];
        assert(([events isEqual:@[@"exclude", @"stop"]]));
        assert(music.stopped && !browser.stopped);
        assert(([audio.excluded isEqual:@[@22, @23, @999]]));
        [audio resetApplicationVolumes];
        Close([browser renderGain], 0.64);
        assert([testDefaults.values[UVApplicationPreferences] count] == 0);
        [audio stop];
        assert(browser.stopped);
        assert(![audio.applications[0][@"controllable"] boolValue]);

        // Failed preparation and failed master mutation are transactional: no
        // applied state/persistence claims, old sound route stays in place.
        audio = Audio();
        audio.failPrepare = YES;
        assert(![audio setApplicationVolume:0.2 forID:@"music" error:&error]);
        assert([audio.applications[0][@"volume"] floatValue] == 1);
        assert([testDefaults.values[UVApplicationPreferences] count] == 0);
        audio.failPrepare = NO; audio.failActivation = YES;
        [events removeAllObjects];
        assert(![audio setApplicationMuted:YES forID:@"music" error:&error]);
        assert(audio.created.lastObject.stopped);
        assert(![events containsObject:@"exclude"]); // never alter master if mute arming fails
        assert(![audio.applications[0][@"muted"] boolValue]);
        audio.failActivation = NO; audio.failExclusions = YES;
        assert(![audio setApplicationMuted:YES forID:@"music" error:&error]);
        assert(audio.created.lastObject.stopped);
        assert(![audio.applications[0][@"muted"] boolValue]);
        assert(audio.muted && audio.applicationSafetyError.length > 0);
        assert([testDefaults.values[UVApplicationPreferences] count] == 0);
        audio.muted = NO; // Only an explicit user action clears a safety mute.
        audio.failExclusions = NO;
        assert([audio setApplicationVolume:0.3 forID:@"music" error:nil]);
        music = audio.created.lastObject;
        Close([music renderGain], 0.0225);
        audio.failExclusions = YES;
        audio.discovery = @[Source(@"music", @[@11])];
        [audio refreshApplications];
        assert(!music.stopped && audio.created.lastObject.stopped);
        Close([music renderGain], 0.0225);
        assert(([audio.excluded isEqual:@[@10, @999]]));
        audio.failExclusions = NO;
        [audio stop];

        // An app failure cannot prevent another app's process replacement or
        // ordinary volume update. Failed healthy routes remain available, while
        // an unhealthy route falls back to the master after exclusion succeeds.
        [testDefaults.values removeAllObjects];
        audio = Audio();
        assert([audio setApplicationVolume:0.4 forID:@"music" error:nil]);
        music = audio.created.lastObject;
        assert([audio setApplicationVolume:0.6 forID:@"browser" error:nil]);
        browser = audio.created.lastObject;
        audio.failedProcesses = [NSSet setWithObject:@22];
        audio.discovery = @[Source(@"music", @[@11]), Source(@"browser", @[@22])];
        [events removeAllObjects];
        [audio refreshApplications];
        assert(music.stopped && !browser.stopped);
        music = audio.created.lastObject;
        assert(([audio.excluded isEqual:@[@11, @20, @21, @999]]));
        Close([music renderGain], 0.04); Close([browser renderGain], 0.09);
        [events removeAllObjects];
        [audio refreshApplications];
        assert(events.count == 0); // bounded retry, not a blocking prepare each second
        browser.healthy = NO;
        [audio refreshApplications];
        assert(browser.stopped);
        assert(([audio.excluded isEqual:@[@11, @999]])); // failed app is master-controlled
        assert([audio.applications[1][@"error"] length] > 0);
        assert(![audio.applications[1][@"applied"] boolValue] && !audio.muted);
        assert([audio setApplicationVolume:0.7 forID:@"music" error:nil]);
        Close([music renderGain], 0.1225);
        assert([testDefaults.values[UVApplicationPreferences][@"music"][@"volume"] floatValue] == 0.7f);
        [events removeAllObjects]; audio.clock += 3;
        [audio refreshApplications];
        assert(([events isEqual:@[@"prepare"]]));
        [events removeAllObjects];
        [audio refreshApplications]; assert(events.count == 0);
        audio.failedProcesses = nil;
        assert([audio setApplicationVolume:0.5 forID:@"browser" error:nil]); // explicit retry bypasses backoff
        browser = audio.created.lastObject;
        Close([browser renderGain], 0.0625);
        assert([audio.applications[1][@"error"] length] == 0);

        // A failed master exclusion mutation also backs off before allocating
        // replacement aggregates again, retaining old routes during the delay.
        audio.failExclusions = YES;
        audio.discovery = @[Source(@"music", @[@12]), Source(@"browser", @[@22])];
        [audio refreshApplications];
        assert(!music.stopped);
        [events removeAllObjects];
        [audio refreshApplications]; assert(events.count == 0);
        audio.failExclusions = NO; audio.clock += 3;
        [audio refreshApplications]; assert(music.stopped);
        [audio stop];
        testDefaults.values[UVApplicationPreferences] = @{@"music":@{@"volume":@0.3, @"muted":@NO}};

        // Settings follow the stable application identifier across launches.
        audio = Audio();
        assert(audio.created.count == 1);
        Close([audio.created.lastObject renderGain], 0.0225);
        [audio stop];

        // Losing an independent app mute is fail-closed: before the app can
        // return to the master route, all live DSPs are silenced immediately.
        // This safety state is visible, unpersisted, and not automatically
        // undone when the failed route recovers.
        [testDefaults.values removeAllObjects];
        audio = Audio();
        assert([audio setApplicationVolume:0.4 forID:@"music" error:nil]);
        music = audio.created.lastObject;
        Close([music renderGain], 0.04);
        assert([audio setApplicationMuted:YES forID:@"browser" error:nil]);
        browser = audio.created.lastObject;
        assert([audio.applications[1][@"applied"] boolValue]);
        NSDictionary *mutePreference = [testDefaults.values[UVApplicationPreferences] copy];
        browser.healthy = NO;
        audio.failedProcesses = [NSSet setWithObject:@20];
        [audio refreshApplications];
        assert(audio.muted && audio.applicationSafetyError.length > 0);
        assert([audio.applications[1][@"muted"] boolValue]);
        assert(![audio.applications[1][@"applied"] boolValue]);
        assert(browser.stopped);
        assert([mutePreference isEqual:testDefaults.values[UVApplicationPreferences]]);
        assert([music renderFirstSample] == 0); // no normal 10ms gain tail
        audio.failedProcesses = nil; audio.clock += 3;
        [audio refreshApplications];
        browser = audio.created.lastObject;
        assert([audio.applications[1][@"applied"] boolValue]);
        assert(audio.muted && audio.applicationSafetyError.length > 0);
        Close([music renderGain], 0); Close([browser renderGain], 0);
        audio.muted = NO;
        assert(audio.applicationSafetyError.length == 0);
        Close([music renderGain], 0.04); Close([browser renderGain], 0);

        // A healthy old mute covering only some of a browser's new helpers is
        // not sufficient. A failed replacement must silence master too.
        audio.discovery = @[Source(@"music", @[@10]), Source(@"browser", @[@20, @21, @22])];
        audio.failedProcesses = [NSSet setWithObject:@22];
        [audio refreshApplications];
        assert(!browser.stopped && audio.muted);
        assert(![audio.applications[1][@"applied"] boolValue]);
        assert([music renderFirstSample] == 0);
        [audio stop];

        // Master mute remains authoritative through application process
        // replacement and reset. Neither operation may emit audible PCM or
        // unmute master control as a side effect.
        [testDefaults.values removeAllObjects];
        audio = Audio();
        assert([audio setApplicationVolume:0.4 forID:@"music" error:nil]);
        audio.muted = YES;
        music = audio.created.lastObject;
        Close([music renderGain], 0);
        audio.discovery = @[Source(@"music", @[@11])];
        [audio refreshApplications];
        assert(music.stopped && audio.muted);
        music = audio.created.lastObject;
        Close([music renderGain], 0);
        assert([audio setApplicationMuted:YES forID:@"music" error:nil]);
        [audio resetApplicationVolumes];
        assert(audio.muted && audio.volume == 0.5f);
        assert(![audio.applications[0][@"muted"] boolValue]);
        Close([music renderGain], 0);
        audio.muted = NO;
        Close([music renderGain], 0.25);
        [audio stop];

        // A failed/partial HAL scan is not evidence that muted processes have
        // exited. Preserve the last complete snapshot and its live exclusions;
        // a subsequent successful empty scan still cleans up genuine exits.
        [testDefaults.values removeAllObjects];
        audio = Audio();
        assert([audio setApplicationMuted:YES forID:@"music" error:nil]);
        music = audio.created.lastObject;
        NSArray *beforeRows = audio.applications;
        NSArray *beforeExclusions = audio.excluded;
        NSDictionary *beforeSettings = [testDefaults.values[UVApplicationPreferences] copy];
        audio.failDiscovery = YES;
        audio.discovery = @[];
        [events removeAllObjects];
        [audio refreshApplications];
        assert(events.count == 0 && !music.stopped);
        assert([audio.applications isEqual:beforeRows]);
        assert([audio.excluded isEqual:beforeExclusions]);
        assert([testDefaults.values[UVApplicationPreferences] isEqual:beforeSettings]);
        Close([music renderGain], 0);
        // Keeping stale metadata must not suppress the independent safety
        // check when its existing muted route also becomes unhealthy.
        music.healthy = NO;
        [audio refreshApplications];
        assert(audio.muted && audio.applicationSafetyError.length > 0);
        assert(!music.stopped);
        audio.failDiscovery = NO;
        [audio refreshApplications];
        assert(music.stopped && audio.applications.count == 0);
        assert(([audio.excluded isEqual:@[@999]]));
        [audio stop];

        // A registered/active application on another output device has no
        // process objects in this route. It must not accept a misleading saved
        // adjustment, create a tap, or affect the controlled app's PCM.
        [testDefaults.values removeAllObjects];
        audio = Audio();
        assert([audio setApplicationVolume:0.4 forID:@"music" error:nil]);
        music = audio.created.lastObject;
        audio.discovery = @[Source(@"music", @[@10]), Source(@"browser", @[])];
        [audio refreshApplications];
        assert([audio.applications[0][@"controllable"] boolValue]);
        assert(![audio.applications[1][@"controllable"] boolValue]);
        NSUInteger routeCount = audio.created.count;
        NSDictionary *before = [testDefaults.values[UVApplicationPreferences] copy];
        error = nil;
        assert(![audio setApplicationMuted:YES forID:@"browser" error:&error] && error);
        error = nil;
        assert(![audio setApplicationVolume:0.1 forID:@"browser" error:&error] && error);
        assert(audio.created.count == routeCount);
        assert([before isEqual:testDefaults.values[UVApplicationPreferences]]);
        Close([music renderGain], 0.04);
        [audio stop];
        assert(![audio.applications[0][@"controllable"] boolValue]);
        error = nil;
        assert(![audio setApplicationVolume:0.2 forID:@"music" error:&error] && error);
        assert([before isEqual:testDefaults.values[UVApplicationPreferences]]);

        // Corrupted persisted values are sanitized, and nonpersistent PID-only
        // sources never leave stale saved controls for a later reused PID.
        testDefaults.values[UVApplicationPreferences] = @{@"music":@{@"volume":@"bad", @"muted":@[]}, @"invalid":@42};
        audio = Audio();
        assert(audio.created.count == 0 && [audio.applications[0][@"volume"] floatValue] == 1);
        audio.discovery = @[Source(@"pid:42", @[@42])];
        [audio refreshApplications];
        assert([audio setApplicationVolume:0.4 forID:@"pid:42" error:nil]);
        assert(!testDefaults.values[UVApplicationPreferences][@"pid:42"]);
        audio.discovery = @[]; [audio refreshApplications];
        audio.discovery = @[Source(@"pid:42", @[@44])]; [audio refreshApplications];
        assert([audio.applications[0][@"volume"] floatValue] == 1);
        [audio stop];
        puts("Application audio: passed (gain, mute, helpers, restart, rollback, persistence, reset, output isolation, fail-closed mute).");
    }
    return 0;
}
