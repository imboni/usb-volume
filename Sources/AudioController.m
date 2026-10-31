#import "AudioController.h"
#import "Localization.h"
#import "VolumeDSP.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <unistd.h>
#import <math.h>
#import <os/log.h>
#import <AppKit/AppKit.h>
#import <libproc.h>

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
                                         AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static OSStatus Read(AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioObjectPropertyScope scope, UInt32 size, void *value) {
    AudioObjectPropertyAddress a = Address(selector, scope);
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &size, value);
}
static NSString *StringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    if (Read(object, selector, kAudioObjectPropertyScopeGlobal, sizeof(value), &value) != noErr) return @"";
    return CFBridgingRelease(value) ?: @"";
}
// A failed HAL read is not an empty device/process list. Callers deciding
// whether to retire a live route must preserve that distinction.
static NSArray<NSNumber *> *ObjectsIfAvailable(AudioObjectID object, AudioObjectPropertySelector selector,
                                               AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Address(selector, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &a, 0, NULL, &size) != noErr) return nil;
    if (!size) return @[];
    if (size % sizeof(AudioObjectID)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(object, &a, 0, NULL, &size, data.mutableBytes) != noErr ||
        size > data.length || size % sizeof(AudioObjectID)) return nil;
    NSMutableArray *result = [NSMutableArray array];
    const AudioObjectID *ids = data.bytes;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [result addObject:@(ids[i])];
    return result;
}
static NSArray<NSNumber *> *Objects(AudioObjectID object, AudioObjectPropertySelector selector,
                                    AudioObjectPropertyScope scope) {
    return ObjectsIfAvailable(object, selector, scope) ?: @[];
}
static UInt32 Channels(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr || !size) return 0;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, data.mutableBytes) != noErr) return 0;
    const AudioBufferList *list = data.bytes;
    UInt32 channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) channels += list->mBuffers[i].mNumberChannels;
    return channels;
}
static AudioObjectID DefaultDevice(AudioObjectPropertySelector selector) {
    AudioObjectID device = kAudioObjectUnknown;
    Read(kAudioObjectSystemObject, selector, kAudioObjectPropertyScopeGlobal, sizeof(device), &device);
    return device;
}
static OSStatus SetDefault(AudioObjectPropertySelector selector, AudioObjectID device) {
    AudioObjectPropertyAddress a = Address(selector, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof(device), &device);
}
static BOOL Alive(AudioObjectID device) {
    UInt32 alive = 0;
    return Read(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                sizeof(alive), &alive) == noErr && alive != 0;
}
static NSError *Failure(NSString *message, OSStatus status) {
    NSString *description = status == noErr ? UVL(message) : [NSString stringWithFormat:UVL(@"%@（错误 %d）"), UVL(message), (int)status];
    return [NSError errorWithDomain:@"local.USBVolume.Audio" code:status ?: -1
                          userInfo:@{NSLocalizedDescriptionKey:description, @"UVMessageKey":message, @"UVStatus":@(status)}];
}
static BOOL FloatFormat(AudioStreamBasicDescription format, double rate) {
    return format.mFormatID == kAudioFormatLinearPCM &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat) &&
        !(format.mFormatFlags & kAudioFormatFlagIsBigEndian) &&
        format.mBitsPerChannel == 32 && format.mFramesPerPacket == 1 &&
        (format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2) &&
        format.mBytesPerFrame == ((format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 4 * format.mChannelsPerFrame) &&
        fabs(format.mSampleRate - rate) < 1.0;
}
static BOOL ValidStreams(AudioObjectID device, AudioObjectPropertyScope scope, double rate) {
    NSArray<NSNumber *> *streams = Objects(device, kAudioDevicePropertyStreams, scope);
    if (streams.count < 1 || streams.count > 2 || Channels(device, scope) != 2) return NO;
    for (NSNumber *stream in streams) {
        AudioStreamBasicDescription format = {0};
        if (Read(stream.unsignedIntValue, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
                 sizeof(format), &format) != noErr || !FloatFormat(format, rate)) return NO;
    }
    return YES;
}
static OSStatus Render(AudioObjectID device, const AudioTimeStamp *now,
                       const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    VDProcess((VDState *)context, input, output);
    return noErr;
}

static NSString *const UVApplicationPreferences = @"USBVolume.applications";

static float ApplicationLevel(id value) {
    if (![value isKindOfClass:NSNumber.class]) return 1;
    float level = [value floatValue];
    return isfinite(level) ? fmaxf(0, fminf(1, level)) : 1;
}

// Chromium and Electron place helpers inside the parent .app. Choosing the
// outermost bundle groups those helpers without guessing from bundle prefixes.
static NSBundle *ApplicationBundle(NSURL *url) {
    if (!url) return nil;
    NSURL *candidate = nil;
    while (url.path.length > 1) {
        if ([url.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame) candidate = url;
        url = url.URLByDeletingLastPathComponent;
    }
    return candidate ? [NSBundle bundleWithURL:candidate] : nil;
}

static NSDictionary *ApplicationIdentity(pid_t pid, NSString *processBundleID) {
    NSRunningApplication *running = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSBundle *bundle = ApplicationBundle(running.bundleURL);
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (!bundle && proc_pidpath(pid, path, sizeof(path)) > 0)
        bundle = ApplicationBundle([NSURL fileURLWithPath:[NSString stringWithUTF8String:path]]);
    NSString *bundleID = bundle.bundleIdentifier ?: running.bundleIdentifier ?: processBundleID;
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?:
                     [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: running.localizedName;
    if (!name.length) name = bundle.bundleURL.lastPathComponent.stringByDeletingPathExtension;
    if (!name.length) name = processBundleID.length ? processBundleID : [NSString stringWithFormat:@"PID %d", pid];
    NSString *identifier = bundleID.length ? bundleID : [NSString stringWithFormat:@"pid:%d", pid];
    return @{@"id":identifier, @"bundleID":bundleID ?: @"", @"name":name};
}

// Each non-default application has a device-scoped tap and private playback
// route. Its PCM is attenuated by master * application gain, while the master
// tap excludes precisely these process objects. No Objective-C runs in Render.
@interface UVApplicationRoute : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *processes;
@property(nonatomic) AudioObjectID tap;
@property(nonatomic) AudioObjectID aggregate;
@property(nonatomic) AudioDeviceIOProcID io;
@property(nonatomic) VDState *dsp;
@property(nonatomic) BOOL attemptedIO;
@property(nonatomic) CATapDescription *tapDescription;
- (BOOL)prepareForProcesses:(NSArray<NSNumber *> *)processes deviceUID:(NSString *)uid
                sampleRate:(double)rate error:(NSError **)error;
- (void)setGain:(float)gain;
- (BOOL)healthyAtRate:(double)rate;
- (BOOL)activateMuting:(NSError **)error;
- (void)stop;
@end

@implementation UVApplicationRoute
- (BOOL)prepareForProcesses:(NSArray<NSNumber *> *)processes deviceUID:(NSString *)uid
                sampleRate:(double)rate error:(NSError **)error {
    self.processes = processes;
    OSStatus status = noErr;
    CATapDescription *description = [[CATapDescription alloc] initWithProcesses:processes andDeviceUID:uid withStream:0];
    description.name = UVL(@"USB 音量 · 本机处理");
    description.privateTap = YES;
    // Preparation must not change the source's existing playback/mute state.
    // The route renders zero until a short, explicit membership handover.
    description.muteBehavior = CATapUnmuted;
    _tapDescription = description;
    status = AudioHardwareCreateProcessTap(description, &_tap);
    if (status != noErr) goto fail;
    {
        AudioStreamBasicDescription format = {0};
        status = Read(_tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, sizeof(format), &format);
        if (status != noErr || !FloatFormat(format, rate) || format.mChannelsPerFrame != 2) goto fail;
        NSString *tapUID = StringProperty(_tap, kAudioTapPropertyUID);
        if (!tapUID.length) goto fail;
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey:UVL(@"USB 音量 · 私有处理通道"),
            @kAudioAggregateDeviceUIDKey:[@"local.USBVolume.application." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceIsPrivateKey:@YES, @kAudioAggregateDeviceIsStackedKey:@NO,
            @kAudioAggregateDeviceMainSubDeviceKey:uid,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:uid}],
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:tapUID, @kAudioSubTapDriftCompensationKey:@YES}],
            @kAudioAggregateDeviceTapAutoStartKey:@NO
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &_aggregate);
        if (status != noErr) goto fail;
    }
    for (NSUInteger attempt = 0; attempt < 50; attempt++) {
        if ([self healthyAtRate:rate]) break;
        [NSThread sleepForTimeInterval:0.02];
    }
    if (![self healthyAtRate:rate]) goto fail;
    _dsp = VDCreate(rate, 0); // Never double the master route during handover.
    if (!_dsp) goto fail;
    status = AudioDeviceCreateIOProcID(_aggregate, Render, _dsp, &_io);
    if (status != noErr) goto fail;
    _attemptedIO = YES;
    status = AudioDeviceStart(_aggregate, _io);
    if (status != noErr) goto fail;
    return YES;
fail:
    if (error) *error = Failure(@"无法建立音频回放。", status);
    [self stop];
    return NO;
}
- (BOOL)activateMuting:(NSError **)error {
    _tapDescription.muteBehavior = CATapMutedWhenTapped;
    CATapDescription *description = _tapDescription;
    AudioObjectPropertyAddress address = Address(kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal);
    OSStatus status = AudioObjectSetPropertyData(_tap, &address, 0, NULL, sizeof(description), &description);
    if (status != noErr && error) *error = Failure(@"无法建立音频回放。", status);
    return status == noErr;
}
- (BOOL)healthyAtRate:(double)rate {
    return Alive(_aggregate) && ValidStreams(_aggregate, kAudioDevicePropertyScopeInput, rate) &&
           ValidStreams(_aggregate, kAudioDevicePropertyScopeOutput, rate);
}
- (void)setGain:(float)gain { VDSetGain(_dsp, gain); }
- (void)stop {
    if (_attemptedIO && _aggregate && _io) AudioDeviceStop(_aggregate, _io);
    if (_aggregate && _io) AudioDeviceDestroyIOProcID(_aggregate, _io);
    _io = NULL; _attemptedIO = NO;
    if (_aggregate) AudioHardwareDestroyAggregateDevice(_aggregate);
    _aggregate = kAudioObjectUnknown;
    if (_tap) AudioHardwareDestroyProcessTap(_tap);
    _tap = kAudioObjectUnknown;
    _tapDescription = nil;
    VDDestroy(_dsp); _dsp = NULL;
}
- (void)dealloc { [self stop]; }
@end

@interface UVAudioController ()
- (NSArray<NSDictionary *> *)discoverApplications;
- (NSUserDefaults *)applicationDefaults;
- (UVApplicationRoute *)prepareApplicationRoute:(NSArray<NSNumber *> *)processes error:(NSError **)error;
- (BOOL)setMasterExclusions:(NSArray<NSNumber *> *)processes error:(NSError **)error;
- (BOOL)reconcileApplicationRoutes:(NSError **)error;
@end

@implementation UVAudioController {
    AudioObjectID _device;
    AudioObjectID _tap;
    AudioObjectID _aggregate;
    AudioDeviceIOProcID _io;
    VDState *_dsp;
    AudioObjectID _previousOutput;
    AudioObjectID _previousSystemOutput;
    NSString *_previousOutputUID;
    NSString *_previousSystemOutputUID;
    NSString *_selectedUID;
    double _sampleRate;
    NSTimer *_healthTimer;
    BOOL _changedOutput;
    BOOL _changedSystemOutput;
    BOOL _attemptedIO;
    BOOL _startedIO;
    BOOL _running;
    float _volume;
    BOOL _muted;
    NSString *_deviceName;
    NSString *_lastError;
    OSStatus _lastErrorStatus;
    AudioObjectPropertyListenerBlock _deviceListener;
    AudioObjectID _ownProcess;
    CATapDescription *_masterDescription;
    NSArray<NSDictionary *> *_applicationSnapshot;
    NSMutableDictionary<NSString *, NSDictionary *> *_applicationSettings;
    NSMutableDictionary<NSString *, UVApplicationRoute *> *_applicationRoutes;
    NSMutableDictionary<NSString *, NSError *> *_applicationErrors;
    NSArray<NSNumber *> *_masterExclusions;
    BOOL _refreshingApplications;
    NSMutableDictionary<NSString *, NSDictionary *> *_applicationRetries;
    NSDictionary *_routingRetrySnapshot;
    NSTimeInterval _routingRetryDeadline;
    NSUInteger _routingFailures;
    NSString *_applicationSafetyError;
}
@synthesize running = _running, volume = _volume, muted = _muted;
@synthesize deviceName = _deviceName;

- (NSString *)lastErrorKey { return _lastError; }
- (void)clearError { _lastError = @""; _lastErrorStatus = noErr; }
- (NSString *)lastError {
    if (!_lastError.length) return @"";
    return _lastErrorStatus == noErr ? UVL(_lastError) : [NSString stringWithFormat:UVL(@"%@（错误 %d）"), UVL(_lastError), (int)_lastErrorStatus];
}

- (instancetype)init {
    if ((self = [super init])) {
        _volume = 0.2f;
        _deviceName = @"";
        _lastError = @"";
        _applicationSnapshot = @[];
        _applicationRoutes = [NSMutableDictionary dictionary];
        _applicationErrors = [NSMutableDictionary dictionary];
        _applicationRetries = [NSMutableDictionary dictionary];
        _applicationSettings = [NSMutableDictionary dictionary];
        NSDictionary *saved = [[self applicationDefaults] dictionaryForKey:UVApplicationPreferences];
        for (NSString *identifier in saved) {
            NSDictionary *setting = saved[identifier];
            if (![identifier isKindOfClass:NSString.class] || ![setting isKindOfClass:NSDictionary.class]) continue;
            _applicationSettings[identifier] = @{@"volume":@(ApplicationLevel(setting[@"volume"])),
                @"muted":@([setting[@"muted"] isKindOfClass:NSNumber.class] && [setting[@"muted"] boolValue])};
        }
    }
    return self;
}
- (NSArray<NSDictionary *> *)devices {
    NSMutableArray *devices = [NSMutableArray array];
    for (NSNumber *number in Objects(kAudioObjectSystemObject, kAudioHardwarePropertyDevices,
                                    kAudioObjectPropertyScopeGlobal)) {
        AudioObjectID device = number.unsignedIntValue;
        // This deliberately small app supports stereo playback-only hardware; no microphone capture.
        if (!Alive(device) || Channels(device, kAudioDevicePropertyScopeOutput) != 2 ||
            Channels(device, kAudioDevicePropertyScopeInput) != 0) continue;
        NSString *name = StringProperty(device, kAudioObjectPropertyName);
        NSString *uid = StringProperty(device, kAudioDevicePropertyDeviceUID);
        NSString *manufacturer = StringProperty(device, kAudioObjectPropertyManufacturer);
        UInt32 transport = 0;
        Read(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, sizeof(transport), &transport);
        if (!uid.length || [manufacturer localizedCaseInsensitiveContainsString:@"Bitgapp"] ||
            [name localizedCaseInsensitiveContainsString:@"eqMac"] ||
            transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual) continue;
        [devices addObject:@{@"id":number, @"uid":uid, @"name":name,
                            @"isUSB":@(transport == kAudioDeviceTransportTypeUSB)}];
    }
    return devices;
}
- (BOOL)startMonitoringDevices {
    if (_deviceListener) return YES;
    __weak UVAudioController *weakSelf = self;
    AudioObjectPropertyListenerBlock listener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        UVAudioController *strongSelf = weakSelf;
        if (strongSelf.devicesChanged) strongSelf.devicesChanged();
    };
    AudioObjectPropertyAddress address = Address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, dispatch_get_main_queue(), listener) != noErr) return NO;
    _deviceListener = listener;
    return YES;
}
- (void)stopMonitoringDevices {
    if (!_deviceListener) return;
    AudioObjectPropertyAddress address = Address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, dispatch_get_main_queue(), _deviceListener);
    _deviceListener = nil;
}
- (void)setVolume:(float)volume {
    _volume = isfinite(volume) ? fmaxf(0, fminf(1, volume)) : 0;
    if (_dsp) VDSetGain(_dsp, _muted ? 0 : _volume * _volume);
    [self updateApplicationGains];
}
- (void)setMuted:(BOOL)muted {
    _muted = muted;
    if (!muted) _applicationSafetyError = nil;
    if (_dsp) VDSetGain(_dsp, _muted ? 0 : _volume * _volume);
    [self updateApplicationGains];
}
- (NSUserDefaults *)applicationDefaults { return NSUserDefaults.standardUserDefaults; }

- (NSArray<NSDictionary *> *)discoverApplications {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    NSArray *processes = ObjectsIfAvailable(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList,
                                           kAudioObjectPropertyScopeGlobal);
    if (!processes) return nil;
    NSMutableSet *controlledProcesses = [NSMutableSet set];
    for (NSDictionary *source in _applicationSnapshot) [controlledProcesses addObjectsFromArray:source[@"processes"]];
    for (UVApplicationRoute *route in _applicationRoutes.allValues) [controlledProcesses addObjectsFromArray:route.processes];
    for (NSNumber *number in processes) {
        pid_t pid = 0;
        // A process may disappear between enumeration and property reads. Do
        // not publish a partial scan as proof that an existing route is gone.
        // An unreadable unrelated/system process must not block all discovery.
        BOOL controlled = [controlledProcesses containsObject:number];
        if (Read(number.unsignedIntValue, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal,
                 sizeof(pid), &pid) != noErr) {
            if (controlled) return nil;
            continue;
        }
        if (pid <= 0 || pid == getpid()) continue;
        CFStringRef bundleValue = NULL;
        if (Read(number.unsignedIntValue, kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal,
                 sizeof(bundleValue), &bundleValue) != noErr) {
            if (controlled) return nil;
            continue;
        }
        NSString *bundleID = CFBridgingRelease(bundleValue) ?: @"";
        NSDictionary *identity = ApplicationIdentity(pid, bundleID);
        NSString *identifier = identity[@"id"];
        UInt32 active = 0;
        Read(number.unsignedIntValue, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, sizeof(active), &active);
        NSArray *devices = ObjectsIfAvailable(number.unsignedIntValue, kAudioProcessPropertyDevices, kAudioDevicePropertyScopeOutput);
        if (!devices) {
            if (controlled) return nil;
            continue;
        }
        if (!active && !devices.count && !_applicationSettings[identifier] && !_applicationRoutes[identifier]) continue;
        NSMutableDictionary *group = groups[identifier];
        if (!group) {
            group = [identity mutableCopy];
            group[@"processes"] = [NSMutableArray array];
            group[@"active"] = @NO;
            groups[identifier] = group;
        }
        if (active) group[@"active"] = @YES;
        if ([devices containsObject:@(_device)]) [group[@"processes"] addObject:number];
    }
    NSMutableArray *snapshot = [NSMutableArray array];
    for (NSMutableDictionary *group in groups.allValues) {
        group[@"processes"] = [group[@"processes"] sortedArrayUsingSelector:@selector(compare:)];
        [snapshot addObject:[group copy]];
    }
    return [snapshot sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        return order == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
    }];
}

- (NSString *)applicationSafetyError { return _applicationSafetyError.length ? UVL(_applicationSafetyError) : @""; }
- (NSArray<NSDictionary *> *)applications {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *source in _applicationSnapshot) {
        NSString *identifier = source[@"id"];
        NSDictionary *setting = _applicationSettings[identifier];
        NSMutableDictionary *row = [source mutableCopy];
        [row removeObjectForKey:@"processes"];
        row[@"volume"] = @(ApplicationLevel(setting[@"volume"]));
        row[@"muted"] = @([setting[@"muted"] boolValue]);
        row[@"controllable"] = @(_running && [source[@"processes"] count] > 0);
        row[@"error"] = _applicationErrors[identifier].localizedDescription ?: @"";
        UVApplicationRoute *route = _applicationRoutes[identifier];
        BOOL independent = ApplicationLevel(setting[@"volume"]) < 1 || [setting[@"muted"] boolValue];
        row[@"applied"] = @([row[@"controllable"] boolValue] && !_applicationErrors[identifier] &&
            (!independent || [route.processes isEqual:source[@"processes"]]));
        [rows addObject:row];
    }
    return rows;
}

- (float)gainForApplication:(NSString *)identifier {
    NSDictionary *setting = _applicationSettings[identifier];
    float level = ApplicationLevel(setting[@"volume"]);
    return _muted || [setting[@"muted"] boolValue] ? 0 : _volume * _volume * level * level;
}
- (void)updateApplicationGains {
    for (NSString *identifier in _applicationRoutes)
        [_applicationRoutes[identifier] setGain:[self gainForApplication:identifier]];
}
- (UVApplicationRoute *)prepareApplicationRoute:(NSArray<NSNumber *> *)processes error:(NSError **)error {
    UVApplicationRoute *route = [UVApplicationRoute new];
    return [route prepareForProcesses:processes deviceUID:_selectedUID sampleRate:_sampleRate error:error] ? route : nil;
}
- (BOOL)setMasterExclusions:(NSArray<NSNumber *> *)processes error:(NSError **)error {
    if ([_masterExclusions isEqual:processes]) return YES;
    NSArray *previous = _masterDescription.processes;
    _masterDescription.processes = processes;
    CATapDescription *description = _masterDescription;
    AudioObjectPropertyAddress address = Address(kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal);
    OSStatus status = AudioObjectSetPropertyData(_tap, &address, 0, NULL, sizeof(description), &description);
    if (status != noErr) {
        _masterDescription.processes = previous;
        if (error) *error = Failure(@"无法建立音频回放。", status);
        return NO;
    }
    _masterExclusions = [processes copy];
    return YES;
}
- (NSTimeInterval)routingTime { return NSProcessInfo.processInfo.systemUptime; }
- (void)deferApplication:(NSString *)identifier processes:(NSArray *)processes {
    NSDictionary *previous = _applicationRetries[identifier];
    NSUInteger failures = [previous[@"processes"] isEqual:processes] ? [previous[@"failures"] unsignedIntegerValue] + 1 : 1;
    NSTimeInterval delay = fmin(30, pow(2, MIN(failures, (NSUInteger)5)));
    _applicationRetries[identifier] = @{@"processes":processes, @"failures":@(failures),
                                        @"deadline":@([self routingTime] + delay)};
}
// A failed independent mute must never silently turn into an audible master
// route. This safety mute is live state only, not a persisted user preference.
// A later successful repair deliberately leaves the master muted until the user
// explicitly unmutes it. Passing proposed routes checks before any handover.
- (void)enforceApplicationMuteSafetyWithRoutes:(NSDictionary<NSString *, UVApplicationRoute *> *)routes {
    BOOL mustMute = NO;
    NSString *message = @"应用静音暂时失效，已静音总音量。请重试后手动取消总静音。";
    for (NSDictionary *source in _applicationSnapshot) {
        NSString *identifier = source[@"id"];
        if (![_applicationSettings[identifier][@"muted"] boolValue] || ![source[@"processes"] count]) continue;
        UVApplicationRoute *route = routes[identifier];
        NSSet *required = [NSSet setWithArray:source[@"processes"]];
        NSSet *covered = [NSSet setWithArray:route.processes ?: @[]];
        if (route && [required isSubsetOfSet:covered] && [route healthyAtRate:_sampleRate]) continue;
        mustMute = YES;
        _applicationErrors[identifier] = Failure(message, noErr);
    }
    if (!mustMute) return;
    self.muted = YES;
    _applicationSafetyError = message;
    VDMuteImmediately(_dsp);
    for (UVApplicationRoute *route in _applicationRoutes.allValues) VDMuteImmediately(route.dsp);
    for (UVApplicationRoute *route in routes.allValues) VDMuteImmediately(route.dsp);
}
- (BOOL)reconcileApplicationRoutes:(NSError **)error {
    if (!_running) return YES;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *desired = [NSMutableDictionary dictionary];
    for (NSDictionary *source in _applicationSnapshot) {
        NSString *identifier = source[@"id"];
        NSDictionary *setting = _applicationSettings[identifier];
        // Keep an existing route at 100% until it goes away, avoiding HAL churn
        // whenever a slider crosses 100% or mute is toggled.
        if ([source[@"processes"] count] && (_applicationRoutes[identifier] ||
            ApplicationLevel(setting[@"volume"]) < 1 || [setting[@"muted"] boolValue]))
            desired[identifier] = source[@"processes"];
    }
    NSTimeInterval now = [self routingTime];
    if ([_routingRetrySnapshot isEqual:desired] && now < _routingRetryDeadline) {
        [self updateApplicationGains];
        [self enforceApplicationMuteSafetyWithRoutes:_applicationRoutes];
        return NO;
    }
    NSMutableDictionary<NSString *, UVApplicationRoute *> *next = [NSMutableDictionary dictionary];
    NSMutableArray<UVApplicationRoute *> *prepared = [NSMutableArray array];
    NSMutableArray<UVApplicationRoute *> *retired = [NSMutableArray array];
    NSMutableSet<NSString *> *changed = [NSMutableSet set];
    NSMutableSet<NSString *> *failed = [NSMutableSet set];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet setWithArray:_applicationRoutes.allKeys];
    [identifiers addObjectsFromArray:desired.allKeys];
    NSError *problem = nil;
    for (NSString *identifier in [identifiers.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        UVApplicationRoute *old = _applicationRoutes[identifier];
        BOOL healthy = old && [old healthyAtRate:_sampleRate];
        NSArray *processes = desired[identifier];
        if (healthy && [old.processes isEqual:processes]) {
            next[identifier] = old;
            [_applicationErrors removeObjectForKey:identifier];
            [_applicationRetries removeObjectForKey:identifier];
            continue;
        }
        if (processes) {
            NSDictionary *retry = _applicationRetries[identifier];
            BOOL deferred = [retry[@"processes"] isEqual:processes] && now < [retry[@"deadline"] doubleValue];
            NSError *prepareError = nil;
            UVApplicationRoute *route = deferred ? nil : [self prepareApplicationRoute:processes error:&prepareError];
            if (route) {
                next[identifier] = route;
                [prepared addObject:route];
                [changed addObject:identifier];
            } else {
                if (!deferred) {
                    _applicationErrors[identifier] = prepareError ?: Failure(@"无法建立音频回放。", noErr);
                    [self deferApplication:identifier processes:processes];
                }
                [failed addObject:identifier];
                problem = problem ?: _applicationErrors[identifier];
                // A bad app does not block another app's gain or route update.
                // Keep a healthy old route; otherwise let the master regain
                // the process rather than leaving it captured but silent.
                if (healthy) next[identifier] = old;
            }
        }
        if (old && next[identifier] != old) {
            [retired addObject:old];
            [changed addObject:identifier];
        }
    }
    // Only arm prepared taps once all potentially slow HAL preparation has
    // finished. This confines overlap with the master to the commit itself.
    for (NSString *identifier in [next.allKeys copy]) {
        UVApplicationRoute *route = next[identifier];
        if (![prepared containsObject:route]) continue;
        NSError *armError = nil;
        if ([route activateMuting:&armError]) continue;
        [route stop];
        [prepared removeObject:route];
        [next removeObjectForKey:identifier];
        UVApplicationRoute *old = _applicationRoutes[identifier];
        if (old && [old healthyAtRate:_sampleRate]) {
            next[identifier] = old;
            [retired removeObject:old];
        }
        if (!old || next[identifier] == old) [changed removeObject:identifier];
        _applicationErrors[identifier] = armError ?: Failure(@"无法建立音频回放。", noErr);
        [self deferApplication:identifier processes:desired[identifier]];
        [failed addObject:identifier];
        problem = problem ?: _applicationErrors[identifier];
    }
    if (!changed.count) {
        [self updateApplicationGains];
        [self enforceApplicationMuteSafetyWithRoutes:_applicationRoutes];
        if (error) *error = problem;
        return failed.count == 0;
    }
    NSMutableSet<NSNumber *> *exclusions = [NSMutableSet setWithObject:@(_ownProcess)];
    for (UVApplicationRoute *route in next.allValues) [exclusions addObjectsFromArray:route.processes];
    // Preparing a replacement at zero gain leaves the current route audible.
    // Ramp its old counterpart down before changing the master tap membership.
    for (UVApplicationRoute *route in retired) [route setGain:0];
    if (retired.count) [NSThread sleepForTimeInterval:0.02];
    [self enforceApplicationMuteSafetyWithRoutes:next];
    NSError *masterError = nil;
    if (![self setMasterExclusions:[exclusions.allObjects sortedArrayUsingSelector:@selector(compare:)] error:&masterError]) {
        for (UVApplicationRoute *route in prepared) [route stop];
        [self updateApplicationGains];
        for (NSString *identifier in changed) _applicationErrors[identifier] = masterError;
        [self enforceApplicationMuteSafetyWithRoutes:_applicationRoutes];
        _routingFailures = [_routingRetrySnapshot isEqual:desired] ? _routingFailures + 1 : 1;
        _routingRetrySnapshot = [desired copy];
        _routingRetryDeadline = now + fmin(30, pow(2, MIN(_routingFailures, (NSUInteger)5)));
        if (error) *error = masterError;
        return NO;
    }
    _routingRetrySnapshot = nil;
    _routingRetryDeadline = 0;
    _routingFailures = 0;
    // The master now owns removed processes. No process is released from its
    // old tap before the master can attenuate it again.
    for (UVApplicationRoute *route in retired) [route stop];
    _applicationRoutes = next;
    for (NSString *identifier in changed) {
        if (![failed containsObject:identifier]) {
            [_applicationErrors removeObjectForKey:identifier];
            [_applicationRetries removeObjectForKey:identifier];
        }
    }
    [self updateApplicationGains];
    if (error) *error = problem;
    return failed.count == 0;
}
- (void)refreshApplications {
    if (_refreshingApplications) return;
    _refreshingApplications = YES;
    NSArray *previous = self.applications;
    BOOL wasMuted = _muted;
    NSArray *discovered = [self discoverApplications];
    if (!discovered) {
        // Keep live channels and their exclusions intact until HAL supplies a
        // complete snapshot. In particular, never release a muted app because
        // an IPC read temporarily failed.
        [self enforceApplicationMuteSafetyWithRoutes:_applicationRoutes];
        _refreshingApplications = NO;
        if ((![previous isEqual:self.applications] || wasMuted != _muted) && self.stateChanged) self.stateChanged();
        return;
    }
    _applicationSnapshot = discovered;
    NSSet *present = [NSSet setWithArray:[_applicationSnapshot valueForKey:@"id"]];
    for (NSString *identifier in _applicationSettings.allKeys) {
        if ([identifier hasPrefix:@"pid:"] && ![present containsObject:identifier])
            [_applicationSettings removeObjectForKey:identifier];
    }
    for (NSString *identifier in _applicationErrors.allKeys)
        if (![present containsObject:identifier]) [_applicationErrors removeObjectForKey:identifier];
    for (NSString *identifier in _applicationRetries.allKeys)
        if (![present containsObject:identifier]) [_applicationRetries removeObjectForKey:identifier];
    [self reconcileApplicationRoutes:nil];
    _refreshingApplications = NO;
    if ((![previous isEqual:self.applications] || wasMuted != _muted) && self.stateChanged) self.stateChanged();
}
- (void)saveApplicationSettings {
    NSMutableDictionary *persistent = [NSMutableDictionary dictionary];
    for (NSString *identifier in _applicationSettings) {
        if (![identifier hasPrefix:@"pid:"]) persistent[identifier] = _applicationSettings[identifier];
    }
    [[self applicationDefaults] setObject:persistent forKey:UVApplicationPreferences];
}
- (BOOL)changeApplication:(NSString *)identifier volume:(NSNumber *)volume muted:(NSNumber *)muted error:(NSError **)error {
    NSDictionary *source = nil;
    for (NSDictionary *row in _applicationSnapshot) if ([row[@"id"] isEqual:identifier]) { source = row; break; }
    if (!_running || ![source[@"processes"] count]) {
        if (error) *error = Failure(@"无法建立音频回放。", noErr);
        return NO;
    }
    NSDictionary *previous = _applicationSettings[identifier];
    _applicationSettings[identifier] = @{@"volume":volume ?: @(ApplicationLevel(previous[@"volume"])),
                                        @"muted":muted ?: @([previous[@"muted"] boolValue])};
    [_applicationRetries removeObjectForKey:identifier];
    [_applicationErrors removeObjectForKey:identifier];
    _routingRetryDeadline = 0; // An explicit adjustment is also a retry request.
    [self reconcileApplicationRoutes:nil];
    if (_applicationErrors[identifier]) {
        if (error) *error = _applicationErrors[identifier];
        if (previous) _applicationSettings[identifier] = previous;
        else [_applicationSettings removeObjectForKey:identifier];
        [self updateApplicationGains];
        if (self.stateChanged) self.stateChanged();
        return NO;
    }
    [_applicationErrors removeObjectForKey:identifier];
    [self saveApplicationSettings];
    if (self.stateChanged) self.stateChanged();
    return YES;
}
- (BOOL)setApplicationVolume:(float)volume forID:(NSString *)identifier error:(NSError **)error {
    // A malformed command may silence a channel, but must never amplify it.
    return [self changeApplication:identifier volume:@(isfinite(volume) ? fmaxf(0, fminf(1, volume)) : 0)
                            muted:nil error:error];
}
- (BOOL)setApplicationMuted:(BOOL)muted forID:(NSString *)identifier error:(NSError **)error {
    return [self changeApplication:identifier volume:nil muted:@(muted) error:error];
}
- (void)resetApplicationVolumes {
    [_applicationSettings removeAllObjects];
    [_applicationErrors removeAllObjects];
    [_applicationRetries removeAllObjects];
    _routingRetrySnapshot = nil;
    _routingRetryDeadline = 0;
    [self updateApplicationGains];
    [self saveApplicationSettings];
    if (self.stateChanged) self.stateChanged();
}
- (void)playFeedback {
    if (_running && _dsp && !_muted && _volume > 0) VDTriggerFeedback(_dsp);
}
- (BOOL)startDeviceUID:(NSString *)uid error:(NSError **)error {
    [self stop];
    _lastError = @"";
    _lastErrorStatus = noErr;
    NSError *problem = nil;
    OSStatus status = noErr;
    NSDictionary *selection = nil;
    for (NSDictionary *candidate in self.devices) if ([candidate[@"uid"] isEqual:uid]) selection = candidate;
    if (!selection) {
        problem = Failure(@"未找到音箱。请接好 USB 后刷新设备列表。", noErr);
        goto fail;
    }
    _device = [selection[@"id"] unsignedIntValue];
    _deviceName = selection[@"name"];
    _selectedUID = uid;
    _previousOutput = DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
    _previousSystemOutput = DefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice);
    _previousOutputUID = StringProperty(_previousOutput, kAudioDevicePropertyDeviceUID);
    _previousSystemOutputUID = StringProperty(_previousSystemOutput, kAudioDevicePropertyDeviceUID);
    if ([StringProperty(_previousOutput, kAudioObjectPropertyName) localizedCaseInsensitiveContainsString:@"eqMac"]) {
        problem = Failure(@"eqMac 正在接管系统输出。请先退出 eqMac，再开启 USB 音量。", noErr);
        goto fail;
    }
    status = Read(_device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                  sizeof(_sampleRate), &_sampleRate);
    if (status != noErr || _sampleRate < 8000 || _sampleRate > 192000) {
        problem = Failure(@"无法读取音箱采样率。", status); goto fail;
    }
    {
        pid_t pid = getpid();
        AudioObjectID ownProcess = kAudioObjectUnknown;
        AudioObjectPropertyAddress a = Address(kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal);
        UInt32 size = sizeof(ownProcess);
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &size, &ownProcess);
        if (status != noErr || ownProcess == kAudioObjectUnknown) {
            problem = Failure(@"无法识别本应用的音频进程，请重新打开应用。", status); goto fail;
        }
        CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:@[@(ownProcess)]
                                                                          andDeviceUID:uid withStream:0];
        description.name = UVL(@"USB 音量 · 本机处理");
        description.privateTap = YES;
        description.muteBehavior = CATapMutedWhenTapped;
        _ownProcess = ownProcess;
        _masterDescription = description;
        _masterExclusions = @[@(ownProcess)];
        status = AudioHardwareCreateProcessTap(description, &_tap);
        if (status != noErr) {
            problem = Failure(@"无法读取系统音频。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「USB 音量」，然后重试。", status);
            goto fail;
        }
        AudioStreamBasicDescription format = {0};
        status = Read(_tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, sizeof(format), &format);
        if (status != noErr || !FloatFormat(format, _sampleRate) || format.mChannelsPerFrame != 2) {
            problem = Failure(@"当前音箱的音频格式暂不支持。请将音箱设为双声道 48 kHz 后重试。", status); goto fail;
        }
        NSString *tapUID = StringProperty(_tap, kAudioTapPropertyUID);
        if (!tapUID.length) { problem = Failure(@"无法创建音频处理通道。", noErr); goto fail; }
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey:UVL(@"USB 音量 · 私有处理通道"),
            @kAudioAggregateDeviceUIDKey:[@"local.USBVolume.aggregate." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceIsPrivateKey:@YES,
            @kAudioAggregateDeviceIsStackedKey:@NO,
            @kAudioAggregateDeviceMainSubDeviceKey:uid,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:uid}],
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:tapUID, @kAudioSubTapDriftCompensationKey:@YES}],
            @kAudioAggregateDeviceTapAutoStartKey:@NO
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &_aggregate);
        if (status != noErr) { problem = Failure(@"无法连接音箱的音频处理通道。", status); goto fail; }
    }
    // HAL publishes an aggregate asynchronously. No audio is muted until IO starts.
    for (NSUInteger attempt = 0; attempt < 50; attempt++) {
        if (Alive(_aggregate) && ValidStreams(_aggregate, kAudioDevicePropertyScopeInput, _sampleRate) &&
            ValidStreams(_aggregate, kAudioDevicePropertyScopeOutput, _sampleRate)) break;
        [NSThread sleepForTimeInterval:0.02];
    }
    if (!Alive(_aggregate) || !ValidStreams(_aggregate, kAudioDevicePropertyScopeInput, _sampleRate) ||
        !ValidStreams(_aggregate, kAudioDevicePropertyScopeOutput, _sampleRate)) {
        problem = Failure(@"音频通道未就绪，或音频格式不受支持。请关闭其他音频处理软件后重试。", noErr); goto fail;
    }
    _dsp = VDCreate(_sampleRate, _muted ? 0 : _volume * _volume);
    if (!_dsp) { problem = Failure(@"无法创建音量处理器。", noErr); goto fail; }
    status = AudioDeviceCreateIOProcID(_aggregate, Render, _dsp, &_io);
    if (status != noErr) { problem = Failure(@"无法建立音频回放。", status); goto fail; }
    _attemptedIO = YES;
    status = AudioDeviceStart(_aggregate, _io);
    if (status != noErr) {
        problem = Failure(@"音频启动失败。", status); goto fail;
    }
    _startedIO = YES;
    if (_previousOutput != _device) {
        status = SetDefault(kAudioHardwarePropertyDefaultOutputDevice, _device);
        if (status != noErr) { problem = Failure(@"无法将输出切换到音箱。", status); goto fail; }
        _changedOutput = YES;
    }
    if (_previousSystemOutput != _device) {
        status = SetDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, _device);
        if (status != noErr) { problem = Failure(@"无法将提示音切换到音箱。", status); goto fail; }
        _changedSystemOutput = YES;
    }
    _running = YES;
    [self refreshApplications];
    {
        __weak UVAudioController *weakSelf = self;
        _healthTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            [weakSelf checkHealth];
        }];
    }
    if (self.stateChanged) self.stateChanged();
    return YES;
fail:
    _lastError = problem.userInfo[@"UVMessageKey"] ?: @"音频启动失败。";
    _lastErrorStatus = [problem.userInfo[@"UVStatus"] intValue];
    // Preserve the initiating failure before cleanup, which can itself fail or
    // wait inside HAL. Log only status and our static message key, never audio.
    os_log_error(OS_LOG_DEFAULT,
                 "Audio start failed: status=%{public}d errorStatus=%{public}d messageKey=%{public}@ attemptedIO=%{public}d startedIO=%{public}d",
                 (int)status, (int)_lastErrorStatus, _lastError, (int)_attemptedIO, (int)_startedIO);
    [self stop];
    if (error) *error = problem;
    if (self.stateChanged) self.stateChanged();
    return NO;
}
- (void)checkHealth {
    if (!_running) return;
    NSString *issue = nil;
    double rate = 0;
    if (!Alive(_device) || !Alive(_aggregate)) issue = @"音箱已断开。重新连接后，点击启用。";
    else if (DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) != _device)
        issue = @"系统输出已改变，控制已停止。请关闭 eqMac 等音频处理软件后重新启用。";
    else if (Read(_device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                  sizeof(rate), &rate) != noErr || fabs(rate - _sampleRate) >= 1.0 ||
             !ValidStreams(_aggregate, kAudioDevicePropertyScopeInput, _sampleRate) ||
             !ValidStreams(_aggregate, kAudioDevicePropertyScopeOutput, _sampleRate))
        issue = @"音箱的音频格式已改变，请重新启用。";
    // A tap can briefly deliver empty buffers while starting or changing sources.
    // The DSP renders silence for those callbacks. They are diagnostic, not a reason
    // to tear down a healthy route and unexpectedly restore unattenuated playback.
    if (issue) {
        [self stop];
        _lastError = issue;
        _lastErrorStatus = noErr;
        if (self.stateChanged) self.stateChanged();
    } else [self refreshApplications];
}
- (void)stop {
    [_healthTimer invalidate]; _healthTimer = nil;
    for (UVApplicationRoute *route in _applicationRoutes.allValues) [route stop];
    [_applicationRoutes removeAllObjects];
    [_applicationErrors removeAllObjects];
    [_applicationRetries removeAllObjects];
    _routingRetrySnapshot = nil;
    _routingRetryDeadline = 0;
    _routingFailures = 0;
    _masterDescription = nil;
    _masterExclusions = nil;
    _ownProcess = kAudioObjectUnknown;
    // Restore only routes we changed, and only if the user hasn't chosen another output.
    if (_changedOutput && DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == _device &&
        Alive(_previousOutput) && [StringProperty(_previousOutput, kAudioDevicePropertyDeviceUID) isEqual:_previousOutputUID])
        SetDefault(kAudioHardwarePropertyDefaultOutputDevice, _previousOutput);
    if (_changedSystemOutput && DefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) == _device &&
        Alive(_previousSystemOutput) && [StringProperty(_previousSystemOutput, kAudioDevicePropertyDeviceUID) isEqual:_previousSystemOutputUID])
        SetDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, _previousSystemOutput);
    _changedOutput = NO; _changedSystemOutput = NO;
    // A failed start can leave HAL with partially registered stream usage.
    // Balance the attempt before destroying its IOProc, even if start failed.
    if ((_attemptedIO || _startedIO) && _aggregate && _io) {
        OSStatus stopStatus = AudioDeviceStop(_aggregate, _io);
        if (stopStatus != noErr)
            os_log_error(OS_LOG_DEFAULT, "Audio stop cleanup failed: status=%{public}d", (int)stopStatus);
    }
    _attemptedIO = NO; _startedIO = NO;
    if (_aggregate && _io) AudioDeviceDestroyIOProcID(_aggregate, _io);
    _io = NULL;
    if (_aggregate) AudioHardwareDestroyAggregateDevice(_aggregate);
    _aggregate = kAudioObjectUnknown;
    if (_tap) AudioHardwareDestroyProcessTap(_tap);
    _tap = kAudioObjectUnknown;
    if (_dsp) VDDestroy(_dsp);
    _dsp = NULL;
    _running = NO;
    if (self.stateChanged) self.stateChanged();
}
- (BOOL)ownsDefaultOutput {
    return _running && _device != kAudioObjectUnknown && DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == _device;
}

- (NSDictionary *)diagnostics {
    VDStats stats = _dsp ? VDGetStats(_dsp) : (VDStats){0};
    NSMutableArray *routes = [NSMutableArray array];
    for (NSString *identifier in [_applicationRoutes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        UVApplicationRoute *route = _applicationRoutes[identifier];
        VDStats appStats = VDGetStats(route.dsp);
        [routes addObject:@{@"id":identifier, @"processes":route.processes,
                            @"callbacks":@(appStats.callbacks), @"currentGain":@(appStats.currentGain),
                            @"formatErrors":@(appStats.formatErrors), @"tapID":@(route.tap),
                            @"aggregateID":@(route.aggregate)}];
    }
    return @{@"running":@(_running), @"device":_deviceName ?: @"", @"uid":_selectedUID ?: @"",
             @"volume":@(_volume), @"muted":@(_muted), @"sampleRate":@(_sampleRate),
             @"callbacks":@(stats.callbacks), @"frames":@(stats.frames),
             @"inputPeak":@(stats.inputPeak), @"outputPeak":@(stats.outputPeak),
             @"currentGain":@(stats.currentGain), @"formatErrors":@(stats.formatErrors),
             @"feedbackCount":@(stats.feedbackCount), @"feedbackFramesRemaining":@(stats.feedbackFramesRemaining),
             @"error":self.lastError, @"defaultOutput":@(DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
             @"deviceID":@(_device), @"tapID":@(_tap), @"aggregateID":@(_aggregate),
             @"applications":self.applications, @"applicationSafetyError":self.applicationSafetyError, @"applicationRouteCount":@(_applicationRoutes.count),
             @"applicationRoutes":routes};
}
- (void)dealloc { [self stopMonitoringDevices]; [self stop]; }
@end
