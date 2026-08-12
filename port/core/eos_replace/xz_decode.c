/* xz_decode.c - bounded single-call XZ/LZMA2 asset decode entrypoint. */

#include "xz_decoder_runtime.h"

static unsigned int voodka_read_u32(const unsigned char *p) {
    return (unsigned int)p[0] |
           ((unsigned int)p[1] << 8) |
           ((unsigned int)p[2] << 16) |
           ((unsigned int)p[3] << 24);
}

int voodka_xz_decode(const unsigned char *input, unsigned int input_size,
                     unsigned char *output, unsigned int output_size) {
    struct xz_dec *decoder;
    struct xz_buf buffer;
    enum xz_ret result;

    if (!input || !output || input_size == 0 || output_size == 0)
        return 0;

    voodka_xz_workspace_reset();
    decoder = xz_dec_init(XZ_SINGLE, 0);
    if (!decoder) return 0;

    buffer.in = input;
    buffer.in_pos = 0;
    buffer.in_size = input_size;
    buffer.out = output;
    buffer.out_pos = 0;
    buffer.out_size = output_size;
    result = xz_dec_run(decoder, &buffer);
    xz_dec_end(decoder);

    return result == XZ_STREAM_END &&
           buffer.in_pos == input_size && buffer.out_pos == output_size;
}

/*
 * Decode one VPK1 entry.  The container is intentionally tiny and private:
 * the XZ stream supplies its own CRC32, while this header supplies bounded
 * offsets and the exact destination size.
 */
int voodka_decode_embedded_asset(unsigned int asset_id,
                                 const unsigned char *payload,
                                 unsigned int payload_size,
                                 unsigned char *output,
                                 unsigned int output_size) {
    unsigned int entry_count;
    unsigned int header_size;

    if (!payload || !output || payload_size < 16u) return 0;
    if (payload[0] != 'V' || payload[1] != 'P' ||
        payload[2] != 'K' || payload[3] != '1') return 0;
    if (payload[4] != 1 || payload[5] != 0 ||
        payload[6] != 1 || payload[7] != 0) return 0;
    entry_count = voodka_read_u32(payload + 8);
    header_size = voodka_read_u32(payload + 12);
    if (entry_count != 2u || header_size != 48u || header_size > payload_size)
        return 0;

    for (unsigned int i = 0; i < entry_count; ++i) {
        const unsigned char *entry = payload + 16u + i * 16u;
        const unsigned int id = voodka_read_u32(entry + 0);
        const unsigned int original_size = voodka_read_u32(entry + 4);
        const unsigned int compressed_offset = voodka_read_u32(entry + 8);
        const unsigned int compressed_size = voodka_read_u32(entry + 12);
        if (id != asset_id) continue;
        if (original_size != output_size ||
            compressed_offset < header_size ||
            compressed_offset > payload_size ||
            compressed_size > payload_size - compressed_offset)
            return 0;
        return voodka_xz_decode(payload + compressed_offset, compressed_size,
                                output, output_size);
    }
    return 0;
}
