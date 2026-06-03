/*
 * QEMU texture swizzling routines
 *
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2013 espes
 * Copyright (c) 2007-2010 The Nouveau Project.
 * Copyright (c) 2025 Matt Borgerson
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>

#include "swizzle.h"

/*
 * Helpers for converting to and from swizzled (Z-ordered) texture formats.
 * Swizzled textures store pixels in a more cache-friendly layout for rendering
 * than linear textures.
 * Width, height, and depth must be powers of two.
 * See also:
 * https://en.wikipedia.org/wiki/Z-order_curve
 */

/*
 * Create masks representing the interleaving of each linear texture dimension (x, y, z).
 * These can be used to map linear texture coordinates to a swizzled "Z" offset.
 * For example, a 2D 8x32 texture needs 3 bits for x, and 5 bits for y:
 * mask_x:  00010101
 * mask_y:  11101010
 * mask_z:  00000000
 * for "Z": yyyxyxyx
 */
static void generate_swizzle_masks(unsigned int width,
                                   unsigned int height,
                                   unsigned int depth,
                                   uint32_t* mask_x,
                                   uint32_t* mask_y,
                                   uint32_t* mask_z)
{
    uint32_t x = 0, y = 0, z = 0;
    uint32_t bit = 1;
    uint32_t mask_bit = 1;
    bool done;
    do {
        done = true;
        if (bit < width) { x |= mask_bit; mask_bit <<= 1; done = false; }
        if (bit < height) { y |= mask_bit; mask_bit <<= 1; done = false; }
        if (bit < depth) { z |= mask_bit; mask_bit <<= 1; done = false; }
        bit <<= 1;
    } while(!done);
    assert((x ^ y ^ z) == (mask_bit - 1)); /* masks are mutually exclusive */
    *mask_x = x;
    *mask_y = y;
    *mask_z = z;
}

static inline bool is_power_of_two(unsigned int value)
{
    return value && !(value & (value - 1));
}

/*
 * Keep common pixel copies as byte assignments. MSVC may otherwise leave the
 * hot inner loop with a small memcpy, and wider unaligned stores would make the
 * aliasing/alignment contract less clear.
 */
#define COPY_PIXEL_1(dst, src) \
    do { \
        (dst)[0] = (src)[0]; \
    } while (0)
#define COPY_PIXEL_2(dst, src) \
    do { \
        (dst)[0] = (src)[0]; \
        (dst)[1] = (src)[1]; \
    } while (0)
#define COPY_PIXEL_3(dst, src) \
    do { \
        (dst)[0] = (src)[0]; \
        (dst)[1] = (src)[1]; \
        (dst)[2] = (src)[2]; \
    } while (0)
#define COPY_PIXEL_4(dst, src) \
    do { \
        (dst)[0] = (src)[0]; \
        (dst)[1] = (src)[1]; \
        (dst)[2] = (src)[2]; \
        (dst)[3] = (src)[3]; \
    } while (0)

static inline void swizzle_box_internal(
    const uint8_t *src_buf,
    unsigned int width,
    unsigned int height,
    unsigned int depth,
    uint8_t *dst_buf,
    unsigned int row_pitch,
    unsigned int slice_pitch,
    unsigned int bytes_per_pixel)
{
    uint32_t mask_x, mask_y, mask_z;
    generate_swizzle_masks(width, height, depth, &mask_x, &mask_y, &mask_z);

    /*
     * Map linear texture to swizzled texture using swizzle masks.
     * https://fgiesen.wordpress.com/2011/01/17/texture-tiling-and-swizzling/
     */

    int x, y, z;
    int off_z = 0;
    for (z = 0; z < depth; z++) {
        int off_y = 0;
        for (y = 0; y < height; y++) {
            int off_x = 0;
            const uint8_t *src_tmp = src_buf + y * row_pitch;
            uint8_t *dst_tmp = dst_buf + (off_y + off_z) * bytes_per_pixel;
            for (x = 0; x < width; x++) {
                const uint8_t *src = src_tmp + x * bytes_per_pixel;
                uint8_t *dst = dst_tmp + off_x * bytes_per_pixel;
                memcpy(dst, src, bytes_per_pixel);

                /*
                 * Increment x offset, letting the increment
                 * ripple through bits that aren't in the mask.
                 * Equivalent to:
                 * off_x = (off_x + (~mask_x + 1)) & mask_x;
                 */
                off_x = (off_x - mask_x) & mask_x;
            }
            off_y = (off_y - mask_y) & mask_y;
        }
        src_buf += slice_pitch;
        off_z = (off_z - mask_z) & mask_z;
    }
}

#define DEFINE_SWIZZLE_BOX_INTERNAL(BPP)                                  \
    static inline void swizzle_box_internal_##BPP(                        \
        const uint8_t *src_buf,                                           \
        unsigned int width,                                               \
        unsigned int height,                                              \
        unsigned int depth,                                               \
        uint8_t *dst_buf,                                                 \
        unsigned int row_pitch,                                           \
        unsigned int slice_pitch)                                         \
    {                                                                     \
        uint32_t mask_x, mask_y, mask_z;                                  \
        generate_swizzle_masks(width, height, depth, &mask_x, &mask_y,    \
                               &mask_z);                                  \
                                                                          \
        unsigned int x, y, z;                                             \
        uint32_t off_z = 0;                                               \
        for (z = 0; z < depth; z++) {                                     \
            uint32_t off_y = 0;                                           \
            for (y = 0; y < height; y++) {                                \
                uint32_t off_x = 0;                                       \
                const uint8_t *src_tmp = src_buf + y * row_pitch;         \
                uint8_t *dst_tmp = dst_buf + (off_y + off_z) * (BPP);     \
                for (x = 0; x < width; x++) {                             \
                    const uint8_t *src = src_tmp + x * (BPP);             \
                    uint8_t *dst = dst_tmp + off_x * (BPP);               \
                    COPY_PIXEL_##BPP(dst, src);                           \
                                                                          \
                    off_x = (off_x - mask_x) & mask_x;                    \
                }                                                         \
                off_y = (off_y - mask_y) & mask_y;                        \
            }                                                             \
            src_buf += slice_pitch;                                       \
            off_z = (off_z - mask_z) & mask_z;                            \
        }                                                                 \
    }

DEFINE_SWIZZLE_BOX_INTERNAL(1)
DEFINE_SWIZZLE_BOX_INTERNAL(2)
DEFINE_SWIZZLE_BOX_INTERNAL(3)
DEFINE_SWIZZLE_BOX_INTERNAL(4)

#undef DEFINE_SWIZZLE_BOX_INTERNAL

static inline void unswizzle_box_internal(
    const uint8_t *src_buf,
    unsigned int width,
    unsigned int height,
    unsigned int depth,
    uint8_t *dst_buf,
    unsigned int row_pitch,
    unsigned int slice_pitch,
    unsigned int bytes_per_pixel)
{
    uint32_t mask_x, mask_y, mask_z;
    generate_swizzle_masks(width, height, depth, &mask_x, &mask_y, &mask_z);

    int x, y, z;
    int off_z = 0;
    for (z = 0; z < depth; z++) {
        int off_y = 0;
        for (y = 0; y < height; y++) {
            int off_x = 0;
            const uint8_t *src_tmp = src_buf + (off_y + off_z) * bytes_per_pixel;
            uint8_t *dst_tmp = dst_buf + y * row_pitch;
            for (x = 0; x < width; x++) {
                const uint8_t *src = src_tmp + off_x * bytes_per_pixel;
                uint8_t *dst = dst_tmp + x * bytes_per_pixel;
                memcpy(dst, src, bytes_per_pixel);

                off_x = (off_x - mask_x) & mask_x;
            }
            off_y = (off_y - mask_y) & mask_y;
        }
        dst_buf += slice_pitch;
        off_z = (off_z - mask_z) & mask_z;
    }
}

#define DEFINE_UNSWIZZLE_BOX_INTERNAL(BPP)                                \
    static inline void unswizzle_box_internal_##BPP(                      \
        const uint8_t *src_buf,                                           \
        unsigned int width,                                               \
        unsigned int height,                                              \
        unsigned int depth,                                               \
        uint8_t *dst_buf,                                                 \
        unsigned int row_pitch,                                           \
        unsigned int slice_pitch)                                         \
    {                                                                     \
        uint32_t mask_x, mask_y, mask_z;                                  \
        generate_swizzle_masks(width, height, depth, &mask_x, &mask_y,    \
                               &mask_z);                                  \
                                                                          \
        unsigned int x, y, z;                                             \
        uint32_t off_z = 0;                                               \
        for (z = 0; z < depth; z++) {                                     \
            uint32_t off_y = 0;                                           \
            for (y = 0; y < height; y++) {                                \
                uint32_t off_x = 0;                                       \
                const uint8_t *src_tmp =                                  \
                    src_buf + (off_y + off_z) * (BPP);                    \
                uint8_t *dst_tmp = dst_buf + y * row_pitch;               \
                for (x = 0; x < width; x++) {                             \
                    const uint8_t *src = src_tmp + off_x * (BPP);         \
                    uint8_t *dst = dst_tmp + x * (BPP);                   \
                    COPY_PIXEL_##BPP(dst, src);                           \
                                                                          \
                    off_x = (off_x - mask_x) & mask_x;                    \
                }                                                         \
                off_y = (off_y - mask_y) & mask_y;                        \
            }                                                             \
            dst_buf += slice_pitch;                                       \
            off_z = (off_z - mask_z) & mask_z;                            \
        }                                                                 \
    }

DEFINE_UNSWIZZLE_BOX_INTERNAL(1)
DEFINE_UNSWIZZLE_BOX_INTERNAL(2)
DEFINE_UNSWIZZLE_BOX_INTERNAL(3)
DEFINE_UNSWIZZLE_BOX_INTERNAL(4)

#undef DEFINE_UNSWIZZLE_BOX_INTERNAL

#define DEFINE_UNSWIZZLE_RECT_PAIR_INTERNAL(BPP)                         \
    static inline void unswizzle_rect_pair_internal_##BPP(                \
        const uint8_t *src_buf,                                           \
        unsigned int width,                                               \
        unsigned int height,                                              \
        uint8_t *dst_buf,                                                 \
        unsigned int row_pitch)                                           \
    {                                                                     \
        uint32_t mask_x, mask_y, mask_z;                                  \
        generate_swizzle_masks(width, height, 1, &mask_x, &mask_y,        \
                               &mask_z);                                  \
        assert(mask_z == 0);                                              \
                                                                          \
        unsigned int x, y;                                                \
        uint32_t off_y = 0;                                               \
        for (y = 0; y + 1 < height; y += 2) {                             \
            uint32_t off_y_next = (off_y - mask_y) & mask_y;              \
            uint8_t *dst_row0 = dst_buf + y * row_pitch;                  \
            uint8_t *dst_row1 = dst_row0 + row_pitch;                     \
            uint32_t off_x = 0;                                           \
                                                                          \
            for (x = 0; x + 1 < width; x += 2) {                          \
                const uint8_t *src_row0 =                                 \
                    src_buf + (off_y + off_x) * (BPP);                    \
                const uint8_t *src_row1 =                                 \
                    src_buf + (off_y_next + off_x) * (BPP);               \
                uint8_t *dst0 = dst_row0 + x * (BPP);                    \
                uint8_t *dst1 = dst_row1 + x * (BPP);                    \
                                                                          \
                COPY_PIXEL_##BPP(dst0, src_row0);                         \
                COPY_PIXEL_##BPP(dst0 + (BPP), src_row0 + (BPP));         \
                COPY_PIXEL_##BPP(dst1, src_row1);                         \
                COPY_PIXEL_##BPP(dst1 + (BPP), src_row1 + (BPP));         \
                                                                          \
                off_x = (off_x - mask_x) & mask_x;                        \
                off_x = (off_x - mask_x) & mask_x;                        \
            }                                                             \
                                                                          \
            if (x < width) {                                              \
                const uint8_t *src_row0 =                                 \
                    src_buf + (off_y + off_x) * (BPP);                    \
                const uint8_t *src_row1 =                                 \
                    src_buf + (off_y_next + off_x) * (BPP);               \
                COPY_PIXEL_##BPP(dst_row0 + x * (BPP), src_row0);         \
                COPY_PIXEL_##BPP(dst_row1 + x * (BPP), src_row1);         \
            }                                                             \
                                                                          \
            off_y = (off_y_next - mask_y) & mask_y;                       \
        }                                                                 \
                                                                          \
        if (y < height) {                                                 \
            uint8_t *dst_row = dst_buf + y * row_pitch;                   \
            uint32_t off_x = 0;                                           \
                                                                          \
            for (x = 0; x + 1 < width; x += 2) {                          \
                const uint8_t *src = src_buf + (off_y + off_x) * (BPP);   \
                uint8_t *dst = dst_row + x * (BPP);                       \
                COPY_PIXEL_##BPP(dst, src);                               \
                COPY_PIXEL_##BPP(dst + (BPP), src + (BPP));               \
                                                                          \
                off_x = (off_x - mask_x) & mask_x;                        \
                off_x = (off_x - mask_x) & mask_x;                        \
            }                                                             \
                                                                          \
            if (x < width) {                                              \
                const uint8_t *src = src_buf + (off_y + off_x) * (BPP);   \
                COPY_PIXEL_##BPP(dst_row + x * (BPP), src);               \
            }                                                             \
        }                                                                 \
    }

DEFINE_UNSWIZZLE_RECT_PAIR_INTERNAL(1)
DEFINE_UNSWIZZLE_RECT_PAIR_INTERNAL(2)
DEFINE_UNSWIZZLE_RECT_PAIR_INTERNAL(3)
DEFINE_UNSWIZZLE_RECT_PAIR_INTERNAL(4)

#undef DEFINE_UNSWIZZLE_RECT_PAIR_INTERNAL

/* Multiversioned to optimize for common bytes_per_pixel */         \
#define C(m, bpp)                                                   \
    m##_internal(src_buf, width, height, depth, dst_buf, row_pitch, \
                 slice_pitch, bpp)
#define C_FAST(m, bpp)                                              \
    m##_internal_##bpp(src_buf, width, height, depth, dst_buf,       \
                       row_pitch, slice_pitch)
#define MULTIVERSION(m)                                                     \
    void m(const uint8_t *src_buf, unsigned int width, unsigned int height, \
           unsigned int depth, uint8_t *dst_buf, unsigned int row_pitch,    \
           unsigned int slice_pitch, unsigned int bytes_per_pixel)          \
    {                                                                       \
        switch (bytes_per_pixel) {                                          \
        case 1:                                                             \
            C_FAST(m, 1);                                                   \
            break;                                                          \
        case 2:                                                             \
            C_FAST(m, 2);                                                   \
            break;                                                          \
        case 3:                                                             \
            C_FAST(m, 3);                                                   \
            break;                                                          \
        case 4:                                                             \
            C_FAST(m, 4);                                                   \
            break;                                                          \
        default:                                                            \
            C(m, bytes_per_pixel);                                          \
        }                                                                   \
    }

MULTIVERSION(swizzle_box)

void unswizzle_box(const uint8_t *src_buf, unsigned int width,
                   unsigned int height, unsigned int depth,
                   uint8_t *dst_buf, unsigned int row_pitch,
                   unsigned int slice_pitch, unsigned int bytes_per_pixel)
{
    if (depth == 1 && width > 1 && height > 1 &&
        is_power_of_two(width) && is_power_of_two(height)) {
        switch (bytes_per_pixel) {
        case 1:
            unswizzle_rect_pair_internal_1(src_buf, width, height, dst_buf,
                                           row_pitch);
            return;
        case 2:
            unswizzle_rect_pair_internal_2(src_buf, width, height, dst_buf,
                                           row_pitch);
            return;
        case 3:
            unswizzle_rect_pair_internal_3(src_buf, width, height, dst_buf,
                                           row_pitch);
            return;
        case 4:
            unswizzle_rect_pair_internal_4(src_buf, width, height, dst_buf,
                                           row_pitch);
            return;
        default:
            break;
        }
    }

    switch (bytes_per_pixel) {
    case 1:
        C_FAST(unswizzle_box, 1);
        break;
    case 2:
        C_FAST(unswizzle_box, 2);
        break;
    case 3:
        C_FAST(unswizzle_box, 3);
        break;
    case 4:
        C_FAST(unswizzle_box, 4);
        break;
    default:
        C(unswizzle_box, bytes_per_pixel);
    }
}

#undef C
#undef C_FAST
#undef MULTIVERSION
#undef COPY_PIXEL_1
#undef COPY_PIXEL_2
#undef COPY_PIXEL_3
#undef COPY_PIXEL_4
