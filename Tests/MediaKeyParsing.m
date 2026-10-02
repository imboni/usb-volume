#import <AppKit/AppKit.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import "../Sources/MediaKeys.h"
#include <assert.h>

// Exercise the exact event-decoding path without creating a global event tap,
// requesting permission, or posting synthetic keys to the user's desktop.
@interface UVMediaKeys (ParsingTests)
- (BOOL)consumeMediaEvent:(NSEvent *)event;
- (CGEventRef)filterCGEvent:(CGEventRef)event type:(CGEventType)type;
@end

@interface UVMediaKeys (ParsingTestHelpers)
- (BOOL)consumeAndDrain:(NSEvent *)event;
@end

static void DrainMainQueue(void) {
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    while (!finished) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
}

@implementation UVMediaKeys (ParsingTestHelpers)
- (BOOL)consumeAndDrain:(NSEvent *)event {
    BOOL consumed = [self consumeMediaEvent:event];
    DrainMainQueue();
    return consumed;
}
@end

static NSEvent *Media(uint16_t key, uint8_t state, BOOL repeat,
                      NSEventModifierFlags modifiers, short subtype) {
    NSInteger data = ((uint32_t)key << 16) | ((uint32_t)state << 8) | (repeat ? 1 : 0);
    return [NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint
                       modifierFlags:modifiers timestamp:0 windowNumber:0
                             context:nil subtype:subtype data1:data data2:0];
}

int main(void) {
    @autoreleasepool {
        UVMediaKeys *keys = [UVMediaKeys new];
        __block NSUInteger calls = 0;
        __block UVMediaKey last = UVMediaKeyMute;
        __block BOOL fine = NO;
        __block NSUInteger releases = 0;
        __block UVMediaKey releasedKey = UVMediaKeyMute;
        __block BOOL ownsOutput = YES;
        keys.handler = ^(UVMediaKey key, BOOL small) { calls++; last = key; fine = small; };
        keys.releaseHandler = ^(UVMediaKey key) { releases++; releasedKey = key; };
        keys.shouldHandle = ^{ return ownsOutput; };
        NSEvent *up = Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, NO, 0, 8);
        assert(![keys consumeAndDrain:up] && calls == 0); // disabled passthrough
        assert([keys.diagnostics[@"recognizedMediaEvents"] unsignedLongLongValue] == 1);
        assert([keys.diagnostics[@"disabledIgnored"] unsignedLongLongValue] == 1);
        keys.enabled = YES;
        assert([keys consumeAndDrain:up] && calls == 1 && last == UVMediaKeyUp && !fine);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8)] && calls == 1 && releases == 1 && releasedKey == UVMediaKeyUp);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8)] && releases == 1); // duplicate release
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, YES, 0, 8)] && calls == 2);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_DOWN, NX_KEYDOWN, YES, 0, 8)] && calls == 3 && last == UVMediaKeyDown);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_MUTE, NX_KEYDOWN, NO, 0, 8)] && calls == 4 && last == UVMediaKeyMute);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_MUTE, NX_KEYDOWN, YES, 0, 8)] && calls == 4 && releases == 1);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_MUTE, NX_KEYUP, NO, 0, 8)] && calls == 4 && releases == 2 && releasedKey == UVMediaKeyMute);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, NO, NSEventModifierFlagShift | NSEventModifierFlagOption, 8)] && calls == 5 && fine);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, NO, NSEventModifierFlagShift, 8)] && calls == 6 && !fine);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, NO, NSEventModifierFlagOption, 8)] && calls == 7 && !fine);
        assert(![keys consumeAndDrain:Media(NX_KEYTYPE_PLAY, NX_KEYDOWN, NO, 0, 8)] && calls == 7);
        assert(![keys consumeAndDrain:Media(NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYDOWN, NO, 0, 8)] && calls == 7);
        NSEvent *ordinaryKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                         modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                            characters:@"a" charactersIgnoringModifiers:@"a"
                                             isARepeat:NO keyCode:0];
        NSDictionary *beforeOrdinaryKey = keys.diagnostics;
        assert(![keys consumeAndDrain:ordinaryKey] && calls == 7);
        assert([keys.diagnostics isEqualToDictionary:beforeOrdinaryKey]);
        assert(![keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, NO, 0, 9)] && calls == 7);
        assert(![keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, 12, NO, 0, 8)] && calls == 7);
        ownsOutput = NO;
        assert(![keys consumeAndDrain:up] && calls == 7);
        assert(![keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8)] && releases == 2);
        ownsOutput = YES;
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8)] && releases == 2); // stale release cleared
        assert([keys consumeAndDrain:up] && calls == 8);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, YES, 0, 8)] && calls == 9 && releases == 2);
        assert([keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8)] && calls == 9 && releases == 3);
        keys.enabled = NO;
        assert(![keys consumeAndDrain:Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8)] && calls == 9 && releases == 3);
        keys.enabled = YES; keys.handler = nil;
        assert(![keys consumeAndDrain:up]); // no handler, no dropped key
        [keys stop]; [keys stop];
        assert(!keys.active);
        NSDictionary *stats = keys.diagnostics;
        assert([stats[@"handledDowns"] unsignedLongLongValue] == calls);
        assert([stats[@"handledUps"] unsignedLongLongValue] == releases);
        assert([stats[@"routeRejected"] unsignedLongLongValue] == 2);
        assert([stats[@"disabledIgnored"] unsignedLongLongValue] == 2);
        assert([stats[@"missingHandlerIgnored"] unsignedLongLongValue] == 1);
        assert([stats[@"invalidStates"] unsignedLongLongValue] == 1);
        assert([stats[@"repeats"] unsignedLongLongValue] == 4);
        assert([stats[@"lastRecognizedKey"] integerValue] == NX_KEYTYPE_SOUND_UP);
        assert([stats[@"lastRecognizedState"] integerValue] == NX_KEYDOWN);
        // Match the real tap callback's CGEvent -> NSEvent bridge, still without
        // posting any input to the system or requesting a global event tap.
        CGEventRef packedEvent = up.CGEvent;
        assert(packedEvent != NULL);
        NSEvent *roundTrip = [NSEvent eventWithCGEvent:packedEvent];
        assert(roundTrip.type == NSEventTypeSystemDefined && roundTrip.subtype == 8);
        assert(roundTrip.data1 == up.data1);
        UVMediaKeys *bridgedKeys = [UVMediaKeys new];
        bridgedKeys.enabled = YES;
        __block BOOL bridgedHandled = NO;
        bridgedKeys.handler = ^(UVMediaKey key, BOOL small) {
            bridgedHandled = key == UVMediaKeyUp && !small;
        };
        assert([bridgedKeys consumeAndDrain:roundTrip] && bridgedHandled);
        // The production CGEvent callback path decides consumption immediately,
        // while handler work waits for the main queue, retaining event order.
        UVMediaKeys *asyncKeys = [UVMediaKeys new];
        asyncKeys.enabled = YES;
        __block BOOL asyncOwnsOutput = YES;
        NSMutableArray<NSString *> *order = [NSMutableArray new];
        asyncKeys.shouldHandle = ^{ return asyncOwnsOutput; };
        asyncKeys.handler = ^(UVMediaKey key, BOOL small) {
            assert(key == UVMediaKeyUp && !small);
            [order addObject:@"down"];
        };
        asyncKeys.releaseHandler = ^(UVMediaKey key) {
            assert(key == UVMediaKeyUp);
            [order addObject:@"up"];
        };
        NSEvent *release = Media(NX_KEYTYPE_SOUND_UP, NX_KEYUP, NO, 0, 8);
        NSEvent *repeated = Media(NX_KEYTYPE_SOUND_UP, NX_KEYDOWN, YES, 0, 8);
        assert([asyncKeys filterCGEvent:up.CGEvent type:(CGEventType)NX_SYSDEFINED] == NULL);
        assert([asyncKeys filterCGEvent:repeated.CGEvent type:(CGEventType)NX_SYSDEFINED] == NULL);
        assert([asyncKeys filterCGEvent:release.CGEvent type:(CGEventType)NX_SYSDEFINED] == NULL);
        assert(order.count == 0); // No handler executes inside the tap callback.
        assert([asyncKeys.diagnostics[@"handledDowns"] unsignedLongLongValue] == 2);
        assert([asyncKeys.diagnostics[@"deliveredDowns"] unsignedLongLongValue] == 0);
        DrainMainQueue();
        assert(([order isEqualToArray:@[@"down", @"down", @"up"]]));
        assert([asyncKeys.diagnostics[@"deliveredDowns"] unsignedLongLongValue] == 2);
        assert([asyncKeys.diagnostics[@"deliveredUps"] unsignedLongLongValue] == 1);
        assert([asyncKeys.diagnostics[@"tapLocation"] isEqualToString:@"hid"]);

        // Already accepted events must not alter volume after disabling,
        // stopping/restarting, or losing the selected audio route.
        assert([asyncKeys consumeMediaEvent:up]);
        asyncKeys.enabled = NO;
        asyncKeys.enabled = YES;
        DrainMainQueue();
        assert(order.count == 3);
        assert([asyncKeys consumeMediaEvent:up]);
        [asyncKeys stop];
        DrainMainQueue();
        assert(order.count == 3);
        assert([asyncKeys consumeMediaEvent:up]);
        asyncOwnsOutput = NO;
        DrainMainQueue();
        assert(order.count == 3);
        assert([asyncKeys.diagnostics[@"cancelledDeliveries"] unsignedLongLongValue] == 3);

        // Unknown media keys and ordinary keys preserve the original event
        // pointer and do not enqueue work through the production callback path.
        asyncOwnsOutput = YES;
        assert([asyncKeys consumeMediaEvent:release]);
        DrainMainQueue();
        assert(order.count == 3); // A cancelled down cannot produce stale feedback.
        NSEvent *brightness = Media(NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYDOWN, NO, 0, 8);
        CGEventRef brightnessEvent = brightness.CGEvent;
        assert([asyncKeys filterCGEvent:brightnessEvent type:(CGEventType)NX_SYSDEFINED] == brightnessEvent);
        CGEventRef ordinaryEvent = ordinaryKey.CGEvent;
        assert([asyncKeys filterCGEvent:ordinaryEvent type:kCGEventKeyDown] == ordinaryEvent);
        DrainMainQueue();
        assert(order.count == 3);
        puts("Media key parsing: passed (media filtering, repeats, async callback order, stale-delivery cancellation).");
    }
    return 0;
}
