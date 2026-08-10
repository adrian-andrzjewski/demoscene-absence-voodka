#pragma once

#include "audio_ring_abi.h"

#include <cstddef>
#include <cstdint>

#pragma pack(push, 1)
struct AudioThreadAsmProbeReport {
    uint32_t threadCreated;
    uint32_t threadPriority;
    uint32_t threadWait;
    uint32_t comHr;
    uint32_t enumeratorHr;
    uint32_t endpointHr;
    uint32_t activateHr;
    uint32_t formatHr;
    uint32_t initializeHr;
    uint32_t bufferSize;
    uint32_t eventCreated;
    uint32_t setEventHr;
    uint32_t serviceHr;
    uint32_t startHr;
    uint32_t firstWait;
    uint32_t paddingHr;
    uint32_t paddingFrames;
    uint32_t getBufferHr;
    uint32_t releaseHr;
    uint32_t stopHr;
    uint32_t resetHr;
    uint32_t eventWakeups;
    uint32_t frames;
    uint32_t timeouts;
    uint32_t workerExit;
    uint32_t durationMs;
};
#pragma pack(pop)

struct AudioPcmThreadArgs {
    const int16_t* pcm;
    uint32_t pcmFrames;
    const uint32_t* tickStarts;
    const uint32_t* modposByTick;
    uint32_t tickCount;
    uint32_t durationMs;
};

struct AudioPcmThreadReport {
    AudioThreadAsmProbeReport common;
    uint32_t publishedTick;
    uint32_t publishedModPos;
    uint32_t publishedPcmFrame;
    uint32_t snapshotUpdates;
    uint32_t sourceLoops;
};

struct AudioRingThreadArgs {
    AudioPcmRing* ring;
    uint32_t durationMs;
};

#pragma pack(push, 1)
struct AudioRingThreadReport {
    AudioThreadAsmProbeReport common;
    uint32_t publishedModPos;
    uint32_t publishedPcmFrame;
    uint32_t snapshotUpdates;
    uint32_t consumedFrames;
    uint32_t underrunEvents;
    uint32_t overrunEvents;
    uint32_t markerOverruns;
    uint64_t pcmFnv;
};
#pragma pack(pop)

static_assert(sizeof(AudioThreadAsmProbeReport) == 104);
static_assert(offsetof(AudioThreadAsmProbeReport, firstWait) == 56);
static_assert(offsetof(AudioThreadAsmProbeReport, paddingFrames) == 64);
static_assert(offsetof(AudioThreadAsmProbeReport, eventWakeups) == 84);
static_assert(offsetof(AudioThreadAsmProbeReport, durationMs) == 100);

static_assert(sizeof(AudioPcmThreadArgs) == 40);
static_assert(offsetof(AudioPcmThreadArgs, pcmFrames) == 8);
static_assert(offsetof(AudioPcmThreadArgs, tickStarts) == 16);
static_assert(offsetof(AudioPcmThreadArgs, modposByTick) == 24);
static_assert(offsetof(AudioPcmThreadArgs, tickCount) == 32);
static_assert(offsetof(AudioPcmThreadArgs, durationMs) == 36);

static_assert(sizeof(AudioPcmThreadReport) == 124);
static_assert(offsetof(AudioPcmThreadReport, publishedTick) == 104);
static_assert(offsetof(AudioPcmThreadReport, publishedModPos) == 108);
static_assert(offsetof(AudioPcmThreadReport, publishedPcmFrame) == 112);
static_assert(offsetof(AudioPcmThreadReport, snapshotUpdates) == 116);
static_assert(offsetof(AudioPcmThreadReport, sourceLoops) == 120);

static_assert(sizeof(AudioRingThreadArgs) == 16);
static_assert(offsetof(AudioRingThreadArgs, durationMs) == 8);

static_assert(sizeof(AudioRingThreadReport) == 140);
static_assert(offsetof(AudioRingThreadReport, publishedModPos) == 104);
static_assert(offsetof(AudioRingThreadReport, publishedPcmFrame) == 108);
static_assert(offsetof(AudioRingThreadReport, snapshotUpdates) == 112);
static_assert(offsetof(AudioRingThreadReport, consumedFrames) == 116);
static_assert(offsetof(AudioRingThreadReport, underrunEvents) == 120);
static_assert(offsetof(AudioRingThreadReport, overrunEvents) == 124);
static_assert(offsetof(AudioRingThreadReport, markerOverruns) == 128);
static_assert(offsetof(AudioRingThreadReport, pcmFnv) == 132);

extern "C" uint32_t asm_audio_thread_probe(
    uint32_t durationMs, AudioThreadAsmProbeReport* report);

extern "C" uint32_t asm_audio_pcm_thread_probe(
    const AudioPcmThreadArgs* args, AudioPcmThreadReport* report);

extern "C" uint32_t asm_audio_ring_thread_probe(
    const AudioRingThreadArgs* args, AudioRingThreadReport* report);
