// embedded_payload_check.cpp - prove the final PE contains one compressed
// payload and that its two XZ streams decode byte-for-byte to the canonicals.

#include <cstdint>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

extern "C" int voodka_xz_decode(const unsigned char*, unsigned int,
                                 unsigned char*, unsigned int);

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
    if (argc != 5) {
        std::fprintf(stderr,
                     "usage: embedded_payload_check <exe> <vodka.dat> <mod> <payload>\n");
        return 2;
    }

    std::vector<uint8_t> image;
    std::vector<uint8_t> archive;
    std::vector<uint8_t> module;
    std::vector<uint8_t> payload;
    if (!readBytes(argv[1], image) || !readBytes(argv[2], archive) ||
        !readBytes(argv[3], module) || !readBytes(argv[4], payload)) {
        std::fprintf(stderr, "cannot read PE or canonical payload\n");
        return 3;
    }

    const size_t archiveCount = countOccurrences(image, archive);
    const size_t moduleCount = countOccurrences(image, module);
    const size_t payloadCount = countOccurrences(image, payload);
    std::printf("embedded payloads: compressed=%zu raw_archive=%zu raw_module=%zu\n",
                payloadCount, archiveCount, moduleCount);
    if (payloadCount != 1 || archiveCount != 0 || moduleCount != 0) {
        std::fprintf(stderr,
                     "expected one compressed container and no raw asset copies\n");
        return 1;
    }

    if (payload.size() < 48 || payload[0] != 'V' || payload[1] != 'P' ||
        payload[2] != 'K' || payload[3] != '1') {
        std::fprintf(stderr, "invalid VPK1 header\n");
        return 4;
    }
    auto u32 = [&payload](size_t offset) -> uint32_t {
        return uint32_t(payload[offset]) |
               (uint32_t(payload[offset + 1]) << 8) |
               (uint32_t(payload[offset + 2]) << 16) |
               (uint32_t(payload[offset + 3]) << 24);
    };
    if (payload[4] != 1 || payload[5] != 0 || payload[6] != 1 ||
        payload[7] != 0 || u32(8) != 2 || u32(12) != 48 ||
        u32(12) > payload.size()) {
        std::fprintf(stderr, "invalid VPK1 metadata\n");
        return 5;
    }

    for (unsigned int i = 0; i != 2; ++i) {
        const size_t entry = 16 + i * 16;
        const uint32_t id = u32(entry);
        const uint32_t originalSize = u32(entry + 4);
        const uint32_t offset = u32(entry + 8);
        const uint32_t compressedSize = u32(entry + 12);
        const std::vector<uint8_t>& expected = id == 1 ? archive : module;
        if (id != i + 1 || originalSize != expected.size() ||
            offset < 48 || offset > payload.size() ||
            compressedSize > payload.size() - offset) {
            std::fprintf(stderr, "invalid VPK1 entry %u\n", i);
            return 6;
        }
        std::vector<uint8_t> decoded(expected.size());
        const auto start = std::chrono::steady_clock::now();
        const bool decodedOk =
            voodka_xz_decode(payload.data() + offset, compressedSize,
                             decoded.data(), originalSize) != 0;
        const auto elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start);
        std::printf("VPK1 asset %u: %.3f ms, output=%u bytes\n", id,
                    elapsed.count(), originalSize);
        if (!decodedOk || decoded != expected) {
            std::fprintf(stderr, "decoded asset %u differs from canonical bytes\n", id);
            return 7;
        }
    }
    std::printf("VPK1 decode OK: archive=%zu module=%zu container=%zu\n",
                archive.size(), module.size(), payload.size());
    return 0;
}
