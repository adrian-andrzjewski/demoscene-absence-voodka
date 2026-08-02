// frames2img.cpp - converts recorded frames (320x200x8 + 768-byte palette per
// frame, as written by VOODKA --record) into PNG images for visual validation.
// Uses a minimal, dependency-free PNG encoder (zlib deflate via raw store).
//
// Usage: frames2img <frames.raw> <outdir> [startFrame] [numFrames]

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

static uint32_t crc32(const uint8_t* data, size_t n) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < n; i++) {
        crc ^= data[i];
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
    return ~crc;
}

static void put32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((uint8_t)(x >> 24)); v.push_back((uint8_t)(x >> 16));
    v.push_back((uint8_t)(x >> 8));  v.push_back((uint8_t)x);
}

// minimal PNG: 8-bit RGB, zlib "stored" (uncompressed) deflate blocks
static void writePng(const char* path, const uint8_t* rgb, int w, int h) {
    std::vector<uint8_t> img, png;
    // filter type 0 before each row
    for (int y = 0; y < h; y++) {
        img.push_back(0);
        img.insert(img.end(), rgb + (size_t)y * w * 3, rgb + (size_t)(y + 1) * w * 3);
    }
    // zlib header
    png.push_back(0x78); png.push_back(0x01);
    // deflate stored blocks
    size_t pos = 0;
    do {
        size_t chunk = img.size() - pos < 65535 ? img.size() - pos : 65535;
        int final = (pos + chunk == img.size()) ? 1 : 0;
        png.push_back((uint8_t)(final & 1));
        png.push_back((uint8_t)(chunk & 0xFF));
        png.push_back((uint8_t)((chunk >> 8) & 0xFF));
        png.push_back((uint8_t)(~(chunk & 0xFF) & 0xFF));
        png.push_back((uint8_t)(~((chunk >> 8) & 0xFF) & 0xFF));
        png.insert(png.end(), img.begin() + pos, img.begin() + pos + chunk);
        pos += chunk;
    } while (pos < img.size());
    // adler32
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < img.size(); i++) { a = (a + img[i]) % 65521; b = (b + a) % 65521; }
    uint32_t adler = (b << 16) | a;
    put32(png, adler);

    // png container
    std::vector<uint8_t> out;
    static const uint8_t sig[8] = {0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A};
    out.insert(out.end(), sig, sig + 8);
    auto chunk = [&](const char* type, const std::vector<uint8_t>& data) {
        put32(out, (uint32_t)data.size());
        out.insert(out.end(), type, type + 4);
        out.insert(out.end(), data.begin(), data.end());
        std::vector<uint8_t> t(type, type + 4);
        t.insert(t.end(), data.begin(), data.end());
        put32(out, crc32(t.data(), t.size()));
    };
    std::vector<uint8_t> ihdr;
    put32(ihdr, (uint32_t)w); put32(ihdr, (uint32_t)h);
    ihdr.push_back(8); ihdr.push_back(2); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    chunk("IHDR", ihdr);
    chunk("IDAT", png);
    chunk("IEND", {});
    FILE* f = fopen(path, "wb");
    if (f) { fwrite(out.data(), 1, out.size(), f); fclose(f); }
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: frames2img <frames.raw> <outdir> [start] [num]\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    const int frameSize = 320 * 200 + 768;
    int total = (int)(sz / frameSize);
    int start = argc > 3 ? atoi(argv[3]) : 0;
    int num = argc > 4 ? atoi(argv[4]) : total - start;
    long offset = (long)start * frameSize;
    fseek(f, offset, SEEK_SET);

    int w = 320, h = 200;
    std::vector<uint8_t> idx(320 * 200), pal(768), rgb(320 * 200 * 3);
    std::string outdir = argv[2];
    for (int n = 0; n < num && n < total - start; n++) {
        if (fread(idx.data(), 1, 320 * 200, f) != (size_t)320 * 200) break;
        if (fread(pal.data(), 1, 768, f) != 768) break;
        for (int i = 0; i < 320 * 200; i++) {
            int c = idx[i];
            rgb[i * 3 + 0] = (uint8_t)((pal[c*3+0] * 255 + 31) / 63);
            rgb[i * 3 + 1] = (uint8_t)((pal[c*3+1] * 255 + 31) / 63);
            rgb[i * 3 + 2] = (uint8_t)((pal[c*3+2] * 255 + 31) / 63);
        }
        char p[512];
        snprintf(p, sizeof p, "%s\\frame_%05d.png", outdir.c_str(), start + n);
        writePng(p, rgb.data(), w, h);
        if ((n & 15) == 0) printf("wrote %s\n", p);
    }
    fclose(f);
    printf("done: %d frames -> %s\n", num, outdir.c_str());
    return 0;
}
