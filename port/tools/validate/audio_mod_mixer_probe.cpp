// audio_mod_mixer_probe.cpp - native assembly PCM mixer vs libxmp oracle.

#include "audio_mix_abi.h"
#include "audio_mod_abi.h"
#include <xmp.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <vector>

namespace {

constexpr int kSampleRate = 44100;
constexpr int kChannels = 2;
constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

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

bool renderOracle(xmp_context context, std::vector<int16_t>* out,
                  std::vector<uint32_t>* tickFrames) {
    if (xmp_start_player(context, kSampleRate, 0) != 0) return false;
    out->clear();
    tickFrames->clear();
    out->reserve(12000000u * kChannels);
    tickFrames->reserve(16000);

    for (uint32_t frame = 0; frame < 100000; ++frame) {
        if (xmp_play_frame(context) != 0) break;

        xmp_frame_info info{};
        xmp_get_frame_info(context, &info);
        if (info.loop_count > 0) break;
        if (!info.buffer || info.buffer_size <= 0 ||
            (info.buffer_size % (kChannels * 2)) != 0) {
            xmp_end_player(context);
            return false;
        }

        const uint32_t count = static_cast<uint32_t>(info.buffer_size / (kChannels * 2));
        tickFrames->push_back(count);
        const auto* pcm = static_cast<const int16_t*>(info.buffer);
        out->insert(out->end(), pcm,
                    pcm + static_cast<size_t>(count) * kChannels);
    }

    xmp_end_player(context);
    return !out->empty() && !tickFrames->empty();
}

uint32_t guardedMix(const uint8_t* module, uint32_t moduleSize,
                    const AudioTickState* states, uint32_t stateFrames,
                    int16_t* output, uint32_t outputCapacity) {
    return asm_audio_mix_tick_states(module, moduleSize, states, stateFrames,
                                      output, outputCapacity);
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2 || argc > 3) {
        std::cerr << "usage: audio_mod_mixer_probe <module.mod> [state-limit]\n";
        return 2;
    }

    std::vector<uint8_t> module;
    if (!readFile(argv[1], &module)) {
        std::cerr << "audio_mod_mixer_probe: cannot read module\n";
        return 1;
    }

    xmp_context context = xmp_create_context();
    if (!context || xmp_load_module_from_memory(context, module.data(),
                                                static_cast<long>(module.size())) != 0) {
        if (context) xmp_free_context(context);
        std::cerr << "audio_mod_mixer_probe: libxmp load failed\n";
        return 1;
    }

    xmp_module_info moduleInfo{};
    xmp_get_module_info(context, &moduleInfo);
    if (!moduleInfo.mod) {
        xmp_free_context(context);
        std::cerr << "audio_mod_mixer_probe: libxmp module info failed\n";
        return 1;
    }

    std::vector<int16_t> expected;
    std::vector<uint32_t> expectedTickFrames;
    if (!renderOracle(context, &expected, &expectedTickFrames)) {
        xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_mixer_probe: oracle render failed\n";
        return 1;
    }

    uint32_t stateLimit = static_cast<uint32_t>(expectedTickFrames.size());
    if (argc == 3) {
        stateLimit = std::min<uint32_t>(
            stateLimit, static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 0)));
    }

    uint64_t targetFrames = 0;
    for (uint32_t i = 0; i < stateLimit; ++i)
        targetFrames += expectedTickFrames[i];
    expected.resize(static_cast<size_t>(targetFrames) * kChannels);
    xmp_release_module(context);
    xmp_free_context(context);

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module.data(), static_cast<uint32_t>(module.size()),
                            &summary) != 0 || summary.status != 0) {
        std::cerr << "audio_mod_mixer_probe: NASM parser failed\n";
        return 1;
    }

    std::vector<AudioTickState> states(20000u * summary.channelCount);
    uint32_t stateFrames = asm_audio_trace_tick_states(
        module.data(), static_cast<uint32_t>(module.size()), states.data(), 20000);
    if (stateFrames == 0) {
        std::cerr << "audio_mod_mixer_probe: native state trace failed\n";
        return 1;
    }
    stateFrames = std::min(stateFrames, stateLimit);
    const uint32_t stateChannels = summary.channelCount;

    uint64_t tickMismatches = 0;
    const uint32_t comparable = std::min<uint32_t>(
        stateFrames, static_cast<uint32_t>(expectedTickFrames.size()));
    for (uint32_t frame = 0; frame < comparable; ++frame) {
        if (states[static_cast<size_t>(frame) * stateChannels].tickFrames !=
            expectedTickFrames[frame]) {
            if (tickMismatches < 4) {
                std::cerr << "tick mismatch frame=" << frame
                          << " got="
                          << states[static_cast<size_t>(frame) * stateChannels].tickFrames
                          << " expected=" << expectedTickFrames[frame] << '\n';
            }
            ++tickMismatches;
        }
    }
    if (stateFrames != stateLimit || tickMismatches != 0) {
        std::cerr << "audio_mod_mixer_probe: tick-size mismatch states=" << stateFrames
                  << " oracle=" << stateLimit
                  << " mismatches=" << tickMismatches << '\n';
        return 1;
    }

    std::vector<int16_t> got(static_cast<size_t>(targetFrames) * kChannels);
    const uint32_t gotFrames = guardedMix(
        module.data(), static_cast<uint32_t>(module.size()), states.data(),
        stateFrames, got.data(), static_cast<uint32_t>(targetFrames));
    if (gotFrames != targetFrames) {
        std::cerr << "audio_mod_mixer_probe: native frames=" << gotFrames
                  << " expected=" << targetFrames << " states=" << stateFrames << '\n';
        return 1;
    }

    uint64_t mismatches = 0;
    size_t firstMismatch = got.size();
    for (size_t i = 0; i < got.size(); ++i) {
        if (got[i] != expected[i]) {
            if (firstMismatch == got.size()) firstMismatch = i;
            if (mismatches < 8) {
                std::cerr << "mismatch sample=" << i
                          << " frame=" << (i / kChannels)
                          << " channel=" << (i % kChannels)
                          << " got=" << got[i]
                          << " expected=" << expected[i] << '\n';
            }
            ++mismatches;
        }
    }

    Fnv64 gotHash;
    Fnv64 expectedHash;
    gotHash.add(got.data(), got.size() * sizeof(int16_t));
    expectedHash.add(expected.data(), expected.size() * sizeof(int16_t));
    if (mismatches) {
        std::cerr << "audio_mod_mixer_probe: FAIL frames=" << gotFrames
                  << " states=" << stateFrames
                  << " first_sample=" << firstMismatch
                  << " sample_mismatches=" << mismatches
                  << " got_fnv=0x" << std::hex << gotHash.value
                  << " expected_fnv=0x" << expectedHash.value << std::dec << '\n';
        return 1;
    }

    std::cout << "audio_mod_mixer_probe: PASS frames=" << gotFrames
              << " states=" << stateFrames
              << " pcm_fnv=0x" << std::hex << gotHash.value << std::dec << '\n';
    return 0;
}
