// embedded_payload_check.cpp - prove the final PE contains the canonical
// runtime payloads exactly once.

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

static bool readBytes(const char* path, std::vector<uint8_t>& bytes) {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in) return false;
    const std::streamoff size = in.tellg();
    if (size <= 0) return false;
    in.seekg(0, std::ios::beg);
    bytes.resize(static_cast<size_t>(size));
    in.read(reinterpret_cast<char*>(bytes.data()), size);
    return in.good() || in.eof();
}

static size_t countOccurrences(const std::vector<uint8_t>& haystack,
                               const std::vector<uint8_t>& needle) {
    if (needle.empty() || needle.size() > haystack.size()) return 0;
    size_t count = 0;
    for (size_t i = 0; i + needle.size() <= haystack.size();) {
        bool equal = true;
        for (size_t j = 0; j < needle.size(); ++j) {
            if (haystack[i + j] != needle[j]) {
                equal = false;
                break;
            }
        }
        if (equal) {
            ++count;
            i += needle.size();
        } else {
            ++i;
        }
    }
    return count;
}

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr,
                     "usage: embedded_payload_check <exe> <vodka.dat> <mod>\n");
        return 2;
    }

    std::vector<uint8_t> image;
    std::vector<uint8_t> archive;
    std::vector<uint8_t> module;
    if (!readBytes(argv[1], image) || !readBytes(argv[2], archive) ||
        !readBytes(argv[3], module)) {
        std::fprintf(stderr, "cannot read PE or canonical payload\n");
        return 3;
    }

    const size_t archiveCount = countOccurrences(image, archive);
    const size_t moduleCount = countOccurrences(image, module);
    std::printf("embedded payloads: archive=%zu module=%zu\n",
                archiveCount, moduleCount);
    if (archiveCount != 1 || moduleCount != 1) {
        std::fprintf(stderr,
                     "expected exactly one byte-exact archive and module in PE\n");
        return 1;
    }
    return 0;
}
