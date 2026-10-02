#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UVSettingsController : NSWindowController
@property(nonatomic, copy, nullable) dispatch_block_t feedbackChanged;
@property(nonatomic, copy, nullable) dispatch_block_t keyboardPermissionRequested;
- (instancetype)init;
- (void)show;
- (void)updateKeyboardActive:(BOOL)active needsPermission:(BOOL)needsPermission;
- (void)showAbout;
@end

NS_ASSUME_NONNULL_END
