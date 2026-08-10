// audio_mod_parse_probe.cpp - NASM parser vs libxmp inventory cross-check.

#include "audio_mod_abi.h"
#include <xmp.h>

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>

namespace {

struct EffectStat {
    uint32_t count = 0;
    uint8_t minParam = 0xff;
    uint8_t maxParam = 0;

    void add(uint8_t value) {
        ++count;
        minParam = std::min(minParam, value);
        maxParam = std::max(maxParam, value);
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

const xmp_event* eventAt(const xmp_module* mod, int pattern, int channel, int row) {
    const int track = mod->xxp[pattern]->index[channel];
    return &mod->xxt[track]->event[row];
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_mod_parse_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!readFile(argv[1], &bytes)) {
        std::cerr << "audio_mod_parse_probe: cannot read module\n";
        return 1;
    }

    audio_abi::Summary got{};
    const uint32_t parseStatus = asm_audio_parse_mod(bytes.data(),
                                                      static_cast<uint32_t>(bytes.size()),
                                                      &got);
    xmp_context context = xmp_create_context();
    if (!context || xmp_load_module_from_memory(context, bytes.data(),
                                                static_cast<long>(bytes.size())) != 0) {
        if (context) xmp_free_context(context);
        std::cerr << "audio_mod_parse_probe: libxmp load failed\n";
        return 1;
    }
    xmp_module_info info{};
    xmp_get_module_info(context, &info);
    const xmp_module* mod = info.mod;
    if (!mod) {
        xmp_release_module(context);
        xmp_free_context(context);
        return 1;
    }

    int failures = 0;
    auto check = [&](bool ok, const char* label) {
        if (!ok) {
            ++failures;
            std::cerr << "mismatch: " << label << '\n';
        }
    };

    uint32_t sampleBytes = 0;
    for (int i = 0; i < mod->smp; ++i)
        sampleBytes += static_cast<uint32_t>(mod->xxs[i].len);
    uint32_t rowsPerLoop = 0;
    for (int order = 0; order < mod->len; ++order)
        rowsPerLoop += static_cast<uint32_t>(mod->xxp[mod->xxo[order]]->rows);
    const uint32_t patternDataBytes = static_cast<uint32_t>(mod->pat) * 64u *
                                      static_cast<uint32_t>(mod->chn) * 4u;
    const uint32_t sampleDataOffset = 1084u + patternDataBytes;

    check(parseStatus == 0 && got.status == 0, "parse status");
    check(got.moduleBytes == bytes.size(), "module bytes");
    check(got.headerBytes == 1084, "header bytes");
    check(got.patternDataOffset == 1084, "pattern data offset");
    check(got.sampleDataOffset == sampleDataOffset, "sample data offset");
    check(got.sampleDataBytes == sampleBytes, "sample data bytes");
    check(got.trailingBytes == bytes.size() - sampleDataOffset - sampleBytes,
          "trailing bytes");
    check(got.rowsPerLoop == rowsPerLoop, "rows per loop");
    check(got.modposPerLoop == rowsPerLoop * 4u, "ModPos loop span");
    check(got.orderCount == static_cast<uint32_t>(mod->len), "order count");
    check(got.patternCount == static_cast<uint32_t>(mod->pat), "pattern count");
    check(got.channelCount == static_cast<uint32_t>(mod->chn), "channel count");
    check(got.instrumentCount == static_cast<uint32_t>(mod->ins), "instrument count");

    for (int i = 0; i < mod->len; ++i)
        check(got.orders[i] == mod->xxo[i], "order table");
    for (int i = 0; i < mod->pat; ++i)
        check(got.patternRows[i] == static_cast<uint32_t>(mod->xxp[i]->rows), "pattern rows");

    for (int i = 0; i < mod->smp; ++i) {
        const auto& a = got.samples[i];
        const auto& b = mod->xxs[i];
        check(a.length == static_cast<uint32_t>(b.len), "sample length");
        check(a.loopStart == static_cast<uint32_t>(b.lps), "sample loop start");
        check(a.loopEnd == static_cast<uint32_t>(b.lpe), "sample loop end");
        check((a.flags & 2u) == (static_cast<uint32_t>(b.flg) & 2u), "sample loop flag");
    }

    std::map<unsigned, EffectStat> primary;
    std::map<unsigned, EffectStat> secondary;
    uint32_t populated = 0, notes = 0, instruments = 0, volumes = 0;
    for (int pattern = 0; pattern < mod->pat; ++pattern) {
        for (int row = 0; row < mod->xxp[pattern]->rows; ++row) {
            for (int channel = 0; channel < mod->chn; ++channel) {
                const xmp_event* e = eventAt(mod, pattern, channel, row);
                if (e->note) ++notes;
                if (e->ins) ++instruments;
                if (e->vol) ++volumes;
                if (e->note || e->ins || e->vol || e->fxt || e->fxp || e->f2t || e->f2p)
                    ++populated;
                if (e->fxt) primary[e->fxt].add(e->fxp);
                if (e->f2t) secondary[e->f2t].add(e->f2p);
            }
        }
    }
    check(got.populatedEvents == populated, "populated events");
    check(got.noteEvents == notes, "note events");
    check(got.instrumentEvents == instruments, "instrument events");
    check(got.volumeEvents == volumes, "volume events");
    for (unsigned i = 0; i < 16; ++i) {
        const auto& p = got.primaryEffects[i];
        const auto it = primary.find(i);
        const EffectStat expected = it == primary.end() ? EffectStat{} : it->second;
        check(p.count == expected.count, "primary effect count");
        check(p.minParam == expected.minParam, "primary effect min");
        check(p.maxParam == expected.maxParam, "primary effect max");
    }
    for (unsigned i = 0; i < 16; ++i) {
        const auto& p = got.secondaryEffects[i];
        const auto it = secondary.find(i);
        const EffectStat expected = it == secondary.end() ? EffectStat{} : it->second;
        check(p.count == expected.count, "secondary effect count");
        check(p.minParam == expected.minParam, "secondary effect min");
        check(p.maxParam == expected.maxParam, "secondary effect max");
    }

    if (failures) {
        xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_parse_probe: FAIL mismatches=" << failures << '\n';
        return 1;
    }
    const int reportPatterns = mod->pat;
    const int reportOrders = mod->len;
    const int reportChannels = mod->chn;
    xmp_release_module(context);
    xmp_free_context(context);
    std::cout << "audio_mod_parse_probe: PASS bytes=" << bytes.size()
              << " patterns=" << reportPatterns
              << " orders=" << reportOrders
              << " channels=" << reportChannels
              << " rows_per_loop=" << rowsPerLoop
              << " sample_bytes=" << sampleBytes << '\n';
    return 0;
}
