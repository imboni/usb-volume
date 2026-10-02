#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Read-only, current-user status endpoint. Start on the main thread; the
 * provider is invoked on that thread and must only return a status snapshot. */
@interface UVStatusServer : NSObject
@property(nonatomic, copy, nullable) NSDictionary * _Nullable (^reportProvider)(void);
- (BOOL)start;
- (void)stop;

/* Query an existing server without launching or activating its application.
 * Prints its JSON and a newline to stdout, or an error to stderr (exit 1). */
+ (int)printRunningStatus;
@end

NS_ASSUME_NONNULL_END
