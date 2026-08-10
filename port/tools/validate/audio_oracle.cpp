// audio_oracle.cpp - Phase 2A libxmp behavioral oracle.
//
// This is intentionally a host-side validation tool, not production playback.
// It freezes the exact module inventory, row/tick timeline, and 44.1 kHz
// stereo PCM produced by the current libxmp path before a dedicated NASM
// player is attempted.  The generated report belongs in the build tree; the
// production VOODKA target continues to use the existing C++ implementation.

#include <xmp.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int kSampleRate = 44100;
constexpr int kChannels = 2;
constexpr int kBytesPerFrame = kChannels * static_cast<int>(sizeof(int16_t));
constexpr int kChunkFrames = 4096;
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

struct EffectStat {
    uint64_t count = 0;
    uint8_t minParam = 0xff;
    uint8_t maxParam = 0;

    void add(uint8_t param) {
        ++count;
        minParam = std::min(minParam, param);
        maxParam = std::max(maxParam, param);
    }
};

struct LoadedModule {
    std::vector<uint8_t> bytes;
    xmp_context context = nullptr;
    bool started = false;

    ~LoadedModule() {
        if (context) {
            if (started) xmp_end_player(context);
            xmp_release_module(context);
            xmp_free_context(context);
        }
    }
    LoadedModule() = default;
    LoadedModule(const LoadedModule&) = delete;
    LoadedModule& operator=(const LoadedModule&) = delete;
};

bool readFile(const char* path, std::vector<uint8_t>* out) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return false;
    const std::streamoff size = f.tellg();
    if (size <= 0) return false;
    out->resize(static_cast<size_t>(size));
    f.seekg(0, std::ios::beg);
    return static_cast<bool>(f.read(reinterpret_cast<char*>(out->data()), size));
}

bool loadModule(const std::vector<uint8_t>& bytes, LoadedModule* out) {
    out->context = xmp_create_context();
    if (!out->context) return false;
    if (xmp_load_module_from_memory(out->context, bytes.data(),
                                    static_cast<long>(bytes.size())) != 0) {
        return false;
    }
    return true;
}

std::string cleanString(const char* text, size_t capacity) {
    std::string out;
    for (size_t i = 0; i < capacity && text[i] != '\0'; ++i) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        if (c >= 0x20 && c < 0x7f) out.push_back(static_cast<char>(c));
        else out.push_back('?');
    }
    return out;
}

std::string hex64(uint64_t value) {
    std::ostringstream s;
    s << std::uppercase << std::hex << std::setw(16) << std::setfill('0') << value;
    return s.str();
}

std::string hexBytes(const unsigned char* bytes, size_t count) {
    std::ostringstream s;
    s << std::uppercase << std::hex << std::setfill('0');
    for (size_t i = 0; i < count; ++i)
        s << std::setw(2) << static_cast<unsigned>(bytes[i]);
    return s.str();
}

int patternRows(const xmp_module* mod, int pattern) {
    if (pattern < 0 || pattern >= mod->pat || !mod->xxp[pattern]) return 0;
    return mod->xxp[pattern]->rows;
}

int trackIndex(const xmp_module* mod, int pattern, int channel) {
    if (pattern < 0 || pattern >= mod->pat || !mod->xxp[pattern]) return -1;
    return mod->xxp[pattern]->index[channel];
}

const xmp_event* eventAt(const xmp_module* mod, int pattern, int channel, int row) {
    const int track = trackIndex(mod, pattern, channel);
    if (track < 0 || track >= mod->trk || !mod->xxt[track]) return nullptr;
    if (row < 0 || row >= mod->xxt[track]->rows) return nullptr;
    return &mod->xxt[track]->event[row];
}

void appendEffectStats(std::ostringstream& report,
                       const char* label,
                       const std::map<unsigned, EffectStat>& stats) {
    for (const auto& [effect, stat] : stats) {
        report << label << " effect=0x" << std::uppercase << std::hex
               << std::setw(2) << std::setfill('0') << effect << std::dec
               << " count=" << stat.count
               << " param_min=" << static_cast<unsigned>(stat.minParam)
               << " param_max=" << static_cast<unsigned>(stat.maxParam) << '\n';
    }
}

bool writeInventory(const xmp_module* mod,
                    const std::vector<uint8_t>& moduleBytes,
                    std::ostringstream& report) {
    Fnv64 moduleHash;
    moduleHash.add(moduleBytes.data(), moduleBytes.size());

    report << "ORACLE_VERSION=1\n";
    report << "MODULE_BYTES=" << moduleBytes.size() << '\n';
    report << "MODULE_FNV1A64=" << hex64(moduleHash.value) << '\n';
    report << "MODULE_NAME=\"" << cleanString(mod->name, sizeof mod->name) << "\"\n";
    report << "MODULE_TYPE=\"" << cleanString(mod->type, sizeof mod->type) << "\"\n";
    report << "PATTERNS=" << mod->pat << " TRACKS=" << mod->trk
           << " CHANNELS=" << mod->chn << " INSTRUMENTS=" << mod->ins
           << " SAMPLES=" << mod->smp << " ORDERS=" << mod->len << '\n';
    report << "INITIAL_SPEED=" << mod->spd << " INITIAL_BPM=" << mod->bpm
           << " RESTART_ORDER=" << mod->rst << " GLOBAL_VOLUME=" << mod->gvl << '\n';

    int rowsPerLoop = 0;
    report << "ORDER_TABLE=";
    for (int order = 0; order < mod->len; ++order) {
        if (order) report << ',';
        const int pattern = mod->xxo[order];
        report << static_cast<unsigned>(mod->xxo[order]);
        rowsPerLoop += patternRows(mod, pattern);
    }
    report << '\n';
    report << "PATTERN_ROWS=";
    for (int pattern = 0; pattern < mod->pat; ++pattern) {
        if (pattern) report << ',';
        report << patternRows(mod, pattern);
    }
    report << '\n';
    report << "ROWS_PER_ORDER_LOOP=" << rowsPerLoop
           << " MODPOS_PER_LOOP=" << (rowsPerLoop * 4) << '\n';

    std::map<unsigned, EffectStat> primary;
    std::map<unsigned, EffectStat> secondary;
    uint64_t noteCount = 0;
    uint64_t instrumentCount = 0;
    uint64_t volumeCount = 0;
    uint64_t populatedEvents = 0;
    for (int pattern = 0; pattern < mod->pat; ++pattern) {
        const int rows = patternRows(mod, pattern);
        for (int row = 0; row < rows; ++row) {
            for (int channel = 0; channel < mod->chn; ++channel) {
                const xmp_event* e = eventAt(mod, pattern, channel, row);
                if (!e) continue;
                if (e->note) ++noteCount;
                if (e->ins) ++instrumentCount;
                if (e->vol) ++volumeCount;
                if (e->note || e->ins || e->vol || e->fxt || e->fxp || e->f2t || e->f2p)
                    ++populatedEvents;
                if (e->fxt) primary[static_cast<unsigned>(e->fxt)].add(e->fxp);
                if (e->f2t) secondary[static_cast<unsigned>(e->f2t)].add(e->f2p);
            }
        }
    }
    report << "EVENTS_POPULATED=" << populatedEvents
           << " NOTES=" << noteCount
           << " INSTRUMENTS_REFERENCED=" << instrumentCount
           << " VOLUMES=" << volumeCount << '\n';
    appendEffectStats(report, "PRIMARY_EFFECT", primary);
    appendEffectStats(report, "SECONDARY_EFFECT", secondary);

    for (int sample = 0; sample < mod->smp; ++sample) {
        const xmp_sample& s = mod->xxs[sample];
        report << "SAMPLE index=" << sample
               << " length=" << s.len
               << " loop_start=" << s.lps
               << " loop_end=" << s.lpe
               << " flags=0x" << std::uppercase << std::hex << s.flg << std::dec << '\n';
    }
    return true;
}

bool renderPcm(xmp_context context,
               int totalTimeMs,
               std::ostringstream& report) {
    if (xmp_start_player(context, kSampleRate, 0) != 0) return false;

    const uint64_t targetFrames =
        (static_cast<uint64_t>(std::max(totalTimeMs, 1)) * kSampleRate + 999) / 1000;
    std::vector<int16_t> pcm(static_cast<size_t>(kChunkFrames) * kChannels);
    Fnv64 all;
    Fnv64 firstSecond;
    Fnv64 firstTenSeconds;
    uint64_t nonZero = 0;
    uint64_t sumAbs = 0;
    int peak = 0;
    uint64_t framesRendered = 0;
    while (framesRendered < targetFrames) {
        const int frames = static_cast<int>(std::min<uint64_t>(kChunkFrames,
                                                               targetFrames - framesRendered));
        if (xmp_play_buffer(context, pcm.data(), frames * kBytesPerFrame, 0) != 0)
            return false;
        const size_t bytes = static_cast<size_t>(frames) * kBytesPerFrame;
        all.add(pcm.data(), bytes);

        const uint64_t begin = framesRendered;
        const uint64_t end = framesRendered + static_cast<uint64_t>(frames);
        const uint64_t firstSecondEnd = std::min<uint64_t>(end, kSampleRate);
        if (begin < firstSecondEnd) {
            const size_t offset = 0;
            const size_t count = static_cast<size_t>(firstSecondEnd - begin) * kBytesPerFrame;
            firstSecond.add(reinterpret_cast<const uint8_t*>(pcm.data()) + offset, count);
        }
        const uint64_t tenSecondEnd = std::min<uint64_t>(end, kSampleRate * 10ull);
        if (begin < tenSecondEnd) {
            const size_t offset = 0;
            const size_t count = static_cast<size_t>(tenSecondEnd - begin) * kBytesPerFrame;
            firstTenSeconds.add(reinterpret_cast<const uint8_t*>(pcm.data()) + offset, count);
        }

        for (int i = 0; i < frames * kChannels; ++i) {
            const int sample = pcm[static_cast<size_t>(i)];
            const int magnitude = sample < 0 ? -sample : sample;
            if (sample != 0) ++nonZero;
            sumAbs += static_cast<uint64_t>(magnitude);
            peak = std::max(peak, magnitude);
        }
        framesRendered += static_cast<uint64_t>(frames);
    }
    xmp_end_player(context);

    report << "PCM_RATE=" << kSampleRate << " PCM_CHANNELS=" << kChannels
           << " PCM_BITS=16\n";
    report << "PCM_TOTAL_TIME_MS=" << totalTimeMs
           << " PCM_FRAMES=" << framesRendered << '\n';
    report << "PCM_FNV1A64=" << hex64(all.value)
           << " PCM_FIRST_1S_FNV1A64=" << hex64(firstSecond.value)
           << " PCM_FIRST_10S_FNV1A64=" << hex64(firstTenSeconds.value) << '\n';
    report << "PCM_NONZERO_SAMPLES=" << nonZero
           << " PCM_SUM_ABS=" << sumAbs
           << " PCM_PEAK_ABS=" << peak << '\n';
    return true;
}

bool traceRows(xmp_context context,
               int totalTimeMs,
               std::ostringstream& report) {
    if (xmp_start_player(context, kSampleRate, 0) != 0) return false;

    Fnv64 traceHash;
    int replayFrames = 0;
    int transitions = 0;
    int lastPos = -1;
    int lastPattern = -1;
    int lastRow = -1;
    xmp_frame_info fi{};
    while (replayFrames < 1000000 && xmp_play_frame(context) == 0) {
        xmp_get_frame_info(context, &fi);
        if (fi.pos != lastPos || fi.pattern != lastPattern || fi.row != lastRow) {
            std::ostringstream line;
            line << "TRACE frame=" << replayFrames
                 << " time_ms=" << fi.time
                 << " pos=" << fi.pos
                 << " pattern=" << fi.pattern
                 << " row=" << fi.row
                 << " rows=" << fi.num_rows
                 << " speed=" << fi.speed
                 << " bpm=" << fi.bpm
                 << " frame_time_us=" << fi.frame_time << '\n';
            const std::string text = line.str();
            report << text;
            traceHash.add(text.data(), text.size());
            lastPos = fi.pos;
            lastPattern = fi.pattern;
            lastRow = fi.row;
            ++transitions;
        }
        ++replayFrames;
        if (fi.time >= totalTimeMs || fi.loop_count > 0) break;
    }
    xmp_end_player(context);
    report << "TRACE_REPLAY_FRAMES=" << replayFrames
           << " TRACE_TRANSITIONS=" << transitions
           << " TRACE_FNV1A64=" << hex64(traceHash.value) << '\n';
    return replayFrames > 0 && transitions > 0;
}

bool writeReport(const char* path, const std::string& text) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(text.data(), static_cast<std::streamsize>(text.size()));
    return static_cast<bool>(f);
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: audio_oracle <module.mod> <report.txt>\n";
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!readFile(argv[1], &bytes)) {
        std::cerr << "audio_oracle: cannot read module: " << argv[1] << '\n';
        return 1;
    }

    LoadedModule inventory;
    inventory.bytes = bytes;
    if (!loadModule(bytes, &inventory)) {
        std::cerr << "audio_oracle: libxmp could not load module\n";
        return 1;
    }
    xmp_module_info moduleInfo{};
    xmp_get_module_info(inventory.context, &moduleInfo);
    if (!moduleInfo.mod) {
        std::cerr << "audio_oracle: libxmp returned no module\n";
        return 1;
    }

    std::ostringstream report;
    report << "ORACLE_MODULE_PATH=\"" << argv[1] << "\"\n";
    report << "MODULE_LIBXMP_MD5=" << hexBytes(moduleInfo.md5, sizeof moduleInfo.md5) << '\n';
    writeInventory(moduleInfo.mod, bytes, report);

    const int totalTimeMs = [&]() {
        xmp_context probe = xmp_create_context();
        if (!probe || xmp_load_module_from_memory(probe, bytes.data(),
                                                  static_cast<long>(bytes.size())) != 0) {
            if (probe) xmp_free_context(probe);
            return 0;
        }
        xmp_frame_info fi{};
        xmp_start_player(probe, kSampleRate, 0);
        xmp_get_frame_info(probe, &fi);
        xmp_end_player(probe);
        xmp_release_module(probe);
        xmp_free_context(probe);
        return fi.total_time;
    }();
    if (totalTimeMs <= 0) {
        std::cerr << "audio_oracle: libxmp did not provide total module time\n";
        return 1;
    }
    report << "LIBXMP_TOTAL_TIME_MS=" << totalTimeMs << '\n';

    LoadedModule pcm;
    pcm.bytes = bytes;
    LoadedModule trace;
    trace.bytes = bytes;
    if (!loadModule(bytes, &pcm) || !loadModule(bytes, &trace)) {
        std::cerr << "audio_oracle: could not create playback contexts\n";
        return 1;
    }
    if (!renderPcm(pcm.context, totalTimeMs, report) ||
        !traceRows(trace.context, totalTimeMs, report)) {
        std::cerr << "audio_oracle: libxmp playback oracle failed\n";
        return 1;
    }

    const xmp_module* mod = moduleInfo.mod;
    bool pass = bytes.size() == 381890 && mod->chn == 14 && mod->len == 42 &&
                mod->ins == 31 && mod->pat == 39;
    report << "ORACLE_EXPECTED_MODULE=bytes:381890 channels:14 orders:42 instruments:31 patterns:39\n";
    report << "ORACLE_STATUS=" << (pass ? "PASS" : "FAIL") << '\n';
    if (!writeReport(argv[2], report.str())) {
        std::cerr << "audio_oracle: cannot write report: " << argv[2] << '\n';
        return 1;
    }

    std::cout << "audio_oracle: " << (pass ? "PASS" : "FAIL")
              << " module_bytes=" << bytes.size()
              << " channels=" << mod->chn
              << " orders=" << mod->len
              << " patterns=" << mod->pat
              << " instruments=" << mod->ins
              << " total_ms=" << totalTimeMs << '\n';
    return pass ? 0 : 1;
}
