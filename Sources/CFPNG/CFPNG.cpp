#include "CFPNG.h"
#include "vendor/fpng.h"
#include <algorithm>
#include <limits>
#include <new>
#include <stdexcept>
#include <vector>
#if defined(__aarch64__) || defined(__arm64__)
#include <arm_neon.h>
#endif

struct CFPNGContext {
    explicit CFPNGContext(size_t limit) : max_pixel_bytes(limit) {}
    size_t max_pixel_bytes;
    std::vector<uint8_t> rgba;
    std::vector<uint8_t> png;
};

namespace {
constexpr size_t max_pixel_bytes = 256u * 1024u * 1024u;
constexpr uint32_t max_dimension = 16384;

bool multiply(size_t a, size_t b, size_t& result) {
    if (b && a > std::numeric_limits<size_t>::max() / b) return false;
    result = a * b;
    return true;
}

bool swizzle_opaque(const uint8_t* source, uint8_t* destination,
                    uint32_t width, uint32_t height, size_t stride, bool ignore_alpha) {
    const size_t packed_row = static_cast<size_t>(width) * 4;
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t* row = source + static_cast<size_t>(y) * stride;
        uint8_t* out = destination + static_cast<size_t>(y) * packed_row;
        uint32_t x = 0;
#if defined(__aarch64__) || defined(__arm64__)
        for (; x + 16 <= width; x += 16) {
            auto channels = vld4q_u8(row + static_cast<size_t>(x) * 4);
            if (!ignore_alpha && vminvq_u8(channels.val[3]) != 255) return false;
            if (ignore_alpha) channels.val[3] = vdupq_n_u8(255);
            std::swap(channels.val[0], channels.val[2]);
            vst4q_u8(out + static_cast<size_t>(x) * 4, channels);
        }
#endif
        for (; x < width; ++x) {
            const size_t i = static_cast<size_t>(x) * 4;
            if (!ignore_alpha && row[i + 3] != 255) return false;
            out[i] = row[i + 2];
            out[i + 1] = row[i + 1];
            out[i + 2] = row[i];
            out[i + 3] = 255;
        }
    }
    return true;
}

void write_u32(uint8_t* out, uint32_t value) {
    out[0] = static_cast<uint8_t>(value >> 24);
    out[1] = static_cast<uint8_t>(value >> 16);
    out[2] = static_cast<uint8_t>(value >> 8);
    out[3] = static_cast<uint8_t>(value);
}
} // namespace

extern "C" CFPNGContext* cf_png_create(size_t limit) {
    if (!limit || limit > max_pixel_bytes) return nullptr;
    try {
        // FPNG_NO_SSE makes upstream initialization a no-op on every target.
        // Avoid mutable global CPU detection when independent encoders coexist.
        return new CFPNGContext(limit);
    } catch (...) { return nullptr; }
}

extern "C" void cf_png_destroy(CFPNGContext* context) { delete context; }

extern "C" void cf_png_reset(CFPNGContext* context) {
    if (!context) return;
    std::vector<uint8_t>().swap(context->rgba);
    std::vector<uint8_t>().swap(context->png);
}

extern "C" size_t cf_png_retained_bytes(const CFPNGContext* context) {
    return context ? context->rgba.capacity() + context->png.capacity() : 0;
}

extern "C" CFPNGResult cf_png_encode_bgra8(
    CFPNGContext* context, const uint8_t* pixels, size_t accessible_bytes,
    uint32_t width, uint32_t height, size_t stride, int alpha_is_ignored,
    const uint8_t** output, size_t* output_count) {
    if (output) *output = nullptr;
    if (output_count) *output_count = 0;
    if (!context || !pixels || !output || !output_count || !width || !height ||
        (alpha_is_ignored != 0 && alpha_is_ignored != 1))
        return CFPNG_INVALID_ARGUMENT;
    context->png.clear();
    if (width > max_dimension || height > max_dimension) return CFPNG_LIMIT_EXCEEDED;
    size_t packed_row, packed_bytes, last_row;
    if (!multiply(width, 4, packed_row) || !multiply(packed_row, height, packed_bytes))
        return CFPNG_LIMIT_EXCEEDED;
    if (packed_bytes > context->max_pixel_bytes) return CFPNG_LIMIT_EXCEEDED;
    if (stride < packed_row || !multiply(height - 1, stride, last_row) ||
        last_row > accessible_bytes || packed_row > accessible_bytes - last_row)
        return CFPNG_INVALID_ARGUMENT;
    try {
        context->rgba.resize(packed_bytes);
        if (!swizzle_opaque(pixels, context->rgba.data(), width, height, stride, alpha_is_ignored != 0))
            return CFPNG_UNSUPPORTED_ALPHA;
        if (!fpng::fpng_encode_image_to_memory(context->rgba.data(), width, height,
                                              4, context->png))
            return CFPNG_ENCODING_FAILED;
        // FPNG writes signature + IHDR first. Insert explicit color metadata
        // after IHDR; retain the standard PNG payload without another output copy.
        if (context->png.size() < 33) return CFPNG_ENCODING_FAILED;
        uint8_t srgb[13] = {0, 0, 0, 1, 's', 'R', 'G', 'B', 0, 0, 0, 0, 0};
        write_u32(srgb + 9, fpng::fpng_crc32(srgb + 4, 5));
        context->png.insert(context->png.begin() + 33, srgb, srgb + sizeof(srgb));
        // Upstream can fall back to uncompressed DEFLATE blocks. This bound
        // includes row filters, worst-case stored-block headers and PNG metadata.
        const size_t filtered_bytes = packed_bytes + height;
        const size_t output_bound = filtered_bytes +
            ((filtered_bytes + 65534) / 65535) * 5 + 256;
        if (context->png.size() > output_bound) return CFPNG_ENCODING_FAILED;
        *output = context->png.data();
        *output_count = context->png.size();
        return CFPNG_SUCCESS;
    } catch (const std::bad_alloc&) {
        cf_png_reset(context);
        return CFPNG_ALLOCATION_FAILED;
    } catch (const std::length_error&) {
        cf_png_reset(context);
        return CFPNG_LIMIT_EXCEEDED;
    } catch (...) {
        cf_png_reset(context);
        return CFPNG_ENCODING_FAILED;
    }
}
