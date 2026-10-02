#ifndef USB_VOLUME_DSP_H
#define USB_VOLUME_DSP_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VDState VDState;

typedef struct VDStats {
    uint64_t callbacks;
    uint64_t frames;
    float inputPeak;
    float outputPeak;
    float currentGain;
    uint32_t formatErrors;
    uint64_t feedbackCount;
    uint32_t feedbackFramesRemaining;
} VDStats;

/* Create/destroy off the audio thread. Returns NULL for an invalid sample rate,
 * allocation failure, or a platform without lock-free required atomic types.
 * Gain is linear, clamped to [0,1]; a nonfinite gain becomes zero. */
VDState *VDCreate(double sampleRate, float initialGain);
void VDDestroy(VDState *state);

/* Safe to call concurrently with VDProcess. Changes ramp over 10 ms. */
void VDSetGain(VDState *state, float linearGain);

/* Request a gentle 80 ms confirmation tone, mixed into both output channels
 * before the current volume gain. Safe on any thread. Pending requests coalesce;
 * an active tone finishes before a pending tone begins. Muting cancels feedback
 * and requests made while muted are ignored. No sound is played elsewhere. */
void VDTriggerFeedback(VDState *state);

/* Called by one audio thread. Input/output must contain native-endian Float32
 * stereo PCM: either one interleaved stereo buffer, or two mono buffers.
 * The caller validates the stream's ASBD; an ABL alone cannot identify its PCM
 * encoding. Both sides must describe the same number of frames. Each ABL and
 * its stated buffers must be accessible and mDataByteSize must be accurate.
 * Disjoint buffers or exactly in-place matching layouts are supported; other
 * partial aliasing is not. No allocations, locks, logging, or OS calls occur.
 * Invalid/missing input becomes silence while confirmation feedback can still
 * play into valid output; nonfinite samples become zero. */
void VDProcess(VDState *state, const AudioBufferList *input,
               AudioBufferList *output);

/* Safe on any thread. Peaks describe the latest callback; counters accumulate.
 * This is a best-effort snapshot: individual fields can span adjacent callbacks.
 * frames counts valid output frames, including silence for invalid input. */
VDStats VDGetStats(const VDState *state);

#ifdef __cplusplus
}
#endif

#endif
