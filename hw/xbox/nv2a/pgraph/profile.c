/*
 * QEMU Geforce NV2A profiling helpers
 *
 * Copyright (c) 2020-2024 Matt Borgerson
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

#include "hw/xbox/nv2a/nv2a_int.h"

NV2AStats g_nv2a_stats;

static void nv2a_profile_dump_surface_to_texture_counters(void);

void nv2a_profile_increment(void)
{
    int64_t now = qemu_clock_get_us(QEMU_CLOCK_REALTIME);
    const int64_t fps_update_interval = 250000;
    g_nv2a_stats.last_flip_time = now;

    static int64_t frame_count = 0;
    frame_count++;

    static int64_t ts = 0;
    int64_t delta = now - ts;
    if (delta >= fps_update_interval) {
        g_nv2a_stats.increment_fps = frame_count * 1000000 / delta;
        ts = now;
        frame_count = 0;
    }
}

void nv2a_profile_flip_stall(void)
{
    int64_t now = qemu_clock_get_us(QEMU_CLOCK_REALTIME);
    int64_t render_time = (now-g_nv2a_stats.last_flip_time)/1000;

    g_nv2a_stats.frame_working.mspf = render_time;
    g_nv2a_stats.frame_history[g_nv2a_stats.frame_ptr] =
        g_nv2a_stats.frame_working;
    g_nv2a_stats.frame_ptr =
        (g_nv2a_stats.frame_ptr + 1) % NV2A_PROF_NUM_FRAMES;
    g_nv2a_stats.frame_count++;
    nv2a_profile_dump_surface_to_texture_counters();
    memset(&g_nv2a_stats.frame_working, 0, sizeof(g_nv2a_stats.frame_working));
}

const char *nv2a_profile_get_counter_name(unsigned int cnt)
{
    const char *default_names[NV2A_PROF__COUNT] = {
        #define _X(x) stringify(x),
        NV2A_PROF_COUNTERS_XMAC
        #undef _X
    };

    assert(cnt < NV2A_PROF__COUNT);
    return default_names[cnt] + 10; /* 'NV2A_PROF_' */
}

int nv2a_profile_get_counter_value(unsigned int cnt)
{
    assert(cnt < NV2A_PROF__COUNT);
    unsigned int idx = (g_nv2a_stats.frame_ptr + NV2A_PROF_NUM_FRAMES - 1) %
                       NV2A_PROF_NUM_FRAMES;
    return g_nv2a_stats.frame_history[idx].counters[cnt];
}

static void nv2a_profile_dump_surface_to_texture_counters(void)
{
    static const unsigned int counters[] = {
        NV2A_PROF_SURF_DOWNLOAD,
        NV2A_PROF_SURF_TO_TEX,
        NV2A_PROF_SURF_TO_TEX_FALLBACK,
        NV2A_PROF_SURF_TO_TEX_OK,
        NV2A_PROF_SURF_TO_TEX_NO_SURFACE,
        NV2A_PROF_SURF_TO_TEX_FAIL_DIM,
        NV2A_PROF_SURF_TO_TEX_FAIL_PITCH,
        NV2A_PROF_SURF_TO_TEX_FAIL_OFFSET,
        NV2A_PROF_SURF_TO_TEX_FAIL_ORIGIN,
        NV2A_PROF_SURF_TO_TEX_FAIL_BOUNDS,
        NV2A_PROF_SURF_TO_TEX_FAIL_ZETA,
        NV2A_PROF_SURF_TO_TEX_ZETA_Z16,
        NV2A_PROF_SURF_TO_TEX_ZETA_Z24S8,
        NV2A_PROF_SURF_TO_TEX_ZETA_FIXED,
        NV2A_PROF_SURF_TO_TEX_ZETA_FLOAT,
        NV2A_PROF_SURF_TO_TEX_ZETA_TEX_Y16,
        NV2A_PROF_SURF_TO_TEX_ZETA_TEX_X8Y24,
        NV2A_PROF_SURF_TO_TEX_ZETA_TEX_OTHER,
        NV2A_PROF_SURF_TO_TEX_ZETA_OK,
        NV2A_PROF_SURF_TO_TEX_ZETA_COPY,
        NV2A_PROF_SURF_TO_TEX_STORAGE_ALLOC,
        NV2A_PROF_SURF_TO_TEX_STORAGE_REUSE,
        NV2A_PROF_SURF_TO_TEX_FAIL_CUBEMAP,
        NV2A_PROF_SURF_TO_TEX_FAIL_MIPMAP,
        NV2A_PROF_SURF_TO_TEX_FAIL_FORMAT,
        NV2A_PROF_SURF_TO_TEX_FALLBACK_OVERLAP,
        NV2A_PROF_SURF_TO_TEX_FALLBACK_DOWNLOAD,
        NV2A_PROF_SURF_TO_TEX_FALLBACK_CACHE,
        NV2A_PROF_SURF_TO_TEX_FALLBACK_ZETA_OVERLAP,
        NV2A_PROF_SURF_TO_TEX_FALLBACK_ZETA_DOWNLOAD,
        NV2A_PROF_SURF_TO_TEX_FALLBACK_ZETA_CLEAN,
    };
    static const unsigned int num_counters =
        sizeof(counters) / sizeof(counters[0]);
    int values[sizeof(counters) / sizeof(counters[0])] = { 0 };
    unsigned int i, frame;
    bool any = false;

    if (g_nv2a_stats.frame_count == 0 ||
        (g_nv2a_stats.frame_count % NV2A_PROF_NUM_FRAMES) != 0) {
        return;
    }

    for (frame = 0; frame < NV2A_PROF_NUM_FRAMES; frame++) {
        for (i = 0; i < num_counters; i++) {
            values[i] += g_nv2a_stats.frame_history[frame].counters[counters[i]];
        }
    }

    for (i = 0; i < num_counters; i++) {
        any |= values[i] != 0;
    }

    if (!any) {
        return;
    }

    fprintf(stderr, "nv2a-profile: surface-to-texture counters, last %u frames\n",
            NV2A_PROF_NUM_FRAMES);
    for (i = 0; i < num_counters; i++) {
        if (values[i] != 0) {
            fprintf(stderr, "nv2a-profile:   %s=%d\n",
                    nv2a_profile_get_counter_name(counters[i]), values[i]);
        }
    }
}
