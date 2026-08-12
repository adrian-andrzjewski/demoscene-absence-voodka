// audio_controller_probe.cpp - assembly query/pump/self-check witness.

#include <windows.h>

#include "audio_controller_abi.h"

#include <cstdarg>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace {
bool g_paused = false;
uint64_t g_qpcUs = 0;
uint32_t g_inputUpdates = 0;
uint32_t g_logCalls = 0;
uint32_t g_shutdownCalls = 0;
}

namespace vk {

uint32_t audioAsmModPos();
uint32_t audioAsmModLength();
double audioAsmElapsedSec();
void audioAsmPump();
int audioAsmSelfCheck(int seconds);

bool isPaused() {
    return g_paused;
}

uint64_t getQpcUs() {
    g_qpcUs += 600000;
    return g_qpcUs;
}

void updateInput() {
    ++g_inputUpdates;
}

bool quitRequested() {
    return false;
}

void shutdownAndExit() {
    ++g_shutdownCalls;
}

void logPrint(const char*, ...) {
    ++g_logCalls;
}

} // namespace vk

struct AckState {
    AudioLiveControl* control;
    volatile LONG stop = 0;
};

static DWORD WINAPI acknowledge(LPVOID raw) {
    auto* state = static_cast<AckState*>(raw);
    uint32_t seen = 0;
    while (InterlockedCompareExchange(&state->stop, 0, 0) == 0) {
        const uint32_t sequence = state->control->requestSequence;
        if (sequence != seen) {
            InterlockedExchange(
                reinterpret_cast<volatile LONG*>(
                    &state->control->acknowledgedState),
                static_cast<LONG>(state->control->requestedState & 1));
            InterlockedExchange(
                reinterpret_cast<volatile LONG*>(
                    &state->control->acknowledgedSequence),
                static_cast<LONG>(sequence));
            seen = sequence;
        }
        Sleep(1);
    }
    return 0;
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "audio controller: %s\n", message);
    return condition;
}

int main() {
    auto* runtime = reinterpret_cast<AudioControllerRuntimeView*>(
        asm_audio_runtime_state);
    *runtime = AudioControllerRuntimeView{};

    bool ok = true;
    ok &= check(vk::audioAsmModPos() == 0 &&
                    vk::audioAsmModLength() == 0 &&
                    vk::audioAsmElapsedSec() == 0.0,
                "uninitialized query defaults");

    runtime->initialized = 1;
    runtime->storage.orderCount = 42;
    runtime->workerReport.publishedModPos = 0x1234;
    runtime->workerReport.publishedPcmFrame = 5410;
    runtime->seekBaseFrame = 1000;
    runtime->seekTimeBase = 1.5;
    ok &= check(vk::audioAsmModPos() == 0x1234 &&
                    vk::audioAsmModLength() == 42,
                "initialized query values");
    ok &= check(std::fabs(vk::audioAsmElapsedSec() - 1.6) < 1e-12,
                "elapsed-time calculation");

    AckState ack{&runtime->control};
    HANDLE ackThread = CreateThread(nullptr, 0, acknowledge, &ack, 0, nullptr);
    if (!ackThread) {
        std::fprintf(stderr, "audio controller: acknowledgement thread failed\n");
        return 1;
    }

    runtime->playing = 0;
    vk::audioAsmPump();
    ok &= check(runtime->control.requestedState == 1 &&
                    runtime->control.requestSequence == 1 &&
                    runtime->control.acknowledgedSequence == 1 &&
                    runtime->lastControlState == 1 &&
                    runtime->lastControlSequence == 1,
                "pause pump publication");

    runtime->playing = 1;
    g_paused = false;
    vk::audioAsmPump();
    ok &= check(runtime->control.requestedState == 0 &&
                    runtime->control.requestSequence == 2 &&
                    runtime->control.acknowledgedSequence == 2 &&
                    runtime->lastControlState == 0 &&
                    runtime->lastControlSequence == 2,
                "resume pump publication");

    g_paused = true;
    vk::audioAsmPump();
    ok &= check(runtime->control.requestedState == 1 &&
                    runtime->control.requestSequence == 3 &&
                    runtime->lastControlState == 1,
                "pause-flag pump publication");

    g_paused = false;
    vk::audioAsmPump();
    ok &= check(runtime->control.requestedState == 0 &&
                    runtime->control.requestSequence == 4 &&
                    runtime->lastControlState == 0,
                "second resume pump publication");

    InterlockedExchange(&ack.stop, 1);
    WaitForSingleObject(ackThread, INFINITE);
    CloseHandle(ackThread);

    g_qpcUs = 0;
    g_inputUpdates = 0;
    g_logCalls = 0;
    g_shutdownCalls = 0;
    runtime->workerReport.underrunEvents = 0;
    runtime->workerReport.common.workerExit = 0;
    ok &= check(vk::audioAsmSelfCheck(1) == 0 && g_inputUpdates != 0 &&
                    g_logCalls == 1 && g_shutdownCalls == 0,
                "self-check success/report");

    g_qpcUs = 0;
    g_logCalls = 0;
    runtime->workerReport.underrunEvents = 1;
    ok &= check(vk::audioAsmSelfCheck(1) == 1 && g_logCalls == 1,
                "self-check failure report");

    return ok ? 0 : 1;
}
