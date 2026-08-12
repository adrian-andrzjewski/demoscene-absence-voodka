// presentation_layout_test.cpp - deterministic integer-scaling geometry gate.

#include "presentation_layout.h"

#include <cstdio>

namespace {

bool check(const vk::PresentationLayout& actual, int x, int y, int width,
           int height, int scale, const char* name) {
    if (actual.x == x && actual.y == y && actual.width == width &&
        actual.height == height && actual.scale == scale)
        return true;
    std::fprintf(stderr,
                 "%s: got {%d,%d %dx%d scale=%d}, expected {%d,%d %dx%d "
                 "scale=%d}\n",
                 name, actual.x, actual.y, actual.width, actual.height,
                 actual.scale, x, y, width, height, scale);
    return false;
}

} // namespace

int main() {
    bool ok = true;
    ok &= check(vk::computePresentationLayout(1280, 800),
                0, 0, 1280, 800, 4, "windowed");
    ok &= check(vk::computePresentationLayout(1920, 1080),
                160, 40, 1600, 1000, 5, "1080p");
    ok &= check(vk::computePresentationLayout(2560, 1440),
                160, 20, 2240, 1400, 7, "larger-16-9");
    ok &= check(vk::computePresentationLayout(1920, 1200),
                0, 0, 1920, 1200, 6, "five-four-output");
    ok &= !vk::computePresentationLayout(319, 200).valid();
    ok &= !vk::computePresentationLayout(320, 199).valid();
    return ok ? 0 : 1;
}
