#include "VolumeDSP.h"

#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct StereoList {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} StereoList;

static AudioBufferList interleaved(float *data, unsigned frames) {
    AudioBufferList list = {1, {{2, frames * 2 * sizeof(float), data}}};
    return list;
}

static StereoList planar(float *left, float *right, unsigned frames) {
    StereoList list = {2, {{1, frames * sizeof(float), left},
                          {1, frames * sizeof(float), right}}};
    return list;
}

static void closeEnough(double actual, double expected, double tolerance) {
    if (fabs(actual - expected) > tolerance) {
        fprintf(stderr, "Expected %.12f, got %.12f (tolerance %.12f)\n",
                expected, actual, tolerance);
        assert(0);
    }
}

static void testSineAttenuation(void) {
    enum { frames = 4800 };
    float input[2 * frames], output[2 * frames];
    double inputEnergy = 0, outputEnergy = 0;
    for (unsigned i = 0; i < frames; ++i) {
        input[2 * i] = (float)(0.8 * sin(2 * M_PI * 1000 * i / 48000));
        input[2 * i + 1] = -input[2 * i];
    }
    AudioBufferList in = interleaved(input, frames);
    AudioBufferList out = interleaved(output, frames);
    VDState *state = VDCreate(48000, 0.04f);
    assert(state);
    VDProcess(state, &in, &out);
    for (unsigned i = 0; i < 2 * frames; ++i) {
        inputEnergy += (double)input[i] * input[i];
        outputEnergy += (double)output[i] * output[i];
    }
    closeEnough(sqrt(outputEnergy / inputEnergy), 0.04, 0.00000001);
    VDStats stats = VDGetStats(state);
    assert(stats.callbacks == 1 && stats.frames == frames && !stats.formatErrors);
    closeEnough(stats.inputPeak, 0.8, 0.000001);
    closeEnough(stats.outputPeak, 0.032, 0.000001);
    VDDestroy(state);
}

static void testStereoLayouts(void) {
    float left[] = {0.2f, -0.5f, 0.75f};
    float right[] = {-0.7f, 0.1f, 0.0f};
    float packed[6] = {0}, outLeft[3] = {0}, outRight[3] = {0};
    StereoList in = planar(left, right, 3);
    AudioBufferList middle = interleaved(packed, 3);
    StereoList out = planar(outLeft, outRight, 3);
    VDState *state = VDCreate(48000, 0.5f);
    VDProcess(state, (AudioBufferList *)&in, &middle);
    for (unsigned i = 0; i < 3; ++i) {
        assert(packed[2 * i] == left[i] * 0.5f);
        assert(packed[2 * i + 1] == right[i] * 0.5f);
    }
    VDProcess(state, &middle, (AudioBufferList *)&out);
    for (unsigned i = 0; i < 3; ++i) {
        assert(outLeft[i] == left[i] * 0.25f);
        assert(outRight[i] == right[i] * 0.25f);
    }
    /* Exactly in-place interleaved and planar processing retain L/R mapping. */
    VDProcess(state, &middle, &middle);
    VDProcess(state, (AudioBufferList *)&out, (AudioBufferList *)&out);
    for (unsigned i = 0; i < 3; ++i) {
        assert(packed[2 * i] == left[i] * 0.25f);
        assert(packed[2 * i + 1] == right[i] * 0.25f);
        assert(outLeft[i] == left[i] * 0.125f);
        assert(outRight[i] == right[i] * 0.125f);
    }
    VDDestroy(state);
}

static void testRampContinuityAndMute(void) {
    float input[1200], output[1200];
    for (unsigned i = 0; i < 1200; ++i) input[i] = 1.0f;
    VDState *state = VDCreate(48000, 1.0f);
    VDSetGain(state, 0.0f);
    const unsigned chunks[] = {137, 211, 132, 120};
    unsigned offset = 0;
    for (unsigned c = 0; c < 4; ++c) {
        AudioBufferList in = interleaved(input + 2 * offset, chunks[c]);
        AudioBufferList out = interleaved(output + 2 * offset, chunks[c]);
        VDProcess(state, &in, &out);
        offset += chunks[c];
    }
    for (unsigned i = 0; i < 600; ++i) {
        double expected = i < 480 ? 1.0 - (i + 1.0) / 480 : 0.0;
        closeEnough(output[2 * i], expected, 0.00000006);
        assert(output[2 * i] == output[2 * i + 1]);
        if (i >= 479) assert(output[2 * i] == 0.0f);
        if (i) assert(output[2 * i] <= output[2 * (i - 1)]);
    }
    VDStats stats = VDGetStats(state);
    assert(stats.callbacks == 4 && stats.frames == 600);
    assert(stats.currentGain == 0.0f && stats.outputPeak == 0.0f);
    VDSetGain(state, 1.0f);
    AudioBufferList in = interleaved(input, 137);
    AudioBufferList out = interleaved(output, 137);
    VDProcess(state, &in, &out);
    const double before = output[2 * 136];
    VDSetGain(state, 0.2f); /* Retarget from the current level without a jump. */
    in = interleaved(input, 1);
    out = interleaved(output, 1);
    VDProcess(state, &in, &out);
    closeEnough(output[0], before + (0.2 - before) / 480, 0.00000006);
    VDDestroy(state);
}

static void testInvalidInputSilencesWithoutOverrun(void) {
    float source[] = {0.5f, -0.5f, 0.25f, -0.25f};
    float guarded[] = {1234, 1, 1, 1, 1, 5678};
    AudioBufferList in = interleaved(source, 2);
    AudioBufferList out = interleaved(guarded + 1, 2);
    VDState *state = VDCreate(48000, 0.5f);
    VDProcess(state, NULL, &out);
    for (unsigned i = 1; i < 5; ++i) assert(guarded[i] == 0.0f);
    assert(guarded[0] == 1234 && guarded[5] == 5678);
    in.mBuffers[0].mDataByteSize = 3 * sizeof(float); /* Incomplete stereo frame. */
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).formatErrors == 2);
    in = interleaved(source, 1); /* Whole frames, wrong number. */
    VDProcess(state, &in, &out);
    in = interleaved(NULL, 2);
    VDProcess(state, &in, &out);
    float left[2] = {1, 1}, right[2] = {1, 1};
    StereoList malformed = planar(left, right, 2);
    malformed.mBuffers[1].mDataByteSize = sizeof(float);
    VDProcess(state, (AudioBufferList *)&malformed, &out);
    out.mBuffers[0].mNumberChannels = 3;
    VDProcess(state, &in, &out);
    VDProcess(state, &in, NULL);
    VDStats stats = VDGetStats(state);
    assert(stats.formatErrors == 7 && stats.callbacks == 7 && stats.frames == 10);
    assert(guarded[0] == 1234 && guarded[5] == 5678);
    VDDestroy(state);
}

static void testNonfiniteAndClampedGain(void) {
    float input[] = {NAN, INFINITY, -INFINITY, FLT_MAX, 0.5f, -0.5f};
    float output[6];
    AudioBufferList in = interleaved(input, 3);
    AudioBufferList out = interleaved(output, 3);
    VDState *state = VDCreate(100, 9.0f); /* One-frame ramp. */
    VDProcess(state, &in, &out);
    assert(output[0] == 0 && output[1] == 0 && output[2] == 0);
    assert(output[3] == FLT_MAX && output[4] == 0.5f && output[5] == -0.5f);
    VDSetGain(state, NAN);
    VDProcess(state, &in, &out);
    for (unsigned i = 0; i < 6; ++i) assert(output[i] == 0);
    VDSetGain(state, 2.0f);
    VDProcess(state, &in, &out);
    assert(output[4] == 0.5f);
    VDSetGain(state, -1.0f);
    VDProcess(state, &in, &out);
    assert(output[4] == 0.0f);
    VDDestroy(state);
    assert(!VDCreate(NAN, 1));
    assert(!VDCreate(0, 1));
    state = VDCreate(48000, INFINITY);
    assert(state && VDGetStats(state).currentGain == 0);
    VDDestroy(state);
}

static void testUnalignedAndEmptyBuffers(void) {
    unsigned char source[18], destination[18];
    const float samples[4] = {0.25f, -0.5f, 0.75f, -1.0f};
    memcpy(source + 1, samples, sizeof(samples));
    memset(destination, 0x7A, sizeof(destination));
    AudioBufferList in = interleaved((float *)(void *)(source + 1), 2);
    AudioBufferList out = interleaved((float *)(void *)(destination + 1), 2);
    VDState *state = VDCreate(44100, 0.5f);
    VDProcess(state, &in, &out);
    for (unsigned i = 0; i < 4; ++i) {
        float actual;
        memcpy(&actual, destination + 1 + sizeof(float) * i, sizeof(float));
        assert(actual == samples[i] * 0.5f);
    }
    assert(destination[0] == 0x7A && destination[17] == 0x7A);
    in = interleaved(NULL, 0);
    out = interleaved(NULL, 0);
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).formatErrors == 0);
    VDDestroy(state);
}

static void testFeedbackWindowAndCoalescing(void) {
    enum { frames = 4800, toneFrames = 3840 };
    float input[2 * frames] = {0}, output[2 * frames];
    AudioBufferList in = interleaved(input, frames);
    AudioBufferList out = interleaved(output, frames);
    VDState *state = VDCreate(48000, 1.0f);
    assert(state);
    VDTriggerFeedback(state);
    VDTriggerFeedback(state); /* Requests before processing coalesce. */
    VDTriggerFeedback(state);
    VDProcess(state, &in, &out);
    float peak = 0.0f;
    assert(output[0] == 0.0f && output[1] == 0.0f);
    for (unsigned frame = 0; frame < frames; ++frame) {
        assert(isfinite(output[2 * frame]));
        assert(output[2 * frame] == output[2 * frame + 1]);
        peak = fmaxf(peak, fabsf(output[2 * frame]));
        if (frame >= toneFrames - 1) assert(output[2 * frame] == 0.0f);
    }
    assert(peak > 0.01f && peak <= 0.05f);
    VDStats stats = VDGetStats(state);
    assert(stats.feedbackCount == 1 && stats.feedbackFramesRemaining == 0);
    assert(stats.inputPeak == 0.0f && stats.outputPeak == peak);
    VDProcess(state, &in, &out);
    for (unsigned sample = 0; sample < 2 * frames; ++sample) assert(output[sample] == 0.0f);
    assert(VDGetStats(state).feedbackCount == 1);
    VDTriggerFeedback(state);
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackCount == 2);
    VDDestroy(state);
}

static void testFeedbackGainAndLayouts(void) {
    enum { frames = 4000 };
    float input[2 * frames] = {0}, full[2 * frames], quiet[2 * frames];
    float left[frames] = {0}, right[frames] = {0};
    AudioBufferList in = interleaved(input, frames);
    AudioBufferList outFull = interleaved(full, frames);
    AudioBufferList outQuiet = interleaved(quiet, frames);
    StereoList outPlanar = planar(left, right, frames);
    VDState *loudState = VDCreate(48000, 1.0f);
    VDState *quietState = VDCreate(48000, 0.25f);
    VDState *planarState = VDCreate(48000, 1.0f);
    VDTriggerFeedback(loudState);
    VDTriggerFeedback(quietState);
    VDTriggerFeedback(planarState);
    VDProcess(loudState, &in, &outFull);
    VDProcess(quietState, &in, &outQuiet);
    VDProcess(planarState, &in, (AudioBufferList *)&outPlanar);
    for (unsigned frame = 0; frame < frames; ++frame) {
        assert(quiet[2 * frame] == full[2 * frame] * 0.25f);
        assert(quiet[2 * frame + 1] == full[2 * frame + 1] * 0.25f);
        assert(left[frame] == full[2 * frame] && right[frame] == full[2 * frame + 1]);
    }
    VDDestroy(loudState);
    VDDestroy(quietState);
    VDDestroy(planarState);
}

static void testFeedbackMuteAndInvalidInput(void) {
    enum { frames = 256 };
    float input[2 * frames] = {0}, output[2 * frames];
    AudioBufferList in = interleaved(input, frames);
    AudioBufferList out = interleaved(output, frames);
    VDState *state = VDCreate(48000, 0.0f);
    VDTriggerFeedback(state);
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackCount == 0);
    for (unsigned sample = 0; sample < 2 * frames; ++sample) assert(output[sample] == 0.0f);
    VDSetGain(state, 1.0f);
    VDTriggerFeedback(state);
    VDProcess(state, NULL, &out); /* Feedback also plays when the tap is idle. */
    assert(VDGetStats(state).feedbackCount == 1);
    assert(VDGetStats(state).outputPeak > 0.0f);
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackCount == 1);
    assert(VDGetStats(state).feedbackFramesRemaining == 3840 - 2 * frames);
    VDTriggerFeedback(state); /* An active and a queued tone both cancel on mute. */
    VDSetGain(state, 0.0f);
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackFramesRemaining == 0);
    for (unsigned sample = 0; sample < 2 * frames; ++sample) assert(output[sample] == 0.0f);
    VDSetGain(state, 1.0f);
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackCount == 1);
    for (unsigned sample = 0; sample < 2 * frames; ++sample) assert(output[sample] == 0.0f);
    VDDestroy(state);
    VDTriggerFeedback(NULL);
}

static void testFeedbackWithMissingAndMalformedInput(void) {
    enum { frames = 4000 };
    float silence[2 * frames] = {0}, reference[2 * frames];
    float guarded[2 * frames + 2];
    AudioBufferList validInput = interleaved(silence, frames);
    AudioBufferList referenceOutput = interleaved(reference, frames);
    VDState *referenceState = VDCreate(48000, 0.25f);
    VDTriggerFeedback(referenceState);
    VDProcess(referenceState, &validInput, &referenceOutput);
    assert(VDGetStats(referenceState).outputPeak > 0.0f);
    VDDestroy(referenceState);

    AudioBufferList empty = interleaved(NULL, 0);
    AudioBufferList missingData = interleaved(NULL, frames);
    AudioBufferList incompleteFrame = interleaved(silence, frames);
    incompleteFrame.mBuffers[0].mDataByteSize -= sizeof(float);
    AudioBufferList mismatchedFrames = interleaved(silence, frames - 1);
    AudioBufferList wrongChannels = interleaved(silence, frames);
    wrongChannels.mBuffers[0].mNumberChannels = 1;
    const AudioBufferList *invalidInputs[] = {
        NULL, &empty, &missingData, &incompleteFrame, &mismatchedFrames, &wrongChannels
    };
    for (unsigned variant = 0; variant < sizeof(invalidInputs) / sizeof(invalidInputs[0]); ++variant) {
        for (unsigned sample = 0; sample < 2 * frames + 2; ++sample) guarded[sample] = 1234.0f;
        AudioBufferList out = interleaved(guarded + 1, frames);
        VDState *state = VDCreate(48000, 0.25f);
        VDTriggerFeedback(state);
        VDProcess(state, invalidInputs[variant], &out);
        VDStats stats = VDGetStats(state);
        assert(stats.feedbackCount == 1 && stats.feedbackFramesRemaining == 0);
        assert(stats.formatErrors == 1 && stats.inputPeak == 0.0f);
        for (unsigned sample = 0; sample < 2 * frames; ++sample)
            assert(guarded[sample + 1] == reference[sample]);
        assert(guarded[0] == 1234.0f && guarded[2 * frames + 1] == 1234.0f);
        VDProcess(state, NULL, &out);
        for (unsigned sample = 0; sample < 2 * frames; ++sample)
            assert(guarded[sample + 1] == 0.0f);
        assert(VDGetStats(state).feedbackCount == 1);
        VDDestroy(state);

        state = VDCreate(48000, 0.0f);
        VDTriggerFeedback(state);
        VDProcess(state, invalidInputs[variant], &out);
        assert(VDGetStats(state).feedbackCount == 0);
        assert(VDGetStats(state).formatErrors == 1);
        for (unsigned sample = 0; sample < 2 * frames; ++sample)
            assert(guarded[sample + 1] == 0.0f);
        VDDestroy(state);
    }
}

static void testFeedbackRetriggerAndBounds(void) {
    enum { frames = 256, callbacksPerTone = 15 };
    float input[2 * frames], output[2 * frames];
    for (unsigned frame = 0; frame < frames; ++frame) {
        input[2 * frame] = frame & 1 ? FLT_MAX : NAN;
        input[2 * frame + 1] = frame & 1 ? -FLT_MAX : INFINITY;
    }
    AudioBufferList in = interleaved(input, frames);
    AudioBufferList out = interleaved(output, frames);
    VDState *state = VDCreate(48000, 1.0f);
    VDTriggerFeedback(state);
    for (unsigned callback = 0; callback < callbacksPerTone; ++callback) {
        VDProcess(state, &in, &out);
        assert(VDGetStats(state).feedbackCount == 1);
        assert(VDGetStats(state).feedbackFramesRemaining ==
               3840 - (callback + 1) * frames);
        for (unsigned sample = 0; sample < 2 * frames; ++sample) {
            assert(isfinite(output[sample]) && fabsf(output[sample]) <= 1.0f);
        }
        VDTriggerFeedback(state); /* Coalesces to one tone after the first. */
    }
    memset(input, 0, sizeof(input));
    VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackCount == 2);
    assert(output[0] == 0.0f && output[1] == 0.0f);
    for (unsigned callback = 1; callback < callbacksPerTone + 1; ++callback)
        VDProcess(state, &in, &out);
    assert(VDGetStats(state).feedbackCount == 2);
    assert(VDGetStats(state).feedbackFramesRemaining == 0);
    for (unsigned sample = 0; sample < 2 * frames; ++sample) assert(output[sample] == 0.0f);
    VDDestroy(state);
}

int main(void) {
    testSineAttenuation();
    testStereoLayouts();
    testRampContinuityAndMute();
    testInvalidInputSilencesWithoutOverrun();
    testNonfiniteAndClampedGain();
    testUnalignedAndEmptyBuffers();
    testFeedbackWindowAndCoalescing();
    testFeedbackGainAndLayouts();
    testFeedbackMuteAndInvalidInput();
    testFeedbackWithMissingAndMalformedInput();
    testFeedbackRetriggerAndBounds();
    puts("VolumeDSP: 11 suites passed (attenuation, layouts, ramps/mute, invalid input, nonfinite/gain limits, alignment, feedback window/coalescing, feedback gain/layouts, feedback mute/invalid input, feedback missing/malformed input, feedback retrigger/bounds).");
    return 0;
}
