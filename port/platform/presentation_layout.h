// presentation_layout.h - integer, aspect-preserving presentation geometry.

#pragma once

#include "platform_abi.h"

namespace vk {

struct PresentationLayout {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    int scale = 0;

    constexpr bool valid() const {
        return scale > 0 && width > 0 && height > 0;
    }
};

// Keep the 320x200 source pixels square, sharp, and evenly sized. The
// returned rectangle is the only region the D3D11 quad should draw into;
// callers clear the complete output first so the remainder stays black.
constexpr PresentationLayout computePresentationLayout(int outputWidth,
                                                        int outputHeight) {
    if (outputWidth < kScreenW || outputHeight < kScreenH)
        return {};

    const int scaleX = outputWidth / kScreenW;
    const int scaleY = outputHeight / kScreenH;
    const int scale = scaleX < scaleY ? scaleX : scaleY;
    const int contentWidth = kScreenW * scale;
    const int contentHeight = kScreenH * scale;
    return {
        (outputWidth - contentWidth) / 2,
        (outputHeight - contentHeight) / 2,
        contentWidth,
        contentHeight,
        scale,
    };
}

} // namespace vk
