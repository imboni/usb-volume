#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, UVMediaKey) {
    UVMediaKeyUp,
    UVMediaKeyDown,
    UVMediaKeyMute
};

/* Main-thread-only media-key controller. It observes only system-defined media
 * events; ordinary keyboard input is neither read nor retained.
 * The tap parses/filters synchronously, then delivers handlers asynchronously
 * on the main queue so UI and audio work cannot block the event callback.
 */
@interface UVMediaKeys : NSObject

/* Set YES only while software volume is controlling the selected output.
 * When NO, all events pass through unchanged, even if the tap is active. */
@property(nonatomic) BOOL enabled;
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) BOOL needsPermission;
@property(nonatomic, readonly, copy) NSString *lastError;
/* Read-only lifetime counters for media-key delivery and filtering. Contains no
 * ordinary key data. Reading this snapshot does not create a tap or prompt. */
@property(nonatomic, readonly, copy) NSDictionary<NSString *, id> *diagnostics;
@property(nonatomic, copy, nullable) void (^handler)(UVMediaKey key, BOOL fineAdjustment);
/* Optional ownership check immediately before interception and delivery.
 * This MUST read cached state only: no CoreAudio calls, UI work, I/O or locks
 * that can block. Return NO when the app no longer owns the selected output. */
@property(nonatomic, copy, nullable) BOOL (^shouldHandle)(void);
/* One release per handled down sequence. Use this for a release feedback sound;
 * key repeats keep calling handler but never call releaseHandler. */
@property(nonatomic, copy, nullable) void (^releaseHandler)(UVMediaKey key);

/* Idempotent. Tries HID first, then session once if HID creation is rejected.
 * Reports the actual location and enabled state; an existing active tap is
 * retained. Does not prompt for or change Accessibility permission. */
- (BOOL)start;
- (void)stop;

/* Call only in response to the user's explicit Enable Keyboard Control action.
 * The system prompt is asynchronous; retry start when the app becomes active. */
- (void)requestPermission;
@end

NS_ASSUME_NONNULL_END
