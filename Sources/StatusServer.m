#import "StatusServer.h"
#import "Localization.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>

static NSString *UVStatusServiceName(void) {
    return [NSString stringWithFormat:@"local.lee.USBVolume.status.%u", (unsigned int)getuid()];
}

static CFDataRef UVStatusRequest(CFMessagePortRef port, SInt32 messageID,
                                 CFDataRef data, void *context) {
    (void)port;
    (void)data;
    // No commands, payload interpretation, or side effects are supported.
    if (messageID != 1) return NULL;
    @autoreleasepool {
        UVStatusServer *server = (__bridge UVStatusServer *)context;
        NSDictionary *(^provider)(void) = server.reportProvider;
        if (!provider) return NULL;
        NSDictionary *report = provider();
        if (![report isKindOfClass:NSDictionary.class] ||
            ![NSJSONSerialization isValidJSONObject:report]) return NULL;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        // CFMessagePort takes ownership of the callback's returned data.
        return json ? CFBridgingRetain(json) : NULL;
    }
}

@implementation UVStatusServer {
    CFMessagePortRef _port;
    CFRunLoopSourceRef _source;
}

- (BOOL)start {
    if (!NSThread.isMainThread) return NO;
    if (_port && CFMessagePortIsValid(_port)) return YES;
    [self stop];
    CFMessagePortContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    Boolean unusedContext = false;
    _port = CFMessagePortCreateLocal(kCFAllocatorDefault,
                                     (__bridge CFStringRef)UVStatusServiceName(),
                                     UVStatusRequest, &context, &unusedContext);
    if (!_port) return NO;
    if (unusedContext) {
        // The name already belongs to another local object. Do not invalidate it.
        CFRelease(_port);
        _port = NULL;
        return NO;
    }
    _source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, _port, 0);
    if (!_source) { [self stop]; return NO; }
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    return YES;
}

- (void)stop {
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRunLoopSourceInvalidate(_source);
        CFRelease(_source);
        _source = NULL;
    }
    if (_port) {
        CFMessagePortInvalidate(_port);
        CFRelease(_port);
        _port = NULL;
    }
}

+ (int)printRunningStatus {
    @autoreleasepool {
        CFMessagePortRef remote = CFMessagePortCreateRemote(kCFAllocatorDefault,
                                    (__bridge CFStringRef)UVStatusServiceName());
        if (!remote) {
            fputs([UVL(@"USB 音量未运行，无法读取状态。") stringByAppendingString:@"\n"].UTF8String, stderr);
            return 1;
        }
        CFDataRef response = NULL;
        // The combined send/receive wait budget is less than two seconds.
        SInt32 result = CFMessagePortSendRequest(remote, 1, NULL, 0.25, 1.5,
                                                 kCFRunLoopDefaultMode, &response);
        CFRelease(remote);
        if (result != kCFMessagePortSuccess || !response) {
            if (response) CFRelease(response);
            fputs([UVL(@"USB 音量未运行或状态服务未响应。") stringByAppendingString:@"\n"].UTF8String, stderr);
            return 1;
        }
        NSData *json = CFBridgingRelease(response);
        if (!json.length) {
            fputs([UVL(@"USB 音量状态不可用。") stringByAppendingString:@"\n"].UTF8String, stderr);
            return 1;
        }
        if (fwrite(json.bytes, 1, json.length, stdout) != json.length ||
            fputc('\n', stdout) == EOF || fflush(stdout) == EOF) {
            fputs([UVL(@"无法输出 USB 音量状态。") stringByAppendingString:@"\n"].UTF8String, stderr);
            return 1;
        }
        return 0;
    }
}

- (void)dealloc { [self stop]; }
@end
