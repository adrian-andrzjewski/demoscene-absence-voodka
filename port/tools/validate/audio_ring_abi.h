#pragma once

#include <cstddef>
#include <cstdint>

// The ring is single-producer/single-consumer. The producer owns writeFrame
// and markerWrite; the consumer owns readFrame and markerRead. The assembly
// implementation publishes payload bytes before its corresponding index and
// uses mfence at both ownership boundaries.
#pragma pack(push, 1)
struct AudioRingMarker {
    uint32_t frame;
    uint32_t modpos;
};

struct AudioPcmRing {
    int16_t* samples;
    uint32_t capacityFrames;
    uint32_t mask;
    volatile uint32_t readFrame;
    volatile uint32_t writeFrame;
    volatile uint32_t closed;
    volatile uint32_t overrunEvents;
    volatile uint32_t underrunEvents;
    AudioRingMarker* markers;
    uint32_t markerCapacity;
    uint32_t markerMask;
    volatile uint32_t markerRead;
    volatile uint32_t markerWrite;
    volatile uint32_t markerOverruns;
};
#pragma pack(pop)

static_assert(offsetof(AudioPcmRing, samples) == 0);
static_assert(offsetof(AudioPcmRing, capacityFrames) == 8);
static_assert(offsetof(AudioPcmRing, readFrame) == 16);
static_assert(offsetof(AudioPcmRing, writeFrame) == 20);
static_assert(offsetof(AudioPcmRing, closed) == 24);
static_assert(offsetof(AudioPcmRing, markers) == 36);
static_assert(offsetof(AudioPcmRing, markerRead) == 52);
static_assert(offsetof(AudioPcmRing, markerWrite) == 56);
static_assert(sizeof(AudioPcmRing) == 64);
static_assert(sizeof(AudioRingMarker) == 8);

extern "C" uint32_t asm_audio_ring_init(AudioPcmRing* ring,
                                          int16_t* samples,
                                          uint32_t capacityFrames,
                                          AudioRingMarker* markers,
                                          uint32_t markerCapacity);

extern "C" uint32_t asm_audio_ring_push(AudioPcmRing* ring,
                                          const int16_t* frames,
                                          uint32_t frameCount);

extern "C" uint32_t asm_audio_ring_pop(AudioPcmRing* ring,
                                         int16_t* frames,
                                         uint32_t frameCapacity);

extern "C" uint32_t asm_audio_ring_push_marker(AudioPcmRing* ring,
                                                 uint32_t frame,
                                                 uint32_t modpos);

extern "C" uint32_t asm_audio_ring_pop_marker(AudioPcmRing* ring,
                                                uint32_t consumedFrame,
                                                AudioRingMarker* marker);

extern "C" void asm_audio_ring_close(AudioPcmRing* ring);
