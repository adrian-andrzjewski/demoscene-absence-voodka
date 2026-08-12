// win32_timeline_probe.cpp - byte-level witness for the production timeline.

#include "platform_abi.h"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>

namespace vk {

void logPrint(const char*, ...) {}
double audioElapsedSec() { return 1.25; }

}  // namespace vk

int main() {
    const char* path = "win32_timeline_probe.raw";
    vk::timelineInit(path);
    vk::timelineFrame(7, 123456789, 0x304);
    vk::timelineFrame(8, 123456790, 0x305);
    vk::timelineClose();

    std::ifstream file(path, std::ios::binary);
    const std::string actual((std::istreambuf_iterator<char>(file)),
                             std::istreambuf_iterator<char>());
    std::remove(path);

    const std::string expected =
        "# frame qpc_us modpos audio_elapsed_us\n"
        "7 123456789 772 1250000\n"
        "8 123456790 773 1250000\n";
    return actual == expected ? 0 : 1;
}
