// audio_seek_controller_probe.cpp - public seek wrapper ABI witness.

#include "audio_controller_abi.h"
#include "audio_seek_abi.h"

#include <cstdint>
#include <cstdio>

extern "C" unsigned char asm_audio_runtime_state[0x2000];

namespace vk {

uint32_t audioAsmSeekRows(uint32_t modpos);
uint32_t audioAsmSeekMs(int ms);
uint32_t audioAsmSeekOrder(int order);

} // namespace vk

namespace {
uint32_t g_modpos[] = {0x100, 0x200, 0x200, 0x500, 0x900};
uint32_t g_tickTimes[] = {0, 10, 10, 20, 30};
uint32_t g_tickStarts[] = {0, 44100, 88200, 132300, 176400};
uint32_t g_transactionStatus = 1;
uint32_t g_transactionCalls = 0;
bool g_transactionShapeOk = true;
}

extern "C" uint32_t asm_audio_seek_transaction(
    const AudioSeekTransactionArgs* args) {
    ++g_transactionCalls;
    auto* runtime = reinterpret_cast<AudioControllerRuntimeView*>(
        asm_audio_runtime_state);
    g_transactionShapeOk = args &&
        args->control == &runtime->control &&
        args->ring == &runtime->ring &&
        args->producerFailed == reinterpret_cast<volatile uint32_t*>(
            &runtime->producerFailed) &&
        args->lastState == &runtime->lastControlState &&
        args->lastSequence == &runtime->lastControlSequence &&
        args->baseConsumedOut != nullptr &&
        args->seekSequenceOut != nullptr;
    if (args && args->baseConsumedOut) *args->baseConsumedOut = 1234;
    if (args && args->seekSequenceOut) *args->seekSequenceOut = 77;
    return g_transactionStatus;
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "audio seek controller: %s\n", message);
    return condition;
}

int main() {
    auto* runtime = reinterpret_cast<AudioControllerRuntimeView*>(
        asm_audio_runtime_state);
    *runtime = AudioControllerRuntimeView{};
    runtime->storage.stateFrames = 5;
    runtime->storage.modposByTick = g_modpos;
    runtime->storage.tickTimesMs = g_tickTimes;
    runtime->storage.tickStarts = g_tickStarts;

    bool ok = true;
    ok &= check(vk::audioAsmSeekRows(0x200) == 0,
                "uninitialized ModPos defaults");

    runtime->initialized = 1;
    g_transactionCalls = 0;
    g_transactionShapeOk = true;
    g_transactionStatus = 1;
    ok &= check(vk::audioAsmSeekRows(0x200) == 0x200 &&
                    g_transactionCalls == 1 && g_transactionShapeOk &&
                    runtime->seekBaseFrame == 1234 &&
                    runtime->seekSourceTick == 1 &&
                    runtime->seekTimeBase == 1.0,
                "duplicate ModPos lookup and metadata commit");

    ok &= check(vk::audioAsmSeekMs(10) == 0x200 &&
                    runtime->seekSourceTick == 1,
                "millisecond lower-bound lookup");
    ok &= check(vk::audioAsmSeekOrder(2) == 0x200 &&
                    runtime->seekSourceTick == 1,
                "order-to-ModPos lookup");
    const uint32_t callsBeforeInvalid = g_transactionCalls;
    ok &= check(vk::audioAsmSeekMs(-1) == 0 &&
                    vk::audioAsmSeekOrder(-1) == 0 &&
                    g_transactionCalls == callsBeforeInvalid,
                "negative seek input rejection");

    g_transactionStatus = 2;
    ok &= check(vk::audioAsmSeekRows(0x500) == 0 &&
                    runtime->seekSourceTick == 3 &&
                    runtime->seekBaseFrame == 1234,
                "status-2 metadata preservation");

    const uint32_t committedBase = runtime->seekBaseFrame;
    const uint32_t committedSource = runtime->seekSourceTick;
    const double committedTime = runtime->seekTimeBase;
    g_transactionStatus = 0;
    ok &= check(vk::audioAsmSeekRows(0x900) == 0 &&
                    runtime->seekBaseFrame == committedBase &&
                    runtime->seekSourceTick == committedSource &&
                    runtime->seekTimeBase == committedTime,
                "failed transaction leaves metadata unchanged");

    return ok ? 0 : 1;
}
