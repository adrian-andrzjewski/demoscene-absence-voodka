// audio_mod_event_probe.cpp - NASM MOD event decoder vs libxmp.

#include "audio_event_abi.h"
#include <xmp.h>

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
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

bool same(const AudioEvent& got, const xmp_event& expected) {
    return got.note == expected.note &&
           got.instrument == expected.ins &&
           got.volume == expected.vol &&
           got.effect == expected.fxt &&
           got.parameter == expected.fxp &&
           got.secondaryEffect == expected.f2t &&
           got.secondaryParameter == expected.f2p &&
           got.flags == expected._flag;
}

void printMismatch(int pattern, int row, int channel,
                   const uint8_t* raw, const AudioEvent& got,
                   const xmp_event& expected) {
    std::cerr << "mismatch pattern=" << pattern
              << " row=" << row
              << " channel=" << channel
              << " raw=" << std::hex << std::setfill('0')
              << std::setw(2) << static_cast<unsigned>(raw[0]) << ' '
              << std::setw(2) << static_cast<unsigned>(raw[1]) << ' '
              << std::setw(2) << static_cast<unsigned>(raw[2]) << ' '
              << std::setw(2) << static_cast<unsigned>(raw[3])
              << std::dec << " got={"
              << static_cast<unsigned>(got.note) << ','
              << static_cast<unsigned>(got.instrument) << ','
              << static_cast<unsigned>(got.volume) << ','
              << static_cast<unsigned>(got.effect) << ','
              << static_cast<unsigned>(got.parameter) << ','
              << static_cast<unsigned>(got.secondaryEffect) << ','
              << static_cast<unsigned>(got.secondaryParameter) << ','
              << static_cast<unsigned>(got.flags) << "} expected={"
              << static_cast<unsigned>(expected.note) << ','
              << static_cast<unsigned>(expected.ins) << ','
              << static_cast<unsigned>(expected.vol) << ','
              << static_cast<unsigned>(expected.fxt) << ','
              << static_cast<unsigned>(expected.fxp) << ','
              << static_cast<unsigned>(expected.f2t) << ','
              << static_cast<unsigned>(expected.f2p) << ','
              << static_cast<unsigned>(expected._flag) << "}\n";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_mod_event_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!readFile(argv[1], &bytes)) {
        std::cerr << "audio_mod_event_probe: cannot read module\n";
        return 1;
    }

    xmp_context context = xmp_create_context();
    if (!context || xmp_load_module_from_memory(context, bytes.data(),
                                                static_cast<long>(bytes.size())) != 0) {
        if (context) xmp_free_context(context);
        std::cerr << "audio_mod_event_probe: libxmp load failed\n";
        return 1;
    }
    xmp_module_info info{};
    xmp_get_module_info(context, &info);
    const xmp_module* mod = info.mod;
    if (!mod || mod->chn != 14) {
        xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_event_probe: unexpected module shape\n";
        return 1;
    }

    constexpr size_t headerBytes = 1084;
    constexpr size_t eventBytes = 4;
    constexpr size_t rows = 64;
    int failures = 0;
    uint64_t checked = 0;
    for (int pattern = 0; pattern < mod->pat; ++pattern) {
        if (mod->xxp[pattern]->rows != static_cast<int>(rows)) {
            ++failures;
            std::cerr << "unexpected pattern row count pattern=" << pattern
                      << " rows=" << mod->xxp[pattern]->rows << '\n';
            continue;
        }
        const size_t patternBytes = rows * static_cast<size_t>(mod->chn) * eventBytes;
        const uint8_t* patternData = bytes.data() + headerBytes +
                                      static_cast<size_t>(pattern) * patternBytes;
        for (int row = 0; row < static_cast<int>(rows); ++row) {
            for (int channel = 0; channel < mod->chn; ++channel) {
                const uint8_t* raw = patternData +
                    (static_cast<size_t>(row) * static_cast<size_t>(mod->chn) +
                     static_cast<size_t>(channel)) * eventBytes;
                AudioEvent got{};
                const uint32_t status = asm_audio_decode_event(raw, &got);
                const xmp_event& expected = *eventAt(mod, pattern, channel, row);
                ++checked;
                if (status != 0 || !same(got, expected)) {
                    if (failures < 8)
                        printMismatch(pattern, row, channel, raw, got, expected);
                    ++failures;
                }
            }
        }
    }

    const int patterns = mod->pat;
    xmp_release_module(context);
    xmp_free_context(context);
    if (failures) {
        std::cerr << "audio_mod_event_probe: FAIL checked=" << checked
                  << " mismatches=" << failures << '\n';
        return 1;
    }
    std::cout << "audio_mod_event_probe: PASS events=" << checked
              << " patterns=" << patterns << " channels=14\n";
    return 0;
}
