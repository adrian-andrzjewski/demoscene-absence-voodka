// win32_input_abi_probe.cpp - decorated vk:: input ABI witness.

#include "platform_abi.h"

#include <cstdint>

extern "C" void vk_request_quit() {
    vk::requestQuit();
}

int main() {
    if (!vk::inputInit(nullptr)) return 1;

    vk::keyReset();
    auto* keys = vk::rawKeyMap();
    if (!keys) return 2;
    for (int i = 0; i < 128; ++i) {
        if (keys[i] != 0 || vk::isKeyDown(i) != 0) return 3;
    }

    vk::keyDown(static_cast<uint8_t>(42));
    if (keys[42] != 1 || vk::isKeyDown(42) != 1) return 4;
    vk::keyUp(static_cast<uint8_t>(42));
    if (keys[42] != 0 || vk::isKeyDown(42) != 0) return 5;

    vk::clearEscapeQueue();
    if (vk::escapeQueued()) return 6;
    vk::keyDown(static_cast<uint8_t>(1));
    if (!vk::escapeQueued() || !vk::quitRequested()) return 7;

    vk::inputShutdown();
    vk::inputShutdown();
    return 0;
}
