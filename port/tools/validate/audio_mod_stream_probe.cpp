// audio_mod_stream_probe.cpp - continuous bounded assembly mixer gate.

#include "audio_mix_abi.h"
#include "audio_mod_abi.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <vector>

namespace {

constexpr uint32_t kStateCapacity = 20000;
constexpr uint32_t kChannels = 14;
constexpr uint32_t kOutputChannels = 2;
constexpr uint64_t kExpectedPcmFnv = 0x18C7451650A7C772ull;
constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;
constexpr uint32_t kChunkPattern[] = {
    1, 7, 31, 64, 127, 257, 511, 1024, 3, 89, 5, 43};

struct Fnv64 {
    uint64_t value = kFnvOffset;

    void add(const void* data, size_t bytes) {
        const auto* p = static_cast<const uint8_t*>(data);
        for (size_t i = 0; i < bytes; ++i) {
            value ^= p[i];
            value *= kFnvPrime;
        }
    }
};

bool readFile(const char* path, std::vector<uint8_t>* out) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return false;
    const std::streamoff size = file.tellg();
    if (size <= 0) return false;
    out->resize(static_cast<size_t>(size));
    file.seekg(0, std::ios::beg);
    return static_cast<bool>(file.read(reinterpret_cast<char*>(out->data()), size));
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_mod_stream_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> module;
    if (!readFile(argv[1], &module)) {
        std::cerr << "audio_mod_stream_probe: cannot read module\n";
        return 1;
    }

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module.data(), static_cast<uint32_t>(module.size()),
                            &summary) != 0 || summary.status != 0 ||
        summary.channelCount != kChannels) {
        std::cerr << "audio_mod_stream_probe: NASM parser failed\n";
        return 1;
    }

    std::vector<AudioTickState> states(
        static_cast<size_t>(kStateCapacity) * summary.channelCount);
    const uint32_t stateFrames = asm_audio_trace_tick_states(
        module.data(), static_cast<uint32_t>(module.size()), states.data(),
        kStateCapacity);
    if (!stateFrames || stateFrames > kStateCapacity) {
        std::cerr << "audio_mod_stream_probe: native state trace failed\n";
        return 1;
    }

    uint64_t totalFrames64 = 0;
    for (uint32_t frame = 0; frame < stateFrames; ++frame)
        totalFrames64 += states[static_cast<size_t>(frame) * kChannels].tickFrames;
    if (!totalFrames64 || totalFrames64 > 0xffffffffull) {
        std::cerr << "audio_mod_stream_probe: invalid output frame count\n";
        return 1;
    }
    const uint32_t totalFrames = static_cast<uint32_t>(totalFrames64);
    std::vector<int16_t> output(static_cast<size_t>(totalFrames) * kOutputChannels);
    AudioMixerHistory history{};

    uint32_t stateFrame = 0;
    uint32_t outputFrame = 0;
    uint32_t chunkIndex = 0;
    uint32_t chunks = 0;
    while (stateFrame < stateFrames) {
        const uint32_t remaining = stateFrames - stateFrame;
        const uint32_t requested = kChunkPattern[
            chunkIndex % (sizeof(kChunkPattern) / sizeof(kChunkPattern[0]))];
        const uint32_t chunkFrames = requested < remaining ? requested : remaining;
        uint32_t chunkOutputFrames = 0;
        for (uint32_t i = 0; i < chunkFrames; ++i) {
            chunkOutputFrames += states[
                static_cast<size_t>(stateFrame + i) * kChannels].tickFrames;
        }

        const uint32_t gotFrames = asm_audio_mix_tick_states_continuous(
            module.data(), static_cast<uint32_t>(module.size()),
            states.data() + static_cast<size_t>(stateFrame) * kChannels,
            chunkFrames,
            output.data() + static_cast<size_t>(outputFrame) * kOutputChannels,
            chunkOutputFrames, &history);
        if (gotFrames != chunkOutputFrames) {
            std::cerr << "audio_mod_stream_probe: chunk=" << chunks
                      << " got=" << gotFrames
                      << " expected=" << chunkOutputFrames << '\n';
            return 1;
        }
        stateFrame += chunkFrames;
        outputFrame += gotFrames;
        ++chunkIndex;
        ++chunks;
    }

    Fnv64 hash;
    hash.add(output.data(), output.size() * sizeof(int16_t));
    std::cout << "audio_mod_stream_probe: frames=" << outputFrame
              << " states=" << stateFrames
              << " chunks=" << chunks
              << " pcm_fnv=0x" << std::hex << hash.value << std::dec << '\n';
    return outputFrame == totalFrames && hash.value == kExpectedPcmFnv ? 0 : 1;
}
