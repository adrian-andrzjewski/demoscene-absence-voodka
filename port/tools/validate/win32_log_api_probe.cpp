// win32_log_api_probe.cpp - production vk::logPrint ABI witness.

#include "platform_abi.h"

int main() {
    vk::logInit();
    vk::logPrint("[win32_log_api_probe] literal\n");
    vk::logPrint("[win32_log_api_probe] %d %s %08x\n", -17, "text", 0x2a);
    vk::logPrint("[win32_log_api_probe] %.2f %+.0f %.3f\n",
                 1.234, -2.6, 0.9995);
    vk::logShutdown();
    return 0;
}
