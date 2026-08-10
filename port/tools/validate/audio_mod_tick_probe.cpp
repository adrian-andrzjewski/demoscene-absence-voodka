// audio_mod_tick_probe.cpp - NASM tracker effect/tick state vs libxmp.

#include "audio_mod_abi.h"
#include "audio_tick_abi.h"
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

bool sameEvent(const AudioEvent& a, const xmp_event& b) {
    return a.note == b.note && a.instrument == b.ins && a.volume == b.vol &&
           a.effect == b.fxt && a.parameter == b.fxp &&
           a.secondaryEffect == b.f2t && a.secondaryParameter == b.f2p &&
           a.flags == b._flag;
}

bool sameState(const AudioTickState& a, const xmp_channel_info& b,
              const xmp_event& event) {
    return a.period == b.period && a.pitchbend == b.pitchbend &&
           a.note == b.note && a.instrument == b.instrument &&
           a.sample == b.sample && a.volume == b.volume && a.pan == b.pan &&
           sameEvent(a.event, event);
}

void printMismatch(uint32_t frame, int channel,
                   const xmp_frame_info& info,
                   const AudioTickState& a,
                   const xmp_channel_info& b,
                   const xmp_event& event) {
    std::cerr << "mismatch frame=" << frame
              << " pos=" << info.pos
              << " row=" << info.row
              << " tick=" << info.frame
              << " channel=" << channel
              << " got={period=" << a.period
              << ",bend=" << a.pitchbend
              << ",note=" << static_cast<unsigned>(a.note)
              << ",ins=" << static_cast<unsigned>(a.instrument)
              << ",smp=" << static_cast<unsigned>(a.sample)
              << ",vol=" << static_cast<unsigned>(a.volume)
              << ",pan=" << static_cast<unsigned>(a.pan)
              << ",samplePos=" << a.samplePosition
              << "} expected={period=" << b.period
              << ",bend=" << b.pitchbend
              << ",note=" << static_cast<unsigned>(b.note)
              << ",ins=" << static_cast<unsigned>(b.instrument)
              << ",smp=" << static_cast<unsigned>(b.sample)
              << ",vol=" << static_cast<unsigned>(b.volume)
              << ",pan=" << static_cast<unsigned>(b.pan)
              << ",position=" << b.position << "}\n"
              << "  event got={note=" << static_cast<unsigned>(a.event.note)
              << ",ins=" << static_cast<unsigned>(a.event.instrument)
              << ",vol=" << static_cast<unsigned>(a.event.volume)
              << ",fx=" << static_cast<unsigned>(a.event.effect)
              << ",fp=" << static_cast<unsigned>(a.event.parameter)
              << ",f2=" << static_cast<unsigned>(a.event.secondaryEffect)
              << ",f2p=" << static_cast<unsigned>(a.event.secondaryParameter)
              << ",flag=" << static_cast<unsigned>(a.event.flags) << "} expected={note="
               << static_cast<unsigned>(event.note)
               << ",ins=" << static_cast<unsigned>(event.ins)
               << ",vol=" << static_cast<unsigned>(event.vol)
               << ",fx=" << static_cast<unsigned>(event.fxt)
               << ",fp=" << static_cast<unsigned>(event.fxp)
               << ",f2=" << static_cast<unsigned>(event.f2t)
               << ",f2p=" << static_cast<unsigned>(event.f2p)
               << ",flag=" << static_cast<unsigned>(event._flag) << "}\n";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_mod_tick_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!readFile(argv[1], &bytes)) {
        std::cerr << "audio_mod_tick_probe: cannot read module\n";
        return 1;
    }

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(bytes.data(), static_cast<uint32_t>(bytes.size()),
                            &summary) != 0 || summary.status != 0) {
        std::cerr << "audio_mod_tick_probe: NASM parser failed\n";
        return 1;
    }

    xmp_context context = xmp_create_context();
    if (!context || xmp_load_module_from_memory(context, bytes.data(),
                                                static_cast<long>(bytes.size())) != 0) {
        if (context) xmp_free_context(context);
        std::cerr << "audio_mod_tick_probe: libxmp load failed\n";
        return 1;
    }
    xmp_module_info moduleInfo{};
    xmp_get_module_info(context, &moduleInfo);
    const xmp_module* mod = moduleInfo.mod;
    if (!mod || mod->chn != static_cast<int>(summary.channelCount) ||
        xmp_start_player(context, 44100, 0) != 0) {
        if (mod) xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_tick_probe: libxmp start failed\n";
        return 1;
    }

    std::vector<xmp_frame_info> frames;
    frames.reserve(16000);
    xmp_frame_info frame{};
    while (xmp_play_frame(context) == 0) {
        xmp_get_frame_info(context, &frame);
        if (frame.loop_count > 0)
            break;
        frames.push_back(frame);
        if (frames.size() > 100000) {
            std::cerr << "audio_mod_tick_probe: oracle did not loop\n";
            xmp_end_player(context);
            xmp_release_module(context);
            xmp_free_context(context);
            return 1;
        }
    }
    if (frames.empty()) {
        xmp_end_player(context);
        xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_tick_probe: empty libxmp trace\n";
        return 1;
    }

    std::vector<AudioTickState> got(frames.size() * summary.channelCount);
    const uint32_t gotFrames = asm_audio_trace_tick_states(
        bytes.data(), static_cast<uint32_t>(bytes.size()), got.data(),
        static_cast<uint32_t>(frames.size()));
    if (gotFrames != frames.size()) {
        std::cerr << "audio_mod_tick_probe: NASM frames=" << gotFrames
                  << " expected=" << frames.size() << '\n';
        xmp_end_player(context);
        xmp_release_module(context);
        xmp_free_context(context);
        return 1;
    }

    int failures = 0;
    uint64_t fieldMismatches[8]{};
    for (size_t f = 0; f < frames.size(); ++f) {
        const xmp_frame_info& expectedFrame = frames[f];
        for (int channel = 0; channel < mod->chn; ++channel) {
            const AudioTickState& a = got[f * static_cast<size_t>(mod->chn) +
                                           static_cast<size_t>(channel)];
            const xmp_channel_info& b = expectedFrame.channel_info[channel];
            const int track = mod->xxp[expectedFrame.pattern]->index[channel];
            const xmp_event& event = mod->xxt[track]->event[expectedFrame.row];
            if (!sameState(a, b, event)) {
                if (a.period != b.period) ++fieldMismatches[0];
                if (a.pitchbend != b.pitchbend) ++fieldMismatches[1];
                if (a.note != b.note) ++fieldMismatches[2];
                if (a.instrument != b.instrument) ++fieldMismatches[3];
                if (a.sample != b.sample) ++fieldMismatches[4];
                if (a.volume != b.volume) ++fieldMismatches[5];
                if (a.pan != b.pan) ++fieldMismatches[6];
                if (!sameEvent(a.event, event)) ++fieldMismatches[7];
                if (failures < 8)
                    printMismatch(static_cast<uint32_t>(f), channel,
                                  expectedFrame, a, b, event);
                ++failures;
            }
        }
    }

    const size_t reportFrames = frames.size();
    const int reportChannels = mod->chn;
    xmp_end_player(context);
    xmp_release_module(context);
    xmp_free_context(context);
    if (failures) {
        std::cerr << "audio_mod_tick_probe: FAIL frames=" << reportFrames
                  << " channels=" << reportChannels
                  << " mismatches=" << failures
                  << " fields={period=" << fieldMismatches[0]
                  << ",bend=" << fieldMismatches[1]
                  << ",note=" << fieldMismatches[2]
                  << ",ins=" << fieldMismatches[3]
                  << ",smp=" << fieldMismatches[4]
                  << ",vol=" << fieldMismatches[5]
                  << ",pan=" << fieldMismatches[6]
                  << ",event=" << fieldMismatches[7] << '}\n';
        return 1;
    }

    std::cout << "audio_mod_tick_probe: PASS frames=" << reportFrames
              << " channels=" << reportChannels
              << " states=" << reportFrames * static_cast<size_t>(reportChannels)
              << '\n';
    return 0;
}
