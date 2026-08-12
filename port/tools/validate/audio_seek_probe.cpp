// audio_seek_probe.cpp - real two-worker seek transaction witness.

#include <windows.h>

#include "audio_seek_abi.h"

#include <cstdint>
#include <cstdio>

struct ProbeState {
    AudioLiveControl control{};
    AudioPcmRing ring{};
    volatile uint32_t producerFailed = 0;
};

static DWORD WINAPI seekWorker(void* raw) {
    auto* state = static_cast<ProbeState*>(raw);
    while (state->control.requestSequence == 0) Sleep(1);

    // Publish the consumed boundary before acknowledging pause.
    state->control.workerConsumedFrames = 4321;
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&state->control.acknowledgedState), 1);
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&state->control.acknowledgedSequence),
        static_cast<LONG>(state->control.requestSequence));

    while (state->control.requestSequence < 2) Sleep(1);
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&state->control.acknowledgedState), 0);
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&state->control.acknowledgedSequence),
        static_cast<LONG>(state->control.requestSequence));
    return 0;
}

static DWORD WINAPI seekProducer(void* raw) {
    auto* state = static_cast<ProbeState*>(raw);
    while (state->control.seekSequence == 0) Sleep(1);

    const uint32_t sequence = state->control.seekSequence;
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&state->control.producerSeekAckSequence),
        static_cast<LONG>(sequence));
    while (state->control.seekCommitSequence != sequence) Sleep(1);

    state->ring.writeFrame = state->ring.readFrame + 8192;
    return 0;
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "audio seek: %s\n", message);
    return condition;
}

int main() {
    ProbeState state;
    state.ring.readFrame = 100;
    state.ring.writeFrame = 12000;
    state.ring.markerRead = 3;
    state.ring.markerWrite = 7;

    HANDLE worker = CreateThread(nullptr, 0, seekWorker, &state, 0, nullptr);
    HANDLE producer = CreateThread(nullptr, 0, seekProducer, &state, 0, nullptr);
    if (!worker || !producer) {
        if (worker) {
            WaitForSingleObject(worker, INFINITE);
            CloseHandle(worker);
        }
        if (producer) {
            WaitForSingleObject(producer, INFINITE);
            CloseHandle(producer);
        }
        std::fprintf(stderr, "audio seek: helper thread creation failed\n");
        return 1;
    }

    uint32_t lastState = 0;
    uint32_t lastSequence = 0;
    uint32_t baseConsumed = 0;
    uint32_t seekSequence = 0;
    const AudioSeekTransactionArgs args{
        &state.control,
        &state.ring,
        &state.producerFailed,
        37,
        0,
        &lastState,
        &lastSequence,
        &baseConsumed,
        &seekSequence,
    };

    const uint32_t result = asm_audio_seek_transaction(&args);
    const DWORD workerWait = WaitForSingleObject(worker, INFINITE);
    const DWORD producerWait = WaitForSingleObject(producer, INFINITE);
    CloseHandle(worker);
    CloseHandle(producer);

    const bool ok =
        check(result == 1, "transaction status") &&
        check(workerWait == WAIT_OBJECT_0 && producerWait == WAIT_OBJECT_0,
              "helper thread completion") &&
        check(baseConsumed == 4321 && seekSequence == 1,
              "transaction outputs") &&
        check(state.control.requestedState == 0 &&
                  state.control.requestSequence == 2 &&
                  state.control.acknowledgedState == 0 &&
                  state.control.acknowledgedSequence == 2 &&
                  lastState == 0 && lastSequence == 2,
              "pause/resume publication") &&
        check(state.control.requestedSeekTick == 37 &&
                  state.control.seekSequence == 1 &&
                  state.control.producerSeekAckSequence == 1 &&
                  state.control.seekCommitSequence == 1 &&
                  state.control.seekRingBaseFrame == 4321,
              "seek sequence publication") &&
        check(state.ring.readFrame == 12000 &&
                  state.ring.writeFrame == 20192 &&
                  state.ring.markerRead == 7 && state.ring.markerWrite == 7,
              "ring flush and refill") &&
        check(state.producerFailed == 0, "producer failure flag");

    if (!ok) {
        std::fprintf(stderr,
                     "audio seek: result=%u base=%u seq=%u ring=%u/%u "
                     "markers=%u/%u state=%u/%u ack=%u/%u\n",
                     result, baseConsumed, seekSequence, state.ring.readFrame,
                     state.ring.writeFrame, state.ring.markerRead,
                     state.ring.markerWrite, state.control.requestedState,
                     state.control.requestSequence,
                     state.control.acknowledgedState,
                     state.control.acknowledgedSequence);
    }
    return ok ? 0 : 1;
}
