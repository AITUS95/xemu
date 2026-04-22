/*
 * QEMU Geforce NV2A implementation
 *
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2024 Matt Borgerson
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

#ifndef HW_XBOX_NV2A_PGRAPH_UTIL_H
#define HW_XBOX_NV2A_PGRAPH_UTIL_H

static const float f16_max = 511.9375f;
static const float f24_max = 1.0E30;

/* 16 bit to [0.0, F16_MAX = 511.9375] */
static inline 
float convert_f16_to_float(uint16_t f16) {
    if (f16 == 0x0000) { return 0.0; }
    uint32_t i = (f16 << 11) + 0x3C000000;
    return *(float*)&i;
}

/* 24 bit to [0.0, F24_MAX] */
static inline 
float convert_f24_to_float(uint32_t f24) {
    assert(!(f24 >> 24));
    f24 &= 0xFFFFFF;
    if (f24 == 0x000000) { return 0.0; }
    uint32_t i = f24 << 7;
    return *(float*)&i;
}

static inline 
uint8_t cliptobyte(int x)
{
    if ((unsigned int)x <= 255) {
        return (uint8_t)x;
    }
    return (x < 0) ? 0 : 255;
}

static inline 
void convert_yuy2_to_rgb(const uint8_t *line, unsigned int ix,
                                uint8_t *r, uint8_t *g, uint8_t* b) {
    const uint8_t *src = line + ((ix & ~1u) * 2);
    int c = (int)src[(ix & 1u) ? 2 : 0] - 16;
    int d = (int)src[1] - 128;
    int e = (int)src[3] - 128;

    *r = cliptobyte((298 * c + 409 * e + 128) >> 8);
    *g = cliptobyte((298 * c - 100 * d - 208 * e + 128) >> 8);
    *b = cliptobyte((298 * c + 516 * d + 128) >> 8);
}

static inline 
void convert_uyvy_to_rgb(const uint8_t *line, unsigned int ix,
                                uint8_t *r, uint8_t *g, uint8_t* b) {
    const uint8_t *src = line + ((ix & ~1u) * 2);
    int c = (int)src[(ix & 1u) ? 3 : 1] - 16;
    int d = (int)src[0] - 128;
    int e = (int)src[2] - 128;

    *r = cliptobyte((298 * c + 409 * e + 128) >> 8);
    *g = cliptobyte((298 * c - 100 * d - 208 * e + 128) >> 8);
    *b = cliptobyte((298 * c + 516 * d + 128) >> 8);
}

static inline
void convert_yuy2_pair_to_rgb(const uint8_t *src,
                              uint8_t *rgb0, uint8_t *rgb1)
{
    int d = (int)src[1] - 128;
    int e = (int)src[3] - 128;
    int re = 409 * e + 128;
    int gde = -100 * d - 208 * e + 128;
    int bd = 516 * d + 128;
    int c0 = 298 * ((int)src[0] - 16);
    int c1 = 298 * ((int)src[2] - 16);

    rgb0[0] = cliptobyte((c0 + re) >> 8);
    rgb0[1] = cliptobyte((c0 + gde) >> 8);
    rgb0[2] = cliptobyte((c0 + bd) >> 8);
    rgb1[0] = cliptobyte((c1 + re) >> 8);
    rgb1[1] = cliptobyte((c1 + gde) >> 8);
    rgb1[2] = cliptobyte((c1 + bd) >> 8);
}

static inline
void convert_uyvy_pair_to_rgb(const uint8_t *src,
                              uint8_t *rgb0, uint8_t *rgb1)
{
    int d = (int)src[0] - 128;
    int e = (int)src[2] - 128;
    int re = 409 * e + 128;
    int gde = -100 * d - 208 * e + 128;
    int bd = 516 * d + 128;
    int c0 = 298 * ((int)src[1] - 16);
    int c1 = 298 * ((int)src[3] - 16);

    rgb0[0] = cliptobyte((c0 + re) >> 8);
    rgb0[1] = cliptobyte((c0 + gde) >> 8);
    rgb0[2] = cliptobyte((c0 + bd) >> 8);
    rgb1[0] = cliptobyte((c1 + re) >> 8);
    rgb1[1] = cliptobyte((c1 + gde) >> 8);
    rgb1[2] = cliptobyte((c1 + bd) >> 8);
}

#endif
