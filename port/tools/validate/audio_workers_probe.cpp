// audio_workers_probe.cpp - real Win32 startup/rollback/teardown witness.

#include <windows.h>

#include "audio_ring_abi.h"
#include "audio_thread_abi.h"
#include "audio_workers_abi.h"

#include <cstdint>
#include <cstdio>

extern "C" DWORD asm_audio_wait_worker(HANDLE handle, DWORD timeout);

struct ProbeState {
    AudioPcmRing ring{};
    AudioLiveControl control{};
    volatile uint32_t producerFailed = 0;
    volatile uint32_t producerStop = 0;
};

static DWORD WINAPI probeProducer(LPVOID raw) {
    auto* state = static_cast<ProbeState*>(raw);
    state->ring.writeFrame = 8192;
    return 0;
}

static DWORD WINAPI probeWorker(LPVOID raw) {
    auto* state = static_cast<ProbeState*>(raw);
    while (state->control.requestedState != 2) Sleep(1);
    return 0;
}

static DWORD WINAPI earlyExitWorker(LPVOID) {
    return 0;
}

static AudioWorkerLifecycleArgs makeArgs(
    ProbeState& state, HANDLE& producerHandle, HANDLE& workerHandle,
    uint64_t producerEntry, uint64_t workerEntry) {
    return {
        reinterpret_cast<void**>(&producerHandle),
        producerEntry,
        &state,
        &state.ring,
        &state.producerFailed,
        reinterpret_cast<void**>(&workerHandle),
        workerEntry,
        &state,
        &state.control,
        &state.producerStop,
    };
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "audio workers: %s\n", message);
    return condition;
}

int main() {
    bool ok = true;

    ProbeState state;
    HANDLE producerHandle = nullptr;
    HANDLE workerHandle = nullptr;
    auto lifecycle = makeArgs(
        state, producerHandle, workerHandle,
        reinterpret_cast<uint64_t>(probeProducer),
        reinterpret_cast<uint64_t>(probeWorker));
    ok &= check(asm_audio_start_workers(&lifecycle) == 0,
                "normal startup status");
    ok &= check(producerHandle != nullptr && workerHandle != nullptr,
                "normal startup handles");
    ok &= check(asm_audio_wait_worker(workerHandle, 0) == WAIT_TIMEOUT,
                "worker remains alive during normal startup");
    ok &= check(asm_audio_stop_workers(&lifecycle) == 1,
                "normal stop status");
    ok &= check(producerHandle == nullptr && workerHandle == nullptr,
                "normal stop clears both slots");
    ok &= check(state.producerStop == 1 && state.control.requestedState == 2 &&
                    state.control.requestSequence == 1,
                "normal stop publishes producer/worker shutdown");

    ProbeState earlyState;
    HANDLE earlyProducer = nullptr;
    HANDLE earlyWorker = nullptr;
    auto earlyLifecycle = makeArgs(
        earlyState, earlyProducer, earlyWorker,
        reinterpret_cast<uint64_t>(probeProducer),
        reinterpret_cast<uint64_t>(earlyExitWorker));
    const uint32_t earlyStatus = asm_audio_start_workers(&earlyLifecycle);
    if (earlyStatus != 3)
        std::fprintf(stderr, "audio workers: early worker exit status=%u\n",
                     earlyStatus);
    ok &= check(earlyStatus == 3, "early worker exit status");
    ok &= check(earlyProducer != nullptr && earlyWorker != nullptr,
                "early-exit handles remain available for rollback");
    ok &= check(asm_audio_stop_workers(&earlyLifecycle) == 1 &&
                    earlyProducer == nullptr && earlyWorker == nullptr,
                "early-exit rollback joins and closes handles");

    ProbeState controllerFailureState;
    HANDLE controllerFailureProducer = nullptr;
    HANDLE controllerFailureWorker = nullptr;
    auto controllerFailureLifecycle = makeArgs(
        controllerFailureState, controllerFailureProducer,
        controllerFailureWorker,
        reinterpret_cast<uint64_t>(probeProducer),
        reinterpret_cast<uint64_t>(probeWorker));
    controllerFailureLifecycle.workerHandle = nullptr;
    ok &= check(asm_audio_start_workers(&controllerFailureLifecycle) == 2,
                "worker creation failure status");
    ok &= check(controllerFailureProducer != nullptr,
                "worker creation failure preserves producer for rollback");
    ok &= check(asm_audio_stop_workers(&controllerFailureLifecycle) == 1 &&
                    controllerFailureProducer == nullptr,
                "worker creation failure rollback joins producer");

    ProbeState failedState;
    HANDLE failedProducer = nullptr;
    HANDLE failedWorker = nullptr;
    auto failedLifecycle = makeArgs(
        failedState, failedProducer, failedWorker, 0,
        reinterpret_cast<uint64_t>(probeWorker));
    failedLifecycle.producerHandle = nullptr;
    ok &= check(asm_audio_start_workers(&failedLifecycle) == 1,
                "producer creation failure status");
    ok &= check(failedProducer == nullptr && failedWorker == nullptr,
                "producer creation failure leaves no handles");
    ok &= check(asm_audio_stop_workers(&failedLifecycle) == 1 &&
                    failedState.producerStop == 1,
                "producer failure rollback is idempotent");

    return ok ? 0 : 1;
}
