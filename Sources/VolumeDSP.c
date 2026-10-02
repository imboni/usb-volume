#include "VolumeDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct VDState {
    _Atomic float requestedGain;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames;
    _Atomic float inputPeak;
    _Atomic float outputPeak;
    _Atomic float reportedGain;
    _Atomic uint32_t formatErrors;
    _Atomic uint32_t requestedFeedback;
    _Atomic uint64_t feedbackCount;
    _Atomic uint32_t reportedFeedbackRemaining;
    /* Only the audio thread touches the following fields after creation. */
    double currentGain;
    double rampStep;
    float rampTarget;
    uint32_t rampFrames;
    uint32_t rampRemaining;
    uint32_t feedbackFrames;
    uint32_t feedbackRemaining;
    /* Generated once off the audio thread, then immutable. */
    float feedbackSamples[];
};

typedef struct VDLayout {
    unsigned char *data[2];
    uint32_t frames;
    uint32_t stride;
} VDLayout;

static float VDClampGain(float gain) {
    if (!isfinite(gain) || gain <= 0.0f) return 0.0f;
    return gain >= 1.0f ? 1.0f : gain;
}

static int VDReadLayout(const AudioBufferList *list, VDLayout *layout) {
    if (!list) return 0;
    if (list->mNumberBuffers == 1) {
        const AudioBuffer *buffer = &list->mBuffers[0];
        if (buffer->mNumberChannels != 2 ||
            buffer->mDataByteSize % (2 * sizeof(float)) != 0 ||
            (buffer->mDataByteSize > 0 && !buffer->mData)) return 0;
        layout->data[0] = buffer->mData;
        layout->data[1] = buffer->mData ?
            (unsigned char *)buffer->mData + sizeof(float) : NULL;
        layout->frames = buffer->mDataByteSize / (2 * sizeof(float));
        layout->stride = 2 * sizeof(float);
        return 1;
    }
    if (list->mNumberBuffers == 2) {
        const AudioBuffer *left = &list->mBuffers[0];
        const AudioBuffer *right = &list->mBuffers[1];
        if (left->mNumberChannels != 1 || right->mNumberChannels != 1 ||
            left->mDataByteSize != right->mDataByteSize ||
            left->mDataByteSize % sizeof(float) != 0 ||
            (left->mDataByteSize > 0 && (!left->mData || !right->mData)))
            return 0;
        layout->data[0] = left->mData;
        layout->data[1] = right->mData;
        layout->frames = left->mDataByteSize / sizeof(float);
        layout->stride = sizeof(float);
        return 1;
    }
    return 0;
}

static void VDSilence(AudioBufferList *output) {
    if (!output) return;
    for (uint32_t index = 0; index < output->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &output->mBuffers[index];
        if (buffer->mData && buffer->mDataByteSize)
            memset(buffer->mData, 0, buffer->mDataByteSize);
    }
}

static void VDStartRampIfNeeded(VDState *state) {
    float requested = atomic_load_explicit(&state->requestedGain,
                                           memory_order_relaxed);
    if (requested != state->rampTarget) {
        state->rampTarget = requested;
        state->rampRemaining = state->rampFrames;
        state->rampStep = ((double)requested - state->currentGain) /
                          state->rampFrames;
    }
}

static double VDAdvanceGain(VDState *state) {
    if (state->rampRemaining) {
        if (--state->rampRemaining == 0)
            state->currentGain = state->rampTarget;
        else
            state->currentGain += state->rampStep;
    }
    /* Protect the no-amplification invariant from floating-point roundoff. */
    return fmin(1.0, fmax(0.0, state->currentGain));
}

static void VDAdvanceSilentFrames(VDState *state, uint32_t frames) {
    if (frames >= state->rampRemaining) {
        state->currentGain = state->rampTarget;
        state->rampRemaining = 0;
    } else {
        state->currentGain += state->rampStep * frames;
        state->rampRemaining -= frames;
    }
}

VDState *VDCreate(double sampleRate, float initialGain) {
    if (!isfinite(sampleRate) || sampleRate < 1.0 || sampleRate > 768000.0)
        return NULL;
    const uint32_t feedbackFrames = (uint32_t)fmax(2.0, round(sampleRate * 0.080));
    VDState *state = calloc(1, sizeof(*state) + feedbackFrames * sizeof(float));
    if (!state) return NULL;
    const float gain = VDClampGain(initialGain);
    atomic_init(&state->requestedGain, gain);
    atomic_init(&state->callbacks, 0);
    atomic_init(&state->frames, 0);
    atomic_init(&state->inputPeak, 0);
    atomic_init(&state->outputPeak, 0);
    atomic_init(&state->reportedGain, gain);
    atomic_init(&state->formatErrors, 0);
    atomic_init(&state->requestedFeedback, 0);
    atomic_init(&state->feedbackCount, 0);
    atomic_init(&state->reportedFeedbackRemaining, 0);
    if (!atomic_is_lock_free(&state->requestedGain) ||
        !atomic_is_lock_free(&state->callbacks) ||
        !atomic_is_lock_free(&state->frames) ||
        !atomic_is_lock_free(&state->inputPeak) ||
        !atomic_is_lock_free(&state->outputPeak) ||
        !atomic_is_lock_free(&state->reportedGain) ||
        !atomic_is_lock_free(&state->formatErrors) ||
        !atomic_is_lock_free(&state->requestedFeedback) ||
        !atomic_is_lock_free(&state->feedbackCount) ||
        !atomic_is_lock_free(&state->reportedFeedbackRemaining)) {
        free(state);
        return NULL;
    }
    state->currentGain = gain;
    state->rampTarget = gain;
    state->rampFrames = (uint32_t)fmax(1.0, round(sampleRate * 0.010));
    state->feedbackFrames = feedbackFrames;
    const double pi = acos(-1.0);
    const double attackFrames = fmax(1.0, round(sampleRate * 0.004));
    /* A rounded 4 ms attack and smoothly decaying tail avoid clicks. Keeping
     * this table in the state avoids transcendental work in the I/O callback. */
    for (uint32_t frame = 1; frame + 1 < feedbackFrames; ++frame) {
        const double phase = (double)frame / sampleRate;
        const double attack = 0.5 - 0.5 * cos(pi * fmin(1.0, frame / attackFrames));
        const double progress = (double)frame / (feedbackFrames - 1);
        const double release = 0.5 + 0.5 * cos(pi * progress);
        const double wave = 0.72 * sin(2.0 * pi * 660.0 * phase) +
                            0.28 * sin(2.0 * pi * 990.0 * phase);
        state->feedbackSamples[frame] = (float)(0.05 * attack * release *
                                               release * wave);
    }
    return state;
}

void VDDestroy(VDState *state) { free(state); }

void VDSetGain(VDState *state, float linearGain) {
    if (state)
        atomic_store_explicit(&state->requestedGain, VDClampGain(linearGain),
                              memory_order_relaxed);
}

void VDTriggerFeedback(VDState *state) {
    if (state && atomic_load_explicit(&state->requestedGain,
                                      memory_order_relaxed) > 0.0f)
        atomic_store_explicit(&state->requestedFeedback, 1, memory_order_relaxed);
}

void VDProcess(VDState *state, const AudioBufferList *input,
               AudioBufferList *output) {
    if (!state) {
        VDSilence(output);
        return;
    }
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
    VDStartRampIfNeeded(state);
    if (state->rampTarget == 0.0f) {
        state->feedbackRemaining = 0;
        atomic_store_explicit(&state->requestedFeedback, 0, memory_order_relaxed);
    }
    VDLayout inLayout, outLayout;
    const int outputValid = VDReadLayout(output, &outLayout);
    const int inputValid = VDReadLayout(input, &inLayout);
    float inputPeak = 0.0f, outputPeak = 0.0f;
    if (!outputValid) {
        VDSilence(output);
        atomic_fetch_add_explicit(&state->formatErrors, 1, memory_order_relaxed);
    } else {
        /* A silent process tap may omit input completely. Its layout must never
         * be read unless validated, but confirmation still plays immediately. */
        const int inputUsable = inputValid && inLayout.frames == outLayout.frames;
        if (!inputUsable)
            atomic_fetch_add_explicit(&state->formatErrors, 1, memory_order_relaxed);
        if (outLayout.frames && state->rampTarget > 0.0f &&
            state->feedbackRemaining == 0 &&
            atomic_exchange_explicit(&state->requestedFeedback, 0,
                                     memory_order_relaxed)) {
            state->feedbackRemaining = state->feedbackFrames;
            atomic_fetch_add_explicit(&state->feedbackCount, 1, memory_order_relaxed);
        }
        if (!inputUsable && !state->feedbackRemaining) {
            /* Keep the existing invalid-input/no-feedback path exact. */
            VDSilence(output);
            VDAdvanceSilentFrames(state, outLayout.frames);
        } else for (uint32_t frame = 0; frame < outLayout.frames; ++frame) {
            const double gain = VDAdvanceGain(state);
            const int feedbackActive = state->feedbackRemaining > 0;
            const float feedback = feedbackActive ?
                state->feedbackSamples[state->feedbackFrames -
                                       state->feedbackRemaining--] : 0.0f;
            float samples[2] = {0.0f, 0.0f};
            /* memcpy tolerates an unaligned but otherwise valid PCM buffer. */
            for (uint32_t channel = 0; inputUsable && channel < 2; ++channel) {
                memcpy(&samples[channel], inLayout.data[channel] +
                       (size_t)frame * inLayout.stride, sizeof(float));
                if (!isfinite(samples[channel])) samples[channel] = 0.0f;
                inputPeak = fmaxf(inputPeak, fabsf(samples[channel]));
            }
            for (uint32_t channel = 0; channel < 2; ++channel) {
                /* Preserve the original PCM path exactly outside feedback.
                 * Saturate the feedback mix before gain so it cannot exceed
                 * full scale, including unusual but finite input samples. */
                const double mixed = feedbackActive ?
                    fmin(1.0, fmax(-1.0, (double)samples[channel] + feedback)) :
                    (double)samples[channel];
                const float sample = (float)(mixed * gain);
                outputPeak = fmaxf(outputPeak, fabsf(sample));
                memcpy(outLayout.data[channel] +
                       (size_t)frame * outLayout.stride, &sample, sizeof(float));
            }
        }
        atomic_fetch_add_explicit(&state->frames, outLayout.frames,
                                  memory_order_relaxed);
    }
    atomic_store_explicit(&state->inputPeak, inputPeak, memory_order_relaxed);
    atomic_store_explicit(&state->outputPeak, outputPeak, memory_order_relaxed);
    atomic_store_explicit(&state->reportedGain, (float)state->currentGain,
                          memory_order_relaxed);
    atomic_store_explicit(&state->reportedFeedbackRemaining,
                          state->feedbackRemaining, memory_order_relaxed);
}

VDStats VDGetStats(const VDState *state) {
    VDStats stats = {0};
    if (!state) return stats;
    stats.callbacks = atomic_load_explicit(&state->callbacks, memory_order_relaxed);
    stats.frames = atomic_load_explicit(&state->frames, memory_order_relaxed);
    stats.inputPeak = atomic_load_explicit(&state->inputPeak, memory_order_relaxed);
    stats.outputPeak = atomic_load_explicit(&state->outputPeak, memory_order_relaxed);
    stats.currentGain = atomic_load_explicit(&state->reportedGain, memory_order_relaxed);
    stats.formatErrors = atomic_load_explicit(&state->formatErrors, memory_order_relaxed);
    stats.feedbackCount = atomic_load_explicit(&state->feedbackCount, memory_order_relaxed);
    stats.feedbackFramesRemaining = atomic_load_explicit(&state->reportedFeedbackRemaining,
                                                        memory_order_relaxed);
    return stats;
}
