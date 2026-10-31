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
// Application rows contain id, name, bundleID, volume, muted, active,
// controllable, applied and error. Public methods are called on the main thread.
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *applications;
@property(nonatomic, readonly, copy) NSString *applicationSafetyError;
- (void)refreshApplications;
- (BOOL)setApplicationVolume:(float)volume forID:(NSString *)identifier error:(NSError **)error;
- (BOOL)setApplicationMuted:(BOOL)muted forID:(NSString *)identifier error:(NSError **)error;
- (void)resetApplicationVolumes;
@property(nonatomic, copy, nullable) dispatch_block_t stateChanged;
@property(nonatomic, copy, nullable) dispatch_block_t devicesChanged;
- (BOOL)startMonitoringDevices;
- (void)stopMonitoringDevices;
- (NSArray<NSDictionary *> *)devices;
- (BOOL)startDeviceUID:(NSString *)uid error:(NSError **)error;
- (void)stop;
- (void)clearError;
- (void)playFeedback;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
