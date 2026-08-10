// audio_dispatch.cpp - production audio ABI for the assembly-only player.
//
// The shipped VOODKA target deliberately has no libxmp dependency. The
// C++/libxmp implementation remains in the separate VOODKA_REFERENCE target
// and is not part of this dispatch layer.

#include "platform_abi.h"

#include <cstdint>

namespace vk {

int audioAsmInit(const char* modPath, int sampleRate);
void audioAsmShutdown();
int audioAsmPlay();
int audioAsmStop();
uint32_t audioAsmModPos();
uint32_t audioAsmModLength();
double audioAsmElapsedSec();
void audioAsmPump();
uint32_t audioAsmSeekRows(uint32_t modpos);
uint32_t audioAsmSeekMs(int ms);
uint32_t audioAsmSeekOrder(int order);
int audioAsmSelfCheck(int seconds);

namespace {
bool g_assemblyEnabled = true;
}

void audioSetAssemblyMode(bool enabled) {
    g_assemblyEnabled = enabled;
}

int audioInit(const char* modPath, int sampleRate) {
    if (!g_assemblyEnabled) {
        logPrint("[audio] libxmp reference path is unavailable in VOODKA.exe\n");
        return 0;
    }
    return audioAsmInit(modPath, sampleRate);
}

void audioShutdown() {
    audioAsmShutdown();
}

int audioPlay() {
    return g_assemblyEnabled ? audioAsmPlay() : 0;
}

int audioStop() {
    return g_assemblyEnabled ? audioAsmStop() : 0;
}

uint32_t getModPos() {
    return g_assemblyEnabled ? audioAsmModPos() : 0;
}

uint32_t getModLength() {
    return g_assemblyEnabled ? audioAsmModLength() : 0;
}

double audioElapsedSec() {
    return g_assemblyEnabled ? audioAsmElapsedSec() : 0.0;
}

void audioPump() {
    if (g_assemblyEnabled) audioAsmPump();
}

uint32_t audioSeekRows(uint32_t modpos) {
    return g_assemblyEnabled ? audioAsmSeekRows(modpos) : 0;
}

uint32_t audioSeekMs(int ms) {
    return g_assemblyEnabled ? audioAsmSeekMs(ms) : 0;
}

uint32_t audioSeekOrder(int order) {
    return g_assemblyEnabled ? audioAsmSeekOrder(order) : 0;
}

int audioSelfCheck(int seconds) {
    return g_assemblyEnabled ? audioAsmSelfCheck(seconds) : 1;
}

} // namespace vk
