// audio_mod_trace_probe.cpp - NASM tracker timeline vs libxmp.

#include "audio_mod_abi.h"
#include "audio_tracker_abi.h"
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

bool same(const AudioTraceEntry& a, const AudioTraceEntry& b) {
    return a.frame == b.frame && a.timeMs == b.timeMs &&
           a.position == b.position && a.pattern == b.pattern &&
           a.row == b.row && a.rows == b.rows && a.speed == b.speed &&
           a.bpm == b.bpm && a.frameTimeUs == b.frameTimeUs;
}

void printEntry(const char* label, const AudioTraceEntry& e) {
    std::cerr << label << " frame=" << e.frame
              << " time_ms=" << e.timeMs
              << " pos=" << e.position
              << " pattern=" << e.pattern
              << " row=" << e.row
              << " rows=" << e.rows
              << " speed=" << e.speed
              << " bpm=" << e.bpm
              << " frame_time_us=" << e.frameTimeUs << '\n';
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_mod_trace_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> bytes;
    if (!readFile(argv[1], &bytes)) {
        std::cerr << "audio_mod_trace_probe: cannot read module\n";
        return 1;
    }

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(bytes.data(), static_cast<uint32_t>(bytes.size()), &summary) != 0 ||
        summary.status != 0) {
        std::cerr << "audio_mod_trace_probe: NASM parser failed\n";
        return 1;
    }

    const uint32_t expectedRows = summary.rowsPerLoop;
    std::vector<AudioTraceEntry> got(expectedRows);
    const uint32_t gotCount = asm_audio_trace_rows(
        bytes.data(), static_cast<uint32_t>(bytes.size()), got.data(), expectedRows);
    if (gotCount != expectedRows) {
        std::cerr << "audio_mod_trace_probe: NASM trace count=" << gotCount
                  << " expected=" << expectedRows << '\n';
        return 1;
    }

    xmp_context context = xmp_create_context();
    if (!context || xmp_load_module_from_memory(context, bytes.data(),
                                                static_cast<long>(bytes.size())) != 0) {
        if (context) xmp_free_context(context);
        std::cerr << "audio_mod_trace_probe: libxmp load failed\n";
        return 1;
    }
    xmp_module_info info{};
    xmp_get_module_info(context, &info);
    if (!info.mod || xmp_start_player(context, 44100, 0) != 0) {
        xmp_release_module(context);
        xmp_free_context(context);
        std::cerr << "audio_mod_trace_probe: libxmp start failed\n";
        return 1;
    }

    std::vector<AudioTraceEntry> expected;
    expected.reserve(expectedRows);
    int lastPos = -1;
    int lastPattern = -1;
    int lastRow = -1;
    uint32_t replayFrame = 0;
    xmp_frame_info frame{};
    while (expected.size() < expectedRows && xmp_play_frame(context) == 0) {
        xmp_get_frame_info(context, &frame);
        if (frame.pos != lastPos || frame.pattern != lastPattern || frame.row != lastRow) {
            expected.push_back(AudioTraceEntry{
                replayFrame,
                static_cast<uint32_t>(frame.time),
                static_cast<uint32_t>(frame.pos),
                static_cast<uint32_t>(frame.pattern),
                static_cast<uint32_t>(frame.row),
                static_cast<uint32_t>(frame.num_rows),
                static_cast<uint32_t>(frame.speed),
                static_cast<uint32_t>(frame.bpm),
                static_cast<uint32_t>(frame.frame_time),
            });
            lastPos = frame.pos;
            lastPattern = frame.pattern;
            lastRow = frame.row;
        }
        ++replayFrame;
        if (frame.loop_count > 0) break;
    }

    int mismatch = -1;
    const size_t count = expected.size() < got.size() ? expected.size() : got.size();
    for (size_t i = 0; i < count; ++i) {
        if (!same(got[i], expected[i])) {
            mismatch = static_cast<int>(i);
            break;
        }
    }
    if (mismatch < 0 && expected.size() != got.size())
        mismatch = static_cast<int>(count);

    xmp_end_player(context);
    xmp_release_module(context);
    xmp_free_context(context);

    if (mismatch >= 0) {
        std::cerr << "audio_mod_trace_probe: FAIL mismatch=" << mismatch
                  << " expected_count=" << expected.size()
                  << " got_count=" << got.size() << '\n';
        if (static_cast<size_t>(mismatch) < expected.size())
            printEntry("expected", expected[static_cast<size_t>(mismatch)]);
        if (static_cast<size_t>(mismatch) < got.size())
            printEntry("got", got[static_cast<size_t>(mismatch)]);
        return 1;
    }

    std::cout << "audio_mod_trace_probe: PASS rows=" << got.size()
              << " frames=" << got.back().frame + got.back().speed
              << " final_time_ms=" << got.back().timeMs << '\n';
    return 0;
}
