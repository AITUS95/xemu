/*
 * Geforce NV2A PGRAPH GLSL Shader Generator
 *
 * Copyright (c) 2015 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
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

#include "qemu/osdep.h"
#include "hw/xbox/nv2a/pgraph/pgraph.h"
#include "geom.h"

void pgraph_glsl_set_geom_state(PGRAPHState *pg, GeomState *state)
{
    state->primitive_mode = (enum ShaderPrimitiveMode)pg->primitive_mode;

    state->polygon_front_mode = (enum ShaderPolygonMode)GET_MASK(
        pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER),
        NV_PGRAPH_SETUPRASTER_FRONTFACEMODE);
    state->polygon_back_mode = (enum ShaderPolygonMode)GET_MASK(
        pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER),
        NV_PGRAPH_SETUPRASTER_BACKFACEMODE);

    state->smooth_shading = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3),
                                     NV_PGRAPH_CONTROL_3_SHADEMODE) ==
                            NV_PGRAPH_CONTROL_3_SHADEMODE_SMOOTH;

    state->first_vertex_is_provoking =
        GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3),
                 NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX) ==
        NV_PGRAPH_CONTROL_3_PROVOKING_VERTEX_FIRST;

    state->z_perspective = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0) &
                           NV_PGRAPH_CONTROL_0_Z_PERSPECTIVE_ENABLE;

    if (pg->renderer->ops.get_gpu_properties) {
        GPUProperties *gpu_props = pg->renderer->ops.get_gpu_properties();

        switch (state->primitive_mode) {
        case PRIM_TYPE_TRIANGLES:
            state->tri_rot0 = gpu_props->geom_shader_winding.tri;
            state->tri_rot1 = state->tri_rot0;
            break;
        case PRIM_TYPE_TRIANGLE_STRIP:
            state->tri_rot0 = gpu_props->geom_shader_winding.tri_strip0;
            state->tri_rot1 = gpu_props->geom_shader_winding.tri_strip1;
            break;
        case PRIM_TYPE_TRIANGLE_FAN:
        case PRIM_TYPE_POLYGON:
            state->tri_rot0 = gpu_props->geom_shader_winding.tri_fan;
            state->tri_rot1 = state->tri_rot0;
            break;
        default:
            break;
        }
    }
}

static const char *get_vertex_order(int rot)
{
    if (rot == 0) {
        return "ivec3(0, 1, 2)";
    } else if (rot == 1) {
        return "ivec3(2, 0, 1)";
    } else {
        return "ivec3(1, 2, 0)";
    }
}

bool pgraph_glsl_need_geom(const GeomState *state)
{
    /* FIXME: Missing support for 2-sided-poly mode */
    assert(state->polygon_front_mode == state->polygon_back_mode);
    enum ShaderPolygonMode polygon_mode = state->polygon_front_mode;

    switch (state->primitive_mode) {
    case PRIM_TYPE_POINTS:
        return false;
    case PRIM_TYPE_LINES:
    case PRIM_TYPE_LINE_LOOP:
    case PRIM_TYPE_LINE_STRIP:
    case PRIM_TYPE_TRIANGLES:
    case PRIM_TYPE_TRIANGLE_STRIP:
    case PRIM_TYPE_TRIANGLE_FAN:
    case PRIM_TYPE_QUADS:
    case PRIM_TYPE_QUAD_STRIP:
        return true;
    case PRIM_TYPE_POLYGON:
        if (polygon_mode == POLY_MODE_POINT) {
            assert(false);
            return false;
        }
        return true;
    default:
        return false;
    }
}

MString *pgraph_glsl_gen_geom(const GeomState *state, GenGeomGlslOptions opts)
{
    /* FIXME: Missing support for 2-sided-poly mode */
    assert(state->polygon_front_mode == state->polygon_back_mode);
    enum ShaderPolygonMode polygon_mode = state->polygon_front_mode;

    bool need_triz = false;
    bool need_quadz = false;
    bool need_linez = false;
    const char *layout_in = NULL;
    const char *layout_out = NULL;
    const char *body = NULL;
    const char *provoking_index = "0";
    char body_buf[512];

    /* TODO: frontface/backface culling for polygon modes POLY_MODE_LINE and
     * POLY_MODE_POINT.
     */
    switch (state->primitive_mode) {
    case PRIM_TYPE_POINTS: return NULL;
    case PRIM_TYPE_LINES:
    case PRIM_TYPE_LINE_LOOP:
    case PRIM_TYPE_LINE_STRIP:
        provoking_index = state->first_vertex_is_provoking ? "0" : "1";
        need_linez = true;
        layout_in = "layout(lines) in;\n";
        layout_out = "layout(line_strip, max_vertices = 2) out;\n";
        body = "  emit_line(0, 1, 0.0);\n";
        break;
    case PRIM_TYPE_TRIANGLES:
    case PRIM_TYPE_TRIANGLE_STRIP:
    case PRIM_TYPE_TRIANGLE_FAN:
        if (state->first_vertex_is_provoking) {
            provoking_index = "v[0]";
        } else if (state->primitive_mode == PRIM_TYPE_TRIANGLE_STRIP) {
            provoking_index = "v[2 - (gl_PrimitiveIDIn & 1)]";
        } else if (state->primitive_mode == PRIM_TYPE_TRIANGLE_FAN) {
            provoking_index = "v[1]";
        } else {
            provoking_index = "v[2]";
        }
        need_triz = true;
        layout_in = "layout(triangles) in;\n";
        if (polygon_mode == POLY_MODE_FILL) {
            layout_out = "layout(triangle_strip, max_vertices = 6) out;\n";
            snprintf(body_buf, sizeof(body_buf),
                     "  emit_clipped_triangle(load_vertex(v[0], %s), "
                     "load_vertex(v[1], %s), load_vertex(v[2], %s));\n",
                     provoking_index, provoking_index, provoking_index);
            body = body_buf;
        } else if (polygon_mode == POLY_MODE_LINE) {
            need_linez = true;
            layout_out = "layout(line_strip, max_vertices = 6) out;\n";
            body = "  float dz = calc_triz(v[0], v[1], v[2])[3].x;\n"
                   "  emit_line(v[0], v[1], dz);\n"
                   "  emit_line(v[1], v[2], dz);\n"
                   "  emit_line(v[2], v[0], dz);\n";
        } else {
            assert(polygon_mode == POLY_MODE_POINT);
            layout_out = "layout(points, max_vertices = 3) out;\n";
            body = "  mat4 pz = calc_triz(v[0], v[1], v[2]);\n"
                   "  emit_vertex(v[0], mat4(pz[0], pz[0], pz[0], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(v[1], mat4(pz[1], pz[1], pz[1], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(v[2], mat4(pz[2], pz[2], pz[2], pz[3]));\n"
                   "  EndPrimitive();\n";
        }
        break;
    case PRIM_TYPE_QUADS:
        provoking_index = "3";
        need_quadz = true;
        layout_in = "layout(lines_adjacency) in;\n";
        if (polygon_mode == POLY_MODE_FILL) {
            layout_out = "layout(triangle_strip, max_vertices = 12) out;\n";
            body = "  emit_clipped_triangle(load_vertex(1, 3), "
                   "load_vertex(2, 3), load_vertex(0, 3));\n"
                   "  emit_clipped_triangle(load_vertex(2, 3), "
                   "load_vertex(3, 3), load_vertex(0, 3));\n";
        } else if (polygon_mode == POLY_MODE_LINE) {
            need_linez = true;
            layout_out = "layout(line_strip, max_vertices = 8) out;\n";
            body = "  mat4 pz, pzs;\n"
                   "  calc_quadz(0, 1, 2, 3, pz, pzs);\n"
                   "  emit_line(0, 1, pz[3].x);\n"
                   "  emit_line(1, 2, pz[3].x);\n"
                   "  emit_line(2, 3, pzs[3].x);\n"
                   "  emit_line(3, 0, pzs[3].x);\n";
        } else {
            assert(polygon_mode == POLY_MODE_POINT);
            layout_out = "layout(points, max_vertices = 4) out;\n";
            body = "  mat4 pz, pz2;\n"
                   "  calc_quadz(0, 1, 2, 3, pz, pz2);\n"
                   "  emit_vertex(0, mat4(pz[0], pz[0], pz[0], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(1, mat4(pz[1], pz[1], pz[1], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(2, mat4(pz[2], pz[2], pz[2], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(3, mat4(pz2[2], pz2[2], pz2[2], pz2[3]));\n"
                   "  EndPrimitive();\n";
        }
        break;
    case PRIM_TYPE_QUAD_STRIP:
        provoking_index = "3";
        need_quadz = true;
        layout_in = "layout(lines_adjacency) in;\n";
        if (polygon_mode == POLY_MODE_FILL) {
            layout_out = "layout(triangle_strip, max_vertices = 12) out;\n";
            body = "  if ((gl_PrimitiveIDIn & 1) != 0) { return; }\n"
                   "  emit_clipped_triangle(load_vertex(0, 3), "
                   "load_vertex(1, 3), load_vertex(2, 3));\n"
                   "  emit_clipped_triangle(load_vertex(2, 3), "
                   "load_vertex(1, 3), load_vertex(3, 3));\n";
        } else if (polygon_mode == POLY_MODE_LINE) {
            need_linez = true;
            layout_out = "layout(line_strip, max_vertices = 8) out;\n";
            body = "  if ((gl_PrimitiveIDIn & 1) != 0) { return; }\n"
                   "  mat4 pz, pzs;\n"
                   "  calc_quadz(2, 0, 1, 3, pz, pzs);\n"
                   "  emit_line(0, 1, pz[3].x);\n"
                   "  emit_line(1, 3, pzs[3].x);\n"
                   "  emit_line(3, 2, pzs[3].x);\n"
                   "  emit_line(2, 0, pz[3].x);\n";
        } else {
            assert(polygon_mode == POLY_MODE_POINT);
            layout_out = "layout(points, max_vertices = 4) out;\n";
            body = "  if ((gl_PrimitiveIDIn & 1) != 0) { return; }\n"
                   "  mat4 pz, pz2;\n"
                   "  calc_quadz(2, 0, 1, 3, pz, pz2);\n"
                   "  emit_vertex(0, mat4(pz[1], pz[1], pz[1], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(1, mat4(pz[2], pz[2], pz[2], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(2, mat4(pz[0], pz[0], pz[0], pz[3]));\n"
                   "  EndPrimitive();\n"
                   "  emit_vertex(3, mat4(pz2[2], pz2[2], pz2[2], pz2[3]));\n"
                   "  EndPrimitive();\n";
        }
        break;
    case PRIM_TYPE_POLYGON:
        if (polygon_mode == POLY_MODE_FILL) {
            provoking_index = "v[2]";
            need_triz = true;
            layout_in = "layout(triangles) in;\n";
            layout_out = "layout(triangle_strip, max_vertices = 6) out;\n";
            body = "  emit_clipped_triangle(load_vertex(v[0], v[2]), "
                   "load_vertex(v[1], v[2]), load_vertex(v[2], v[2]));\n";
        } else if (polygon_mode == POLY_MODE_LINE) {
            provoking_index = "0";
            need_linez = true;
            /* FIXME: input here is lines and not triangles so we cannot
             * calculate triangle plane slope. Also, the first vertex of the
             * polygon is unavailable so flat shading provoking vertex is
             * wrong.
             */
            layout_in = "layout(lines) in;\n";
            layout_out = "layout(line_strip, max_vertices = 2) out;\n";
            body = "  emit_line(0, 1, 0.0);\n";
        } else {
            assert(false);
            return NULL;
        }
        break;

    default:
        assert(false);
        return NULL;
    }

    /* generate a geometry shader to support deprecated primitive types */
    assert(layout_in);
    assert(layout_out);
    assert(body);
    MString *output =
        mstring_from_fmt("#version %d\n\n"
                         "%s"
                         "%s"
                         "\n"
                         "#define v_vtxPos v_vtxPos0\n"
                         "\n",
                         opts.vulkan ? 450 : 400, layout_in, layout_out);
    pgraph_glsl_get_vtx_header(output, opts.vulkan, state->smooth_shading, true,
                               true, true);
    pgraph_glsl_get_vtx_header(output, opts.vulkan, state->smooth_shading,
                               false, false, false);

    char vertex_order_buf[80];
    const char *vertex_order_body = "";

    if (need_triz) {
        /* Input triangle absolute vertex order is not guaranteed by OpenGL
         * or Vulkan, only winding order is. Reorder vertices here to first
         * vertex convention which we assumed above when setting
         * provoking_index. This mostly only matters with flat shading, but
         * we reorder always to get consistent results across GPU vendors
         * regarding floating-point rounding when calculating with vtxPos0/1/2.
         */
        mstring_append(output, "ivec3 v;\n");
        if (state->tri_rot0 == state->tri_rot1) {
            snprintf(vertex_order_buf, sizeof(vertex_order_buf), "  v = %s;\n",
                     get_vertex_order(state->tri_rot0));
        } else {
            snprintf(vertex_order_buf, sizeof(vertex_order_buf),
                     "  v = (gl_PrimitiveIDIn & 1) == 0 ? %s : %s;\n",
                     get_vertex_order(state->tri_rot0),
                     get_vertex_order(state->tri_rot1));
        }
        vertex_order_body = vertex_order_buf;
    }

    if (state->smooth_shading) {
        provoking_index = "index";
    }

    mstring_append_fmt(
        output,
        "void emit_vertex(int index, mat4 pz) {\n"
        "  gl_Position = gl_in[index].gl_Position;\n"
        "  gl_PointSize = gl_in[index].gl_PointSize;\n"
        "  vtxD0 = v_vtxD0[%s];\n"
        "  vtxD1 = v_vtxD1[%s];\n"
        "  vtxB0 = v_vtxB0[%s];\n"
        "  vtxB1 = v_vtxB1[%s];\n"
        "  vtxFog = v_vtxFog[index];\n"
        "  vtxT0 = v_vtxT0[index];\n"
        "  vtxT1 = v_vtxT1[index];\n"
        "  vtxT2 = v_vtxT2[index];\n"
        "  vtxT3 = v_vtxT3[index];\n"
        "  vtxPos0 = pz[0];\n"
        "  vtxPos1 = pz[1];\n"
        "  vtxPos2 = pz[2];\n"
        "  triMZ = (isnan(pz[3].x) || isinf(pz[3].x)) ? 0.0 : pz[3].x;\n"
        "  EmitVertex();\n"
        "}\n",
        provoking_index,
        provoking_index,
        provoking_index,
        provoking_index);

    if (need_triz || need_quadz) {
        const char *color_index = state->smooth_shading ? "index" : "flat_index";
        mstring_append_fmt(
            output,
            "const float CLIP_W_EPSILON = 5.42101086242752217e-20;\n"
            "\n"
            "struct ClipVertex {\n"
            "  vec4 position;\n"
            "  float pointSize;\n"
            "  vec4 d0;\n"
            "  vec4 d1;\n"
            "  vec4 b0;\n"
            "  vec4 b1;\n"
            "  float fog;\n"
            "  vec4 t0;\n"
            "  vec4 t1;\n"
            "  vec4 t2;\n"
            "  vec4 t3;\n"
            "  vec4 pos;\n"
            "};\n"
            "\n"
            "ClipVertex load_vertex(int index, int flat_index) {\n"
            "  ClipVertex v;\n"
            "  v.position = gl_in[index].gl_Position;\n"
            "  v.pointSize = gl_in[index].gl_PointSize;\n"
            "  v.d0 = v_vtxD0[%s];\n"
            "  v.d1 = v_vtxD1[%s];\n"
            "  v.b0 = v_vtxB0[%s];\n"
            "  v.b1 = v_vtxB1[%s];\n"
            "  v.fog = v_vtxFog[index];\n"
            "  v.t0 = v_vtxT0[index];\n"
            "  v.t1 = v_vtxT1[index];\n"
            "  v.t2 = v_vtxT2[index];\n"
            "  v.t3 = v_vtxT3[index];\n"
            "  v.pos = v_vtxPos[index];\n"
            "  return v;\n"
            "}\n"
            "\n"
            "bool clip_inside(ClipVertex v) {\n"
            "  return v.pos.w >= CLIP_W_EPSILON;\n"
            "}\n"
            "\n"
            "ClipVertex intersect_clip_edge(ClipVertex a, ClipVertex b) {\n"
            "  float t = (CLIP_W_EPSILON - a.pos.w) / (b.pos.w - a.pos.w);\n"
            "  ClipVertex v;\n"
            "  v.position = mix(a.position, b.position, t);\n"
            "  v.position.w = CLIP_W_EPSILON;\n"
            "  v.pointSize = mix(a.pointSize, b.pointSize, t);\n"
            "  v.d0 = mix(a.d0, b.d0, t);\n"
            "  v.d1 = mix(a.d1, b.d1, t);\n"
            "  v.b0 = mix(a.b0, b.b0, t);\n"
            "  v.b1 = mix(a.b1, b.b1, t);\n"
            "  v.fog = mix(a.fog, b.fog, t);\n"
            "  v.t0 = mix(a.t0, b.t0, t);\n"
            "  v.t1 = mix(a.t1, b.t1, t);\n"
            "  v.t2 = mix(a.t2, b.t2, t);\n"
            "  v.t3 = mix(a.t3, b.t3, t);\n"
            "  v.pos.w = CLIP_W_EPSILON;\n"
            "  v.pos.xyz = mix(a.pos.xyz * a.pos.w, b.pos.xyz * b.pos.w, t) / v.pos.w;\n"
            "  return v;\n"
            "}\n"
            "\n",
            color_index,
            color_index,
            color_index,
            color_index);
    }

    if (need_triz || need_quadz) {
        mstring_append(
            output,
            // Kahan's algorithm for computing a*b - c*d using FMA for higher
            // precision. See e.g.:
            // Muller et al, "Handbook of Floating-Point Arithmetic", 2nd ed.
            // or
            // Claude-Pierre Jeannerod, Nicolas Louvet, and Jean-Michel Muller,
            // Further analysis of Kahan's algorithm for the accurate
            // computation of 2x2 determinants,
            // Mathematics of Computation 82(284), October 2013.
            "float kahan_det(float a, float b, float c, float d) {\n"
            "  precise float cd = c*d;\n"
            "  precise float err = fma(-c, d, cd);\n"
            "  precise float res = fma(a, b, -cd) + err;\n"
            "  return res;\n"
            "}\n");

        if (state->z_perspective) {
            mstring_append(
                output,
                "mat4 calc_triz_pos(vec4 p0, vec4 p1, vec4 p2) {\n"
                "  mat2 m = mat2(p1.xy - p0.xy,\n"
                "                p2.xy - p0.xy);\n"
                "  precise vec2 b = vec2(p0.w - p1.w,\n"
                "                        p0.w - p2.w);\n"
                "  b /= vec2(p1.w, p2.w) * p0.w;\n"
                // The following computes dzx and dzy same as
                // vec2 dz = b * inverse(m);
                "  float det = kahan_det(m[0].x, m[1].y, m[1].x, m[0].y);\n"
                "  float dzx = kahan_det(b.x, m[1].y, b.y, m[0].y) / det;\n"
                "  float dzy = kahan_det(b.y, m[0].x, b.x, m[1].x) / det;\n"
                "  float dz = max(abs(dzx), abs(dzy));\n"
                "  return mat4(p0, p1, p2, dz, vec3(0.0));\n"
                "}\n"
                "mat4 calc_triz(int i0, int i1, int i2) {\n"
                "  return calc_triz_pos(v_vtxPos[i0], v_vtxPos[i1], v_vtxPos[i2]);\n"
                "}\n");
        } else {
            mstring_append(
                output,
                "mat4 calc_triz_pos(vec4 p0, vec4 p1, vec4 p2) {\n"
                "  mat2 m = mat2(p1.xy - p0.xy,\n"
                "                p2.xy - p0.xy);\n"
                "  precise vec2 b = vec2(p1.z - p0.z,\n"
                "                        p2.z - p0.z);\n"
                // The following computes dzx and dzy same as
                // vec2 dz = b * inverse(m);
                "  float det = kahan_det(m[0].x, m[1].y, m[1].x, m[0].y);\n"
                "  float dzx = kahan_det(b.x, m[1].y, b.y, m[0].y) / det;\n"
                "  float dzy = kahan_det(b.y, m[0].x, b.x, m[1].x) / det;\n"
                "  float dz = max(abs(dzx), abs(dzy));\n"
                "  return mat4(p0, p1, p2, dz, vec3(0.0));\n"
                "}\n"
                "mat4 calc_triz(int i0, int i1, int i2) {\n"
                "  return calc_triz_pos(v_vtxPos[i0], v_vtxPos[i1], v_vtxPos[i2]);\n"
                "}\n");
        }

        mstring_append(
            output,
            "void emit_clip_vertex(ClipVertex v, mat4 pz) {\n"
            "  gl_Position = v.position;\n"
            "  gl_PointSize = v.pointSize;\n"
            "  vtxD0 = v.d0;\n"
            "  vtxD1 = v.d1;\n"
            "  vtxB0 = v.b0;\n"
            "  vtxB1 = v.b1;\n"
            "  vtxFog = v.fog;\n"
            "  vtxT0 = v.t0;\n"
            "  vtxT1 = v.t1;\n"
            "  vtxT2 = v.t2;\n"
            "  vtxT3 = v.t3;\n"
            "  vtxPos0 = pz[0];\n"
            "  vtxPos1 = pz[1];\n"
            "  vtxPos2 = pz[2];\n"
            "  triMZ = (isnan(pz[3].x) || isinf(pz[3].x)) ? 0.0 : pz[3].x;\n"
            "  EmitVertex();\n"
            "}\n"
            "\n"
            "void emit_triangle_data(ClipVertex a, ClipVertex b, ClipVertex c) {\n"
            "  mat4 pz = calc_triz_pos(a.pos, b.pos, c.pos);\n"
            "  emit_clip_vertex(a, pz);\n"
            "  emit_clip_vertex(b, pz);\n"
            "  emit_clip_vertex(c, pz);\n"
            "  EndPrimitive();\n"
            "}\n"
            "\n"
            "void emit_clipped_triangle(ClipVertex v0, ClipVertex v1, ClipVertex v2) {\n"
            "  ClipVertex input_vertices[3];\n"
            "  ClipVertex output_vertices[4];\n"
            "  input_vertices[0] = v0;\n"
            "  input_vertices[1] = v1;\n"
            "  input_vertices[2] = v2;\n"
            "  int output_count = 0;\n"
            "  ClipVertex start = input_vertices[2];\n"
            "  bool start_inside = clip_inside(start);\n"
            "  for (int i = 0; i < 3; i++) {\n"
            "    ClipVertex end = input_vertices[i];\n"
            "    bool end_inside = clip_inside(end);\n"
            "    if (end_inside) {\n"
            "      if (!start_inside) {\n"
            "        output_vertices[output_count++] = intersect_clip_edge(start, end);\n"
            "      }\n"
            "      output_vertices[output_count++] = end;\n"
            "    } else if (start_inside) {\n"
            "      output_vertices[output_count++] = intersect_clip_edge(start, end);\n"
            "    }\n"
            "    start = end;\n"
            "    start_inside = end_inside;\n"
            "  }\n"
            "  if (output_count < 3) {\n"
            "    return;\n"
            "  }\n"
            "  emit_triangle_data(output_vertices[0], output_vertices[1], output_vertices[2]);\n"
            "  if (output_count == 4) {\n"
            "    emit_triangle_data(output_vertices[0], output_vertices[2], output_vertices[3]);\n"
            "  }\n"
            "}\n");
    }

    if (need_linez) {
        mstring_append(
            output,
            // Calculate a third vertex by rotating 90 degrees so that triangle
            // interpolation in fragment shader can be used as is for lines.
            "void emit_line(int i0, int i1, float dz) {\n"
            "  vec2 delta = v_vtxPos[i1].xy - v_vtxPos[i0].xy;\n"
            "  vec2 v2 = vec2(-delta.y, delta.x) + v_vtxPos[i0].xy;\n"
            "  mat4 pz = mat4(v_vtxPos[i0], v_vtxPos[i1], v2, v_vtxPos[i0].zw, dz, vec3(0.0));\n"
            "  emit_vertex(i0, pz);\n"
            "  emit_vertex(i1, pz);\n"
            "  EndPrimitive();\n"
            "}\n");
    }

    if (need_quadz) {
        mstring_append(
            output,
            "void calc_quadz(int i0, int i1, int i2, int i3, out mat4 triz1, out mat4 triz2) {\n"
            "  triz1 = calc_triz(i0, i1, i2);\n"
            "  triz2 = calc_triz(i0, i2, i3);\n"
            "}\n");
    }

    mstring_append_fmt(output,
                       "\n"
                       "void main() {\n"
                       "%s"
                       "%s"
                       "}\n",
                       vertex_order_body, body);

    return output;
}
