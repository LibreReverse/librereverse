#ifndef LIBREREVERSE_CFPNG_H
#define LIBREREVERSE_CFPNG_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CFPNGContext CFPNGContext;
typedef enum CFPNGResult {
    CFPNG_SUCCESS = 0,
    CFPNG_INVALID_ARGUMENT = 1,
    CFPNG_UNSUPPORTED_ALPHA = 2,
    CFPNG_LIMIT_EXCEEDED = 3,
    CFPNG_ALLOCATION_FAILED = 4,
    CFPNG_ENCODING_FAILED = 5
} CFPNGResult;

/* Serial owner required. max_pixel_bytes bounds packed RGBA scratch (1..256MiB),
 * not total memory: output and upstream temporary filtering also consume memory.
 * Returns NULL for an invalid limit or allocation failure. */
CFPNGContext* cf_png_create(size_t max_pixel_bytes);
void cf_png_destroy(CFPNGContext* context);
/* Releases retained scratch. Invalidates any previously borrowed output. */
void cf_png_reset(CFPNGContext* context);
/* Retained vector capacities only; excludes upstream temporary allocations. */
size_t cf_png_retained_bytes(const CFPNGContext* context);

/* Input must be opaque, 8-bit BGRA, interpreted as sRGB by the caller.
 * alpha_is_ignored=1 is only for a caller-verified skip-alpha layout: the
 * fourth byte is ignored and output alpha becomes 255. Otherwise pass 0 and
 * every input alpha byte must be 255.
 * Stride padding is honored. accessible_bytes must cover every addressed pixel.
 * Input is read synchronously and is never retained or modified.
 * The output PNG includes an sRGB chunk. No file I/O occurs here.
 * On success output is borrowed, valid until the next encode/reset/destroy.
 * On failure outputs are cleared. C++ exceptions never cross this API.
 * No operations on one context may overlap, including reads of borrowed output. */
CFPNGResult cf_png_encode_bgra8(
    CFPNGContext* context, const uint8_t* pixels, size_t accessible_bytes,
    uint32_t width, uint32_t height, size_t bytes_per_row, int alpha_is_ignored,
    const uint8_t** output, size_t* output_count);
#ifdef __cplusplus
}
#endif
#endif
