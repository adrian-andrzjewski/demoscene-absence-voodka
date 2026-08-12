// audio_mod_voice_probe.cpp - NASM row voice identity vs libxmp.

#include "audio_mod_abi.h"
#include "audio_voice_abi.h"
#include <xmp.h>

#include <cstdint>
#include <fstream>
#include <iostream>
#include <vector>

namespace {

bool readFile(const char* path, std::vector<uint8_t>* out) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return false;
    const std::streamoff size = file.tellg();
    if (size <= 0) return false;
    out->resize(static_cast<size_t>(size));
    file.seekg(0, std::ios::beg);
    return static_cast<bool>(file.read(reinterpret_cast<char*>(out->data()), size));
}

const xmp_event* eventAt(const xmp_module* mod, int pattern, int channel, int row) {
    const int track = mod->xxp[pattern]->index[channel];
    return &mod->xxt[track]->event[row];
}

bool sameEvent(const AudioEvent& got, const xmp_event& expected) {
    return got.note == expected.note &&
           got.instrument == expected.ins &&
           got.volume == expected.vol &&
           got.effect == expected.fxt &&
           got.parameter == expected.fxp &&
           got.secondaryEffect == expected.f2t &&
           got.secondaryParameter == expected.f2p &&
           got.flags == expected._flag;
}

void reportMismatch(uint32_t rowIndex, int channel,
                    const AudioVoiceState& got,
                    const xmp_channel_info& expected,
                    uint8_t expectedVolume,
                    const char* reason) {
    std::cerr << "mismatch row_index=" << rowIndex
              << " channel=" << channel << " reason=" << reason
              << " got={note=" << static_cast<unsigned>(got.note)
              << ",ins=" << static_cast<unsigned>(got.instrument)
              << ",smp=" << static_cast<unsigned>(got.sample)
              << ",sample_vol=" << static_cast<unsigned>(got.sampleVolume)
              << "} expected={note=" << static_cast<unsigned>(expected.note)
              << ",ins=" << static_cast<unsigned>(expected.instrument)
              << ",smp=" << static_cast<unsigned>(expected.sample)
              << ",sample_vol=" << static_cast<unsigned>(expectedVolume)
              << "}\n";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_mod_voice_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!readFile(argv[1], &bytes)) {
        std::cerr << "audio_mod_voice_probe: cannot read module\n";
        return 1;
    }

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(bytes.data(), static_cast<uint32_t>(bytes.size()),
                            &summary) != 0 || summary.status != 0) {
        std::cerr << "audio_mod_voice_probe: NASM parser failed\n";
        return 1;
    }

    const uint32_t expectedRows = summary.rowsPerLoop;
    const uint32_t expectedStates = expectedRows * summary.channelCount;
    std::vector<AudioVoiceState> got(expectedStates);
    const uint32_t gotCount = asm_audio_trace_voice_rows(
        bytes.data(), static_cast<uint32_t>(bytes.size()), got.data(), expectedRows);
    if (gotCount != expectedRows) {
        std::cerr << "audio_mod_voice_probe: NASM row count=" << gotCount
                  << " expected=" << expectedRows << '\n';
        return 1;
    }

    xmp_context context = xmp_create_context();
    if (!context || xmp_load_module_from_memory(context, bytes.data(),
                                                static_cast<long>(bytes.size())) != 0) {
        if (context) xmp_free_context(context);
        std::cerr << "audio_mod_voice_probe: libxmp load failed\n";
        return 1;
    }
    xmp_module_info info{};
    xmp_get_module_info(context, &info);
    const xmp_module* mod = info.mod;
    if (!mod || mod->chn != static_cast<int>(summary.channelCount) ||
        xmp_start_player(context, 44100, 0) != 0) {
        if (mod) xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_voice_probe: libxmp start failed\n";
        return 1;
    }

    uint32_t observedRows = 0;
    int failures = 0;
    xmp_frame_info frame{};
    while (observedRows < expectedRows && xmp_play_frame(context) == 0) {
        xmp_get_frame_info(context, &frame);
        if (frame.frame != 0)
            continue;

        for (int channel = 0; channel < mod->chn; ++channel) {
            const AudioVoiceState& a = got[
                observedRows * static_cast<uint32_t>(mod->chn) +
                static_cast<uint32_t>(channel)];
            const xmp_channel_info& b = frame.channel_info[channel];
            const xmp_event* expectedEvent = eventAt(mod, frame.pattern, channel, frame.row);
            uint8_t expectedVolume = 0;
            if (b.instrument < mod->ins)
                expectedVolume = static_cast<uint8_t>(
                    mod->xxi[b.instrument].sub[0].vol);

            const bool ok = sameEvent(a.event, *expectedEvent) &&
                            a.note == b.note &&
                            a.instrument == b.instrument &&
                            a.sample == b.sample &&
                            a.sampleVolume == expectedVolume;
            if (!ok) {
                if (failures < 8)
                    reportMismatch(observedRows, channel, a, b,
                                   expectedVolume,
                                   sameEvent(a.event, *expectedEvent)
                                       ? "voice state" : "row event");
                ++failures;
            }
        }
        ++observedRows;
    }

    const int reportChannels = mod->chn;
    xmp_end_player(context);
    xmp_release_module(context);
    xmp_free_context(context);
    if (observedRows != expectedRows || failures) {
        std::cerr << "audio_mod_voice_probe: FAIL rows=" << observedRows
                  << " expected_rows=" << expectedRows
                  << " state_mismatches=" << failures << '\n';
        return 1;
    }

    std::cout << "audio_mod_voice_probe: PASS rows=" << observedRows
              << " channels=" << reportChannels
              << " states=" << expectedStates << '\n';
    return 0;
}
