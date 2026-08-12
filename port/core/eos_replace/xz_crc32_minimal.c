/* xz_crc32_minimal.c - the single CRC32 primitive required by XZ streams. */

#include <stddef.h>
#include <stdint.h>

uint32_t libxmp_crc32_A(const uint8_t *buf, size_t size, uint32_t crc) {
    crc = ~crc;
    while (size--) {
        crc ^= *buf++;
        for (unsigned bit = 0; bit != 8; ++bit)
            crc = (crc >> 1) ^
                  (0xEDB88320u & (uint32_t)-(int)(crc & 1u));
    }
    return ~crc;
}
