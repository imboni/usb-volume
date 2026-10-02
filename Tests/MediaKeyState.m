// Exercise the real app handler against in-memory audio state. No event posting,
// audio device access, system permission changes, or saved-preference writes.
#define main UVApplicationMain
#import "../Sources/main.m"
#undef main
#include <assert.h>

@interface UVTestAudio : UVAudioController
@property(nonatomic) float level;
@property(nonatomic) BOOL silent;
@property(nonatomic) BOOL ownsOutput;
@end
@implementation UVTestAudio
- (float)volume { return self.level; }
- (void)setVolume:(float)value { self.level = value; }
- (BOOL)muted { return self.silent; }
- (void)setMuted:(BOOL)value { self.silent = value; }
- (BOOL)ownsDefaultOutput { return self.ownsOutput; }
@end

@interface UVTestDelegate : UVAppDelegate
@property(nonatomic) NSUInteger previews;
@property(nonatomic) NSUInteger updates;
@end
@implementation UVTestDelegate
- (void)saveVolumeState {}
- (void)updateUI { self.updates++; }
- (void)playFeedback {
    if (!self.audio.muted && self.audio.volume > 0) self.previews++;
}
@end

int main(void) {
    @autoreleasepool {
        UVTestDelegate *app = [UVTestDelegate new];
        UVTestAudio *audio = [UVTestAudio new];
        app.audio = audio; audio.ownsOutput = YES; audio.volume = 0.5f;
        [app mediaKeyPressed:UVMediaKeyUp fine:NO];
        assert(audio.volume == 0.5625f && app.previews == 0);
        [app mediaKeyPressed:UVMediaKeyUp fine:NO];
        assert(audio.volume == 0.625f && app.previews == 0);
        [app mediaKeyReleased:UVMediaKeyUp];
        [app mediaKeyReleased:UVMediaKeyUp];
        assert(app.previews == 1); // a held/repeated key previews once on release
        [app mediaKeyPressed:UVMediaKeyDown fine:YES];
        assert(audio.volume == 0.609375f);
        [app mediaKeyReleased:UVMediaKeyDown];
        assert(app.previews == 2);
        audio.volume = 1; audio.muted = YES;
        [app mediaKeyPressed:UVMediaKeyUp fine:NO];
        assert(audio.volume == 1 && !audio.muted); // clamped up still unmutes
        [app mediaKeyReleased:UVMediaKeyUp];
        assert(app.previews == 3);
        [app mediaKeyPressed:UVMediaKeyUp fine:NO];
        [app mediaKeyReleased:UVMediaKeyUp];
        assert(audio.volume == 1 && app.previews == 3); // unchanged maximum
        audio.volume = 0.01f;
        [app mediaKeyPressed:UVMediaKeyDown fine:NO];
        [app mediaKeyReleased:UVMediaKeyDown];
        assert(audio.volume == 0 && app.previews == 3);
        audio.volume = 0.5f;
        [app mediaKeyPressed:UVMediaKeyMute fine:NO];
        assert(audio.muted && audio.volume == 0.5f);
        [app mediaKeyReleased:UVMediaKeyMute];
        [app mediaKeyPressed:UVMediaKeyMute fine:NO];
        assert(!audio.muted && app.previews == 3);
        audio.ownsOutput = NO;
        [app mediaKeyPressed:UVMediaKeyDown fine:NO];
        [app mediaKeyPressed:UVMediaKeyMute fine:NO];
        assert(audio.volume == 0.5f && !audio.muted);
        puts("Media key app state: passed (sync, repeat release, limits, mute, route ownership).");
    }
    return 0;
}
