#import "AudioController.h"
#import "Localization.h"
#import "VolumeDSP.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <unistd.h>
#import <math.h>
#import <os/log.h>

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
static NSArray<NSNumber *> *Objects(AudioObjectID object, AudioObjectPropertySelector selector,
                                    AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Address(selector, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &a, 0, NULL, &size) != noErr || !size) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(object, &a, 0, NULL, &size, data.mutableBytes) != noErr) return @[];
    NSMutableArray *result = [NSMutableArray array];
    AudioObjectID *ids = data.mutableBytes;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [result addObject:@(ids[i])];
    return result;
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
}
@synthesize running = _running, volume = _volume, muted = _muted;
@synthesize deviceName = _deviceName;

- (NSString *)lastErrorKey { return _lastError; }
- (NSString *)lastError {
    if (!_lastError.length) return @"";
    return _lastErrorStatus == noErr ? UVL(_lastError) : [NSString stringWithFormat:UVL(@"%@（错误 %d）"), UVL(_lastError), (int)_lastErrorStatus];
}

- (instancetype)init {
    if ((self = [super init])) {
        _volume = 0.2f;
        _deviceName = @"";
        _lastError = @"";
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
        [devices addObject:@{@"id":number, @"uid":uid, @"name":name}];
    }
    return devices;
}
- (void)setVolume:(float)volume {
    _volume = isfinite(volume) ? fmaxf(0, fminf(1, volume)) : 0;
    if (_dsp) VDSetGain(_dsp, _muted ? 0 : _volume * _volume);
}
- (void)setMuted:(BOOL)muted {
    _muted = muted;
    if (_dsp) VDSetGain(_dsp, _muted ? 0 : _volume * _volume);
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
    }
}
- (void)stop {
    [_healthTimer invalidate]; _healthTimer = nil;
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
    return @{@"running":@(_running), @"device":_deviceName ?: @"", @"uid":_selectedUID ?: @"",
             @"volume":@(_volume), @"muted":@(_muted), @"sampleRate":@(_sampleRate),
             @"callbacks":@(stats.callbacks), @"frames":@(stats.frames),
             @"inputPeak":@(stats.inputPeak), @"outputPeak":@(stats.outputPeak),
             @"currentGain":@(stats.currentGain), @"formatErrors":@(stats.formatErrors),
             @"feedbackCount":@(stats.feedbackCount), @"feedbackFramesRemaining":@(stats.feedbackFramesRemaining),
             @"error":self.lastError, @"defaultOutput":@(DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
             @"deviceID":@(_device), @"tapID":@(_tap), @"aggregateID":@(_aggregate)};
}
- (void)dealloc { [self stop]; }
@end
