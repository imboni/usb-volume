#import "MediaKeys.h"
#import "Localization.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <IOKit/hidsystem/ev_keymap.h>

@interface UVMediaKeys ()
- (BOOL)consumeMediaEvent:(NSEvent *)event;
- (CGEventRef)filterCGEvent:(CGEventRef)event type:(CGEventType)type;
- (void)enqueueKey:(UVMediaKey)key fine:(BOOL)fine release:(BOOL)release;
- (void)recoverFromTimeout;
- (void)recordUnconvertedSystemEvent;
- (void)recordUserDisabled;
@end

static CGEventRef UVMediaKeyCallback(CGEventTapProxy proxy, CGEventType type,
                                    CGEventRef event, void *context) {
    (void)proxy;
    @autoreleasepool {
        UVMediaKeys *controller = (__bridge UVMediaKeys *)context;
        return [controller filterCGEvent:event type:type];
    }
}

@implementation UVMediaKeys {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    NSString *_lastError;
    NSUInteger _ownedDownMask;
    uint64_t _deliveryGeneration;
    uint64_t _systemDefinedEvents;
    uint64_t _auxEvents;
    uint64_t _recognizedMediaEvents;
    uint64_t _handledDowns;
    uint64_t _handledUps;
    uint64_t _deliveredDowns;
    uint64_t _deliveredUps;
    uint64_t _cancelledDeliveries;
    uint64_t _repeats;
    uint64_t _routeRejected;
    uint64_t _disabledIgnored;
    uint64_t _missingHandlerIgnored;
    uint64_t _invalidStates;
    uint64_t _timeouts;
    uint64_t _userDisabled;
    uint64_t _conversionFailures;
    NSInteger _lastRecognizedKey;
    NSInteger _lastRecognizedState;
    BOOL _lastRecognizedRepeat;
}
@synthesize enabled = _enabled, handler = _handler;
@synthesize shouldHandle = _shouldHandle, releaseHandler = _releaseHandler;

- (instancetype)init {
    if ((self = [super init])) {
        _lastError = @"";
        _lastRecognizedKey = -1;
        _lastRecognizedState = -1;
    }
    return self;
}

- (BOOL)needsPermission {
    // AXIsProcessTrusted never requests the user's permission.
    return !AXIsProcessTrusted();
}

- (BOOL)active {
    return _tap && CFMachPortIsValid(_tap) && CGEventTapIsEnabled(_tap);
}

- (NSString *)lastError { return _lastError.length ? UVL(_lastError) : @""; }

- (NSDictionary<NSString *,id> *)diagnostics {
    return @{
        @"tapLocation":@"hid", @"enabled":@(_enabled), @"active":@(self.active),
        @"systemDefinedEvents":@(_systemDefinedEvents), @"auxEvents":@(_auxEvents),
        @"recognizedMediaEvents":@(_recognizedMediaEvents),
        @"handledDowns":@(_handledDowns), @"handledUps":@(_handledUps),
        @"deliveredDowns":@(_deliveredDowns), @"deliveredUps":@(_deliveredUps),
        @"cancelledDeliveries":@(_cancelledDeliveries),
        @"repeats":@(_repeats), @"routeRejected":@(_routeRejected),
        @"disabledIgnored":@(_disabledIgnored), @"missingHandlerIgnored":@(_missingHandlerIgnored),
        @"invalidStates":@(_invalidStates), @"timeouts":@(_timeouts),
        @"userDisabled":@(_userDisabled), @"conversionFailures":@(_conversionFailures),
        @"lastRecognizedKey":@(_lastRecognizedKey),
        @"lastRecognizedState":@(_lastRecognizedState),
        @"lastRecognizedRepeat":@(_lastRecognizedRepeat)
    };
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled && !enabled) _deliveryGeneration++;
    _enabled = enabled;
    if (!enabled) _ownedDownMask = 0;
}

- (BOOL)start {
    NSAssert(NSThread.isMainThread, @"Media-key control must run on the main thread.");
    if (self.needsPermission) {
        [self stop];
        _lastError = @"请在系统设置 → 隐私与安全性 → 辅助功能中允许「USB 音量」控制键盘音量键。";
        return NO;
    }
    if (self.active) { _lastError = @""; return YES; }
    [self stop];
    // HID precedes session taps such as MonitorControl's. Filtering still
    // consumes only the three volume keys while our selected route is owned.
    _tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault,
                            CGEventMaskBit(NX_SYSDEFINED),
                            UVMediaKeyCallback, (__bridge void *)self);
    if (!_tap) {
        _lastError = @"无法创建键盘音量控制。请确认辅助功能权限后重新打开应用；键盘控制当前未启用。";
        return NO;
    }
    _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    if (!_source) {
        [self stop];
        _lastError = @"无法创建键盘音量控制，请重新打开应用。";
        return NO;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    if (!self.active) {
        [self stop];
        _lastError = @"键盘音量控制尚未就绪，请重新打开应用。";
        return NO;
    }
    _lastError = @"";
    return YES;
}

- (void)stop {
    _deliveryGeneration++;
    _ownedDownMask = 0;
    if (_tap) CGEventTapEnable(_tap, false);
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRunLoopSourceInvalidate(_source);
        CFRelease(_source);
        _source = NULL;
    }
    if (_tap) {
        CFMachPortInvalidate(_tap);
        CFRelease(_tap);
        _tap = NULL;
    }
}

- (void)requestPermission {
    NSAssert(NSThread.isMainThread, @"Request media-key permission on the main thread.");
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (void)recoverFromTimeout {
    _timeouts++;
    // Permission may have been revoked while a tap existed. Never recreate or
    // prompt from a callback; start can retry after an explicit UI action.
    if (_tap && CFMachPortIsValid(_tap) && AXIsProcessTrusted())
        CGEventTapEnable(_tap, true);
}

- (void)recordUnconvertedSystemEvent {
    _systemDefinedEvents++;
    _conversionFailures++;
}

- (void)recordUserDisabled { _userDisabled++; }

- (CGEventRef)filterCGEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout) {
        [self recoverFromTimeout];
        return event;
    }
    if (type == kCGEventTapDisabledByUserInput) {
        [self recordUserDisabled];
        return event;
    }
    if (type != (CGEventType)NX_SYSDEFINED || !event) return event;
    NSEvent *nativeEvent = [NSEvent eventWithCGEvent:event];
    if (!nativeEvent) [self recordUnconvertedSystemEvent];
    return nativeEvent && [self consumeMediaEvent:nativeEvent] ? NULL : event;
}

- (void)enqueueKey:(UVMediaKey)key fine:(BOOL)fine release:(BOOL)release {
    const uint64_t generation = _deliveryGeneration;
    __weak UVMediaKeys *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UVMediaKeys *controller = weakSelf;
        if (!controller) return;
        if (generation != controller->_deliveryGeneration || !controller->_enabled ||
            !controller->_handler) {
            controller->_cancelledDeliveries++;
            return;
        }
        if (controller->_shouldHandle && !controller->_shouldHandle()) {
            controller->_routeRejected++;
            controller->_ownedDownMask = 0;
            controller->_deliveryGeneration++;
            controller->_cancelledDeliveries++;
            return;
        }
        if (release) {
            if (controller->_releaseHandler) {
                controller->_deliveredUps++;
                controller->_releaseHandler(key);
            }
        } else {
            controller->_deliveredDowns++;
            controller->_handler(key, fine);
        }
    });
}

- (BOOL)consumeMediaEvent:(NSEvent *)event {
    if (event.type != NSEventTypeSystemDefined) return NO;
    _systemDefinedEvents++;
    if (event.subtype != NX_SUBTYPE_AUX_CONTROL_BUTTONS) return NO;
    _auxEvents++;

    // NX auxiliary-control data1: upper 16 bits = key; lower 16 bits = flags.
    // Flags' high byte is NX_KEYDOWN/NX_KEYUP; low bit marks autorepeat.
    const uint32_t data = (uint32_t)event.data1;
    const uint16_t nativeKey = (uint16_t)(data >> 16);
    const uint8_t state = (uint8_t)((data >> 8) & 0xff);
    const BOOL repeat = (data & 1) != 0;
    UVMediaKey key;
    switch (nativeKey) {
        case NX_KEYTYPE_SOUND_UP: key = UVMediaKeyUp; break;
        case NX_KEYTYPE_SOUND_DOWN: key = UVMediaKeyDown; break;
        case NX_KEYTYPE_MUTE: key = UVMediaKeyMute; break;
        default: return NO;
    }
    _recognizedMediaEvents++;
    _lastRecognizedKey = nativeKey;
    _lastRecognizedState = state;
    _lastRecognizedRepeat = repeat;
    if (repeat) _repeats++;
    if (state != NX_KEYDOWN && state != NX_KEYUP) {
        _invalidStates++;
        return NO;
    }
    if (!_enabled) { _disabledIgnored++; return NO; }
    if (!_handler) { _missingHandlerIgnored++; return NO; }
    if (_shouldHandle && !_shouldHandle()) {
        _routeRejected++;
        _ownedDownMask = 0;
        _deliveryGeneration++;
        return NO;
    }
    const NSUInteger keyMask = (NSUInteger)1 << key;
    if (state == NX_KEYDOWN && (key != UVMediaKeyMute || !repeat)) {
        _handledDowns++;
        _ownedDownMask |= keyMask;
        NSEventModifierFlags fineMask = NSEventModifierFlagShift | NSEventModifierFlagOption;
        BOOL fine = (event.modifierFlags & fineMask) == fineMask;
        [self enqueueKey:key fine:fine release:NO];
    } else if (state == NX_KEYUP) {
        const BOOL owned = (_ownedDownMask & keyMask) != 0;
        _ownedDownMask &= ~keyMask;
        if (owned) _handledUps++;
        if (owned && _releaseHandler) [self enqueueKey:key fine:NO release:YES];
    }
    // Consume key-up as well as key-down/repeat to suppress the native muted /
    // unavailable volume overlay. Other media keys always pass through.
    return YES;
}

- (void)dealloc { [self stop]; }
@end
