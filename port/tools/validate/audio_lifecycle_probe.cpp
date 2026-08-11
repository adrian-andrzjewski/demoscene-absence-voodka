// audio_lifecycle_probe.cpp - assembly-owned dedicated-player lifecycle ABI.

#include <windows.h>

#include "audio_controller_abi.h"
#include "audio_ring_abi.h"
#include "audio_service_abi.h"
#include "audio_workers_abi.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

extern "C" unsigned char asm_audio_runtime_state[0x2000];

namespace vk {

int audioAsmInit(const char* path, int sampleRate);
void audioAsmShutdown();
int audioAsmPlay();
int audioAsmStop();

} // namespace vk

namespace {
uint8_t g_module[8]{};
uint32_t g_tickStarts[2]{};
uint32_t g_modpos[1]{};
uint32_t g_tickTimes[1]{};
AudioTickState g_states[1]{};
int16_t g_samples[8]{};
AudioRingMarker g_markers[8]{};
AudioTickState g_producerStates[1]{};
int16_t g_producerPcm[8]{};
AudioMixerHistory g_history{};

uint32_t g_storageCalls = 0;
uint32_t g_ringInitCalls = 0;
uint32_t g_ringCloseCalls = 0;
uint32_t g_startCalls = 0;
uint32_t g_stopCalls = 0;
uint32_t g_logCalls = 0;
bool g_lifecycleShapeOk = true;
bool g_stopShapeOk = true;
}

extern "C" uint32_t asm_audio_service_storage_init(
    const char* path, AudioAssemblyStorage* storage) {
    ++g_storageCalls;
    if (!path || !storage) return 9;
    *storage = {};
    storage->module = g_module;
    storage->moduleSize = sizeof(g_module);
    storage->stateFrames = 1;
    storage->totalFrames = 1;
    storage->maxTickFrames = 1;
    storage->orderCount = 7;
    storage->rowsPerLoop = 64;
    storage->scratchFrames = 1;
    storage->tickStarts = g_tickStarts;
    storage->modposByTick = g_modpos;
    storage->tickTimesMs = g_tickTimes;
    storage->states = g_states;
    storage->ringSamples = g_samples;
    storage->ringMarkers = g_markers;
    storage->producerStates = g_producerStates;
    storage->producerPcm = g_producerPcm;
    storage->producerHistory = &g_history;
    return 0;
}

extern "C" uint32_t asm_audio_ring_init(
    AudioPcmRing* ring, int16_t* samples, uint32_t capacity,
    AudioRingMarker* markers, uint32_t markerCapacity) {
    ++g_ringInitCalls;
    if (!ring || !samples || !markers || capacity != 16384 ||
        markerCapacity != 16384) return 1;
    *ring = {};
    ring->samples = samples;
    ring->capacityFrames = capacity;
    ring->mask = capacity - 1;
    ring->markers = markers;
    ring->markerCapacity = markerCapacity;
    ring->markerMask = markerCapacity - 1;
    return 0;
}

extern "C" void asm_audio_ring_close(AudioPcmRing* ring) {
    ++g_ringCloseCalls;
    if (ring) ring->closed = 1;
}

extern "C" uint32_t asm_audio_start_workers(
    const AudioWorkerLifecycleArgs* args) {
    ++g_startCalls;
    auto* runtime = reinterpret_cast<AudioControllerRuntimeView*>(
        asm_audio_runtime_state);
    g_lifecycleShapeOk = args &&
        args->producerHandle == &runtime->producerHandle &&
        args->producerEntry != 0 &&
        args->producerArgs == &runtime->producerArgs &&
        args->ring == &runtime->ring &&
        args->producerFailed == reinterpret_cast<volatile uint32_t*>(
            &runtime->producerFailed) &&
        args->workerHandle == &runtime->workerControllerHandle &&
        args->workerEntry != 0 &&
        args->workerArgs == &runtime->workerServiceArgs &&
        args->control == &runtime->control &&
        args->producerStop == reinterpret_cast<volatile uint32_t*>(
            &runtime->producerStop);
    if (!g_lifecycleShapeOk) return 2;
    *args->producerHandle = reinterpret_cast<void*>(0x1111);
    *args->workerHandle = reinterpret_cast<void*>(0x2222);
    return 0;
}

extern "C" uint32_t asm_audio_stop_workers(
    const AudioWorkerLifecycleArgs* args) {
    ++g_stopCalls;
    auto* runtime = reinterpret_cast<AudioControllerRuntimeView*>(
        asm_audio_runtime_state);
    g_stopShapeOk = args &&
        args->producerHandle == &runtime->producerHandle &&
        args->producerEntry == 0 && args->producerArgs == nullptr &&
        args->ring == nullptr &&
        args->workerHandle == &runtime->workerControllerHandle &&
        args->workerEntry == 0 && args->workerArgs == nullptr &&
        args->control == &runtime->control &&
        args->producerStop == reinterpret_cast<volatile uint32_t*>(
            &runtime->producerStop);
    if (args && args->producerHandle) *args->producerHandle = nullptr;
    if (args && args->workerHandle) *args->workerHandle = nullptr;
    return g_stopShapeOk ? 1u : 0u;
}

extern "C" uint32_t __stdcall asm_audio_producer_thread(void*) {
    return 0;
}

extern "C" uint32_t __stdcall asm_audio_ring_thread_entry(void*) {
    return 0;
}

namespace vk {

void logPrint(const char*, ...) {
    ++g_logCalls;
}

} // namespace vk

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "audio lifecycle: %s\n", message);
    return condition;
}

int main() {
    auto* runtime = reinterpret_cast<AudioControllerRuntimeView*>(
        asm_audio_runtime_state);
    *runtime = AudioControllerRuntimeView{};
    SetEnvironmentVariableA("VOODKA_ASM_AUDIO_FAIL_DEVICE", nullptr);

    bool ok = true;
    ok &= check(vk::audioAsmInit(nullptr, 44100) == 0 &&
                    runtime->initialized == 0 && g_storageCalls == 0,
                "null module path rejection");

    SetEnvironmentVariableA("VOODKA_ASM_AUDIO_FAIL_DEVICE", "1");
    ok &= check(vk::audioAsmInit("ignored.mod", 44100) == 0 &&
                    g_storageCalls == 0,
                "forced device failure before storage");
    SetEnvironmentVariableA("VOODKA_ASM_AUDIO_FAIL_DEVICE", nullptr);

    g_storageCalls = g_ringInitCalls = g_ringCloseCalls = 0;
    g_startCalls = g_stopCalls = g_logCalls = 0;
    g_lifecycleShapeOk = g_stopShapeOk = true;
    ok &= check(vk::audioAsmInit("synthetic.mod", 44100) == 1 &&
                    runtime->initialized == 1 && runtime->playing == 1 &&
                    g_storageCalls == 1 && g_ringInitCalls == 1 &&
                    g_startCalls == 1 && g_lifecycleShapeOk,
                "successful record construction and startup");
    ok &= check(vk::audioAsmStop() == 1 && runtime->playing == 0,
                "assembly stop publication");
    ok &= check(vk::audioAsmPlay() == 1 && runtime->playing == 1,
                "assembly play publication");

    vk::audioAsmShutdown();
    ok &= check(runtime->initialized == 0 && runtime->playing == 0 &&
                    g_stopCalls == 1 && g_stopShapeOk &&
                    g_ringCloseCalls >= 1,
                "shutdown ordering and runtime clear");

    return ok ? 0 : 1;
}
