#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface UVAudioController : NSObject
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) BOOL ownsDefaultOutput;
@property(nonatomic, readonly, copy) NSString *deviceName;
@property(nonatomic, readonly, copy) NSString *lastError;
@property(nonatomic, readonly, copy) NSString *lastErrorKey;
@property(nonatomic) float volume;
@property(nonatomic) BOOL muted;
@property(nonatomic, copy, nullable) dispatch_block_t stateChanged;
- (NSArray<NSDictionary *> *)devices;
- (BOOL)startDeviceUID:(NSString *)uid error:(NSError **)error;
- (void)stop;
- (void)playFeedback;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
