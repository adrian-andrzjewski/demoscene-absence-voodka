// audio_sync_probe.cpp - asynchronous acknowledgement witness for NASM state sync.

#include <windows.h>

#include "audio_thread_abi.h"

#include <cstdint>
#include <cstdio>

extern "C" uint32_t asm_audio_issue_state(AudioLiveControl* control,
                                             uint32_t state,
                                             uint32_t* lastState,
                                             uint32_t* lastSequence,
                                             uint32_t* sequenceOut);

struct AckArgs {
    AudioLiveControl* control;
    uint32_t expectedState;
};

static DWORD WINAPI acknowledge(LPVOID raw) {
    auto* args = static_cast<AckArgs*>(raw);
    while (args->control->requestSequence == 0) SwitchToThread();
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&args->control->acknowledgedState),
        static_cast<LONG>(args->expectedState & 1));
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&args->control->acknowledgedSequence),
        static_cast<LONG>(args->control->requestSequence));
    return 0;
}

int main() {
    AudioLiveControl control{};
    uint32_t cachedState = 0;
    uint32_t cachedSequence = 0;
    uint32_t sequenceOut = 0;
    AckArgs args{&control, 1};
    HANDLE thread = CreateThread(nullptr, 0, acknowledge, &args, 0, nullptr);
    if (!thread) {
        std::fprintf(stderr, "CreateThread failed\n");
        return 1;
    }

    const uint32_t result = asm_audio_issue_state(
        &control, args.expectedState, &cachedState, &cachedSequence,
        &sequenceOut);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);

    const bool ok = result == 1 && control.requestedState == 1 &&
        control.requestSequence == 1 && control.acknowledgedState == 1 &&
        control.acknowledgedSequence == 1 && cachedState == 1 &&
        cachedSequence == 1 && sequenceOut == 1;
    if (!ok) {
        std::fprintf(stderr,
                     "state sync mismatch result=%u request=%u/%u ack=%u/%u "
                     "cache=%u/%u out=%u\n",
                     result, control.requestedState, control.requestSequence,
                     control.acknowledgedState, control.acknowledgedSequence,
                     cachedState, cachedSequence, sequenceOut);
    }
    return ok ? 0 : 1;
}
