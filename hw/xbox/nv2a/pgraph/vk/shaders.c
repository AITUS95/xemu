/*
 * Geforce NV2A PGRAPH Vulkan Renderer
 *
 * Copyright (c) 2024-2025 Matt Borgerson
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
#include "qemu/fast-hash.h"
#include "qemu/mstring.h"
#include "renderer.h"

#define VSH_UBO_BINDING 0
#define PSH_UBO_BINDING 1
#define PSH_TEX_BINDING 2

const size_t MAX_UNIFORM_ATTR_VALUES_SIZE = NV2A_VERTEXSHADER_ATTRIBUTES * 4 * sizeof(float);

static void create_descriptor_pool(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    size_t num_sets = ARRAY_SIZE(r->descriptor_sets);

    VkDescriptorPoolSize pool_sizes[] = {
        {
            .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 2 * num_sets,
        },
        {
            .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = NV2A_MAX_TEXTURES * num_sets,
        }
    };

    VkDescriptorPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = ARRAY_SIZE(pool_sizes),
        .pPoolSizes = pool_sizes,
        .maxSets = ARRAY_SIZE(r->descriptor_sets),
        .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
    };
    VK_CHECK(vkCreateDescriptorPool(r->device, &pool_info, NULL,
                                    &r->descriptor_pool));
}

static void destroy_descriptor_pool(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    vkDestroyDescriptorPool(r->device, r->descriptor_pool, NULL);
    r->descriptor_pool = VK_NULL_HANDLE;
}

static void create_descriptor_set_layout(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    VkDescriptorSetLayoutBinding bindings[2 + NV2A_MAX_TEXTURES];

    bindings[0] = (VkDescriptorSetLayoutBinding){
        .binding = VSH_UBO_BINDING,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
    };
    bindings[1] = (VkDescriptorSetLayoutBinding){
        .binding = PSH_UBO_BINDING,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    for (int i = 0; i < NV2A_MAX_TEXTURES; i++) {
        bindings[2 + i] = (VkDescriptorSetLayoutBinding){
            .binding = PSH_TEX_BINDING + i,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        };
    }
    VkDescriptorSetLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = ARRAY_SIZE(bindings),
        .pBindings = bindings,
    };
    VK_CHECK(vkCreateDescriptorSetLayout(r->device, &layout_info, NULL,
                                         &r->descriptor_set_layout));
}

static void destroy_descriptor_set_layout(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    vkDestroyDescriptorSetLayout(r->device, r->descriptor_set_layout, NULL);
    r->descriptor_set_layout = VK_NULL_HANDLE;
}

static void create_descriptor_sets(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    VkDescriptorSetLayout layouts[ARRAY_SIZE(r->descriptor_sets)];
    for (int i = 0; i < ARRAY_SIZE(layouts); i++) {
        layouts[i] = r->descriptor_set_layout;
    }

    VkDescriptorSetAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = r->descriptor_pool,
        .descriptorSetCount = ARRAY_SIZE(r->descriptor_sets),
        .pSetLayouts = layouts,
    };
    VK_CHECK(
        vkAllocateDescriptorSets(r->device, &alloc_info, r->descriptor_sets));
    memset(r->descriptor_set_states, 0, sizeof(r->descriptor_set_states));
}

static void destroy_descriptor_sets(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    vkFreeDescriptorSets(r->device, r->descriptor_pool,
                         ARRAY_SIZE(r->descriptor_sets), r->descriptor_sets);
    for (int i = 0; i < ARRAY_SIZE(r->descriptor_sets); i++) {
        r->descriptor_sets[i] = VK_NULL_HANDLE;
    }
    memset(r->descriptor_set_states, 0, sizeof(r->descriptor_set_states));
}

static float get_texture_uniform_scale(PGRAPHVkState *r, int texture_idx)
{
    TextureBinding *binding = r->texture_bindings[texture_idx];

    if (!binding) {
        return 1.0f;
    }

    float scale = binding->key.scale;
    BasicColorFormatInfo f_basic =
        kelvin_color_format_info_map[binding->key.state.color_format];

    return f_basic.linear ? scale : 1.0f;
}

static void init_descriptor_set_state(PGRAPHVkState *r,
                                      ShaderUniformLayout *layouts[2],
                                      DescriptorSetState *state)
{
    memset(state, 0, sizeof(*state));
    for (int i = 0; i < ARRAY_SIZE(state->uniform_ranges); i++) {
        state->uniform_ranges[i] = layouts[i]->total_size;
    }
    for (int i = 0; i < NV2A_MAX_TEXTURES; i++) {
        assert(r->texture_bindings[i] != NULL);
        assert(r->texture_samplers[i] != NULL);
        state->image_views[i] = r->texture_bindings[i]->image_view;
        state->samplers[i] = r->texture_samplers[i]->sampler;
    }
    state->valid = true;
}

static void upload_uniform_buffers(PGRAPHState *pg,
                                   ShaderUniformLayout *layouts[2])
{
    PGRAPHVkState *r = pg->vk_renderer_state;
    VkDeviceAddress alignment =
        r->device_props.limits.minUniformBufferOffsetAlignment;
    void *data[] = {
        layouts[0]->allocation,
        layouts[1]->allocation,
    };
    VkDeviceSize sizes[] = {
        layouts[0]->total_size,
        layouts[1]->total_size,
    };

    r->uniform_buffer_offsets[0] = pgraph_vk_append_to_buffer(
        pg, BUFFER_UNIFORM_STAGING, data, sizes, ARRAY_SIZE(data), alignment);
    r->uniform_buffer_offsets[1] =
        ROUND_UP(r->uniform_buffer_offsets[0] + sizes[0], alignment);

    r->uniform_buffer_offsets_valid = true;
    r->uniforms_changed = false;
}

static bool descriptor_set_state_equal(const DescriptorSetState *a,
                                       const DescriptorSetState *b)
{
    return a->valid && b->valid &&
           memcmp(a->uniform_ranges, b->uniform_ranges,
                  sizeof(a->uniform_ranges)) == 0 &&
           memcmp(a->image_views, b->image_views, sizeof(a->image_views)) == 0 &&
           memcmp(a->samplers, b->samplers, sizeof(a->samplers)) == 0;
}

void pgraph_vk_update_descriptor_sets(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    ShaderBinding *binding = r->shader_binding;
    ShaderUniformLayout *layouts[] = { &binding->vsh.module_info->uniforms,
                                       &binding->psh.module_info->uniforms };
    DescriptorSetState target_descriptor_state = { 0 };
    bool target_descriptor_state_valid = false;

    bool need_uniform_write =
        r->uniforms_changed ||
        !r->uniform_buffer_offsets_valid;
    bool need_descriptor_write =
        r->shader_bindings_changed || r->texture_bindings_changed ||
        (r->descriptor_set_index == 0);

    if (need_descriptor_write) {
        init_descriptor_set_state(r, layouts, &target_descriptor_state);
        target_descriptor_state_valid = true;
    }

    if (need_descriptor_write && r->descriptor_set_index > 0 &&
        descriptor_set_state_equal(
            &r->descriptor_set_states[r->descriptor_set_index - 1],
            &target_descriptor_state)) {
        need_descriptor_write = false;
    }

    if (!(need_descriptor_write || need_uniform_write)) {
        return; // Nothing changed
    }

    VkDeviceSize ubo_buffer_sizes[2];
    for (int i = 0; i < ARRAY_SIZE(layouts); i++) {
        ubo_buffer_sizes[i] = layouts[i]->total_size;
    }
    bool need_ubo_staging_buffer_reset =
        need_uniform_write &&
        !pgraph_vk_buffer_has_space_for_ranges(
            pg, BUFFER_UNIFORM_STAGING, ubo_buffer_sizes,
            ARRAY_SIZE(ubo_buffer_sizes),
            r->device_props.limits.minUniformBufferOffsetAlignment);

    bool need_descriptor_write_reset =
        need_descriptor_write &&
        (r->descriptor_set_index >= ARRAY_SIZE(r->descriptor_sets));

    if (need_descriptor_write_reset || need_ubo_staging_buffer_reset) {
        pgraph_vk_finish(pg, VK_FINISH_REASON_NEED_BUFFER_SPACE);
        need_uniform_write = true;
        need_descriptor_write = true;
        target_descriptor_state_valid = false;
    }

    if (need_uniform_write) {
        upload_uniform_buffers(pg, layouts);
    }

    /*
     * UBO bindings use dynamic offsets, so changing uniform contents only needs
     * a new buffer slice. The descriptor set itself only has to be rewritten
     * when the shader layout or sampled textures change.
     */
    if (!need_descriptor_write) {
        return;
    }

    if (!target_descriptor_state_valid) {
        init_descriptor_set_state(r, layouts, &target_descriptor_state);
    }

    assert(r->descriptor_set_index < ARRAY_SIZE(r->descriptor_sets));

    /*
     * Descriptor sets outlive command buffers. If the next reusable slot
     * already contains the required UBO ranges and sampled images, we can
     * rotate to it directly without issuing another vkUpdateDescriptorSets.
     */
    if (descriptor_set_state_equal(
            &r->descriptor_set_states[r->descriptor_set_index],
            &target_descriptor_state)) {
        r->descriptor_set_index++;
        return;
    }

    VkWriteDescriptorSet descriptor_writes[2 + NV2A_MAX_TEXTURES];

    VkDescriptorBufferInfo ubo_buffer_infos[2];
    for (int i = 0; i < ARRAY_SIZE(layouts); i++) {
        ubo_buffer_infos[i] = (VkDescriptorBufferInfo){
            .buffer = r->storage_buffers[BUFFER_UNIFORM].buffer,
            .offset = 0,
            .range = layouts[i]->total_size,
        };
        descriptor_writes[i] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = r->descriptor_sets[r->descriptor_set_index],
            .dstBinding = i == 0 ? VSH_UBO_BINDING : PSH_UBO_BINDING,
            .dstArrayElement = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 1,
            .pBufferInfo = &ubo_buffer_infos[i],
        };
    }

    VkDescriptorImageInfo image_infos[NV2A_MAX_TEXTURES];
    for (int i = 0; i < NV2A_MAX_TEXTURES; i++) {
        image_infos[i] = (VkDescriptorImageInfo){
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = r->texture_bindings[i]->image_view,
            .sampler = r->texture_samplers[i]->sampler,
        };
        descriptor_writes[2 + i] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = r->descriptor_sets[r->descriptor_set_index],
            .dstBinding = PSH_TEX_BINDING + i,
            .dstArrayElement = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .pImageInfo = &image_infos[i],
        };
    }

    vkUpdateDescriptorSets(r->device, 6, descriptor_writes, 0, NULL);

    r->descriptor_set_states[r->descriptor_set_index] = target_descriptor_state;
    r->descriptor_set_index++;
}

static void update_shader_uniform_locs(ShaderBinding *binding)
{
    for (int i = 0; i < ARRAY_SIZE(binding->vsh.uniform_locs); i++) {
        binding->vsh.uniform_locs[i] = uniform_index(
            &binding->vsh.module_info->uniforms, VshUniformInfo[i].name);
    }

    for (int i = 0; i < ARRAY_SIZE(binding->psh.uniform_locs); i++) {
        binding->psh.uniform_locs[i] = uniform_index(
            &binding->psh.module_info->uniforms, PshUniformInfo[i].name);
    }
}

static ShaderModuleInfo *
get_and_ref_shader_module_for_key(PGRAPHVkState *r,
                                  const ShaderModuleCacheKey *key)
{
    uint64_t hash = fast_hash((void *)key, sizeof(ShaderModuleCacheKey));
    LruNode *node = lru_lookup(&r->shader_module_cache, hash, key);
    ShaderModuleCacheEntry *module =
        container_of(node, ShaderModuleCacheEntry, node);
    pgraph_vk_ref_shader_module(module->module_info);
    return module->module_info;
}

static void shader_cache_entry_init(Lru *lru, LruNode *node, const void *state)
{
    PGRAPHVkState *r = container_of(lru, PGRAPHVkState, shader_cache);
    ShaderBinding *binding = container_of(node, ShaderBinding, node);
    memcpy(&binding->state, state, sizeof(ShaderState));

    NV2A_VK_DPRINTF("cache miss");
    nv2a_profile_inc_counter(NV2A_PROF_SHADER_GEN);

    ShaderModuleCacheKey key;

    bool need_geometry_shader = pgraph_glsl_need_geom(&binding->state.geom);
    if (need_geometry_shader) {
        memset(&key, 0, sizeof(key));
        key.kind = VK_SHADER_STAGE_GEOMETRY_BIT;
        key.geom.state = binding->state.geom;
        key.geom.glsl_opts.vulkan = true;
        binding->geom.module_info = get_and_ref_shader_module_for_key(r, &key);
    } else {
        binding->geom.module_info = NULL;
    }

    memset(&key, 0, sizeof(key));
    key.kind = VK_SHADER_STAGE_VERTEX_BIT;
    key.vsh.state = binding->state.vsh;
    key.vsh.glsl_opts.vulkan = true;
    key.vsh.glsl_opts.prefix_outputs = need_geometry_shader;
    key.vsh.glsl_opts.use_push_constants_for_uniform_attrs =
        r->use_push_constants_for_uniform_attrs;
    key.vsh.glsl_opts.ubo_binding = VSH_UBO_BINDING;
    binding->vsh.module_info = get_and_ref_shader_module_for_key(r, &key);

    memset(&key, 0, sizeof(key));
    key.kind = VK_SHADER_STAGE_FRAGMENT_BIT;
    key.psh.state = binding->state.psh;
    key.psh.glsl_opts.vulkan = true;
    key.psh.glsl_opts.ubo_binding = PSH_UBO_BINDING;
    key.psh.glsl_opts.tex_binding = PSH_TEX_BINDING;
    binding->psh.module_info = get_and_ref_shader_module_for_key(r, &key);

    update_shader_uniform_locs(binding);
}

static void shader_cache_entry_post_evict(Lru *lru, LruNode *node)
{
    PGRAPHVkState *r = container_of(lru, PGRAPHVkState, shader_cache);
    ShaderBinding *snode = container_of(node, ShaderBinding, node);

    ShaderModuleInfo *modules[] = {
        snode->vsh.module_info,
        snode->geom.module_info,
        snode->psh.module_info,
    };
    for (int i = 0; i < ARRAY_SIZE(modules); i++) {
        if (modules[i]) {
            pgraph_vk_unref_shader_module(r, modules[i]);
        }
    }
}

static bool shader_cache_entry_compare(Lru *lru, LruNode *node, const void *key)
{
    ShaderBinding *snode = container_of(node, ShaderBinding, node);
    return memcmp(&snode->state, key, sizeof(ShaderState));
}

static void shader_module_cache_entry_init(Lru *lru, LruNode *node,
                                           const void *key)
{
    PGRAPHVkState *r = container_of(lru, PGRAPHVkState, shader_module_cache);
    ShaderModuleCacheEntry *module =
        container_of(node, ShaderModuleCacheEntry, node);
    memcpy(&module->key, key, sizeof(ShaderModuleCacheKey));
    MString *code;

    switch (module->key.kind) {
    case VK_SHADER_STAGE_VERTEX_BIT:
        code = pgraph_glsl_gen_vsh(&module->key.vsh.state,
                                   module->key.vsh.glsl_opts);
        break;
    case VK_SHADER_STAGE_GEOMETRY_BIT:
        code = pgraph_glsl_gen_geom(&module->key.geom.state,
                                    module->key.geom.glsl_opts);
        break;
    case VK_SHADER_STAGE_FRAGMENT_BIT:
        code = pgraph_glsl_gen_psh(&module->key.psh.state,
                                   module->key.psh.glsl_opts);
        break;
    default:
        assert(!"Invalid shader module kind");
        code = NULL;
    }

    module->module_info = pgraph_vk_create_shader_module_from_glsl(
        r, module->key.kind, mstring_get_str(code));
    pgraph_vk_ref_shader_module(module->module_info);
    mstring_unref(code);
}

static void shader_module_cache_entry_post_evict(Lru *lru, LruNode *node)
{
    PGRAPHVkState *r = container_of(lru, PGRAPHVkState, shader_module_cache);
    ShaderModuleCacheEntry *module =
        container_of(node, ShaderModuleCacheEntry, node);
    pgraph_vk_unref_shader_module(r, module->module_info);
    module->module_info = NULL;
}

static bool shader_module_cache_entry_compare(Lru *lru, LruNode *node,
                                              const void *key)
{
    ShaderModuleCacheEntry *module =
        container_of(node, ShaderModuleCacheEntry, node);
    return memcmp(&module->key, key, sizeof(ShaderModuleCacheKey));
}

static void shader_cache_init(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    const size_t shader_cache_size = 1024;
    lru_init(&r->shader_cache);
    r->shader_cache_entries = g_malloc_n(shader_cache_size, sizeof(ShaderBinding));
    assert(r->shader_cache_entries != NULL);
    for (int i = 0; i < shader_cache_size; i++) {
        lru_add_free(&r->shader_cache, &r->shader_cache_entries[i].node);
    }
    r->shader_cache.init_node = shader_cache_entry_init;
    r->shader_cache.compare_nodes = shader_cache_entry_compare;
    r->shader_cache.post_node_evict = shader_cache_entry_post_evict;

    /* FIXME: Make this configurable */
    const size_t shader_module_cache_size = 50 * 1024;
    lru_init(&r->shader_module_cache);
    r->shader_module_cache_entries =
        g_malloc_n(shader_module_cache_size, sizeof(ShaderModuleCacheEntry));
    assert(r->shader_module_cache_entries != NULL);
    for (int i = 0; i < shader_module_cache_size; i++) {
        lru_add_free(&r->shader_module_cache,
                     &r->shader_module_cache_entries[i].node);
    }

    r->shader_module_cache.init_node = shader_module_cache_entry_init;
    r->shader_module_cache.compare_nodes = shader_module_cache_entry_compare;
    r->shader_module_cache.post_node_evict =
        shader_module_cache_entry_post_evict;
}

static void shader_cache_finalize(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    lru_flush(&r->shader_cache);
    g_free(r->shader_cache_entries);
    r->shader_cache_entries = NULL;

    lru_flush(&r->shader_module_cache);
    g_free(r->shader_module_cache_entries);
    r->shader_module_cache_entries = NULL;
}

static ShaderBinding *get_shader_binding_for_state(PGRAPHVkState *r,
                                                   const ShaderState *state)
{
    uint64_t hash = fast_hash((void *)state, sizeof(*state));
    LruNode *node = lru_lookup(&r->shader_cache, hash, state);
    ShaderBinding *binding = container_of(node, ShaderBinding, node);
    NV2A_VK_DPRINTF("shader state hash: %016" PRIx64 " %p", hash, binding);
    return binding;
}

static bool samples_scaled_surface_texture(PGRAPHVkState *r)
{
    for (int i = 0; i < NV2A_MAX_TEXTURES; i++) {
        TextureBinding *binding = r->texture_bindings[i];
        if (binding && binding->key.scale > 1.0f) {
            return true;
        }
    }

    return false;
}

static bool uses_depth_stencil(PGRAPHState *pg)
{
    uint32_t control_0 = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0);
    uint32_t control_1 = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_1);

    return (control_0 & NV_PGRAPH_CONTROL_0_ZENABLE) ||
           pgraph_zeta_write_enabled(pg) ||
           (control_1 & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
}

static ShaderState get_shader_state_for_vk(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;
    ShaderState state = pgraph_glsl_get_shader_state(pg);

    if (samples_scaled_surface_texture(r) && !uses_depth_stencil(pg)) {
        state.vsh.apply_scaled_pixel_center_bias = false;
        state.psh.apply_scaled_pixel_center_bias = false;
    }

    return state;
}

static void apply_uniform_updates(ShaderUniformLayout *layout,
                                  const UniformInfo *info, int *locs,
                                  void *values, size_t count)
{
    for (int i = 0; i < count; i++) {
        if (locs[i] != -1) {
            uniform_copy(layout, locs[i], (char*)values + info[i].val_offs,
                         4, (info[i].size * info[i].count) / 4);
        }
    }
}

/*
 * Keep Vulkan uniform uploads conservative. Several shader inputs are derived
 * from mixed PGRAPH state, texture state, and generated values, and reusing old
 * dynamic UBO offsets across command buffers can desynchronize recorded draws
 * from the data later copied out of the staging buffer.
 */
static void update_shader_uniforms(PGRAPHState *pg)
{
    NV2A_VK_DGROUP_BEGIN("%s", __func__);

    PGRAPHVkState *r = pg->vk_renderer_state;
    nv2a_profile_inc_counter(NV2A_PROF_SHADER_BIND);

    assert(r->shader_binding);
    ShaderBinding *binding = r->shader_binding;

    VshUniformValues vsh_values;
    pgraph_glsl_set_vsh_uniform_values(pg, &binding->state.vsh,
                                  binding->vsh.uniform_locs, &vsh_values);
    apply_uniform_updates(&binding->vsh.module_info->uniforms, VshUniformInfo,
                          binding->vsh.uniform_locs, &vsh_values,
                          VshUniform__COUNT);

    PshUniformValues psh_values;
    pgraph_glsl_set_psh_uniform_values(pg, binding->psh.uniform_locs,
                                       &psh_values);
    for (int i = 0; i < 4; i++) {
        assert(r->texture_bindings[i] != NULL);
        float scale = get_texture_uniform_scale(r, i);

        psh_values.texScale[i] = scale;
    }
    apply_uniform_updates(&binding->psh.module_info->uniforms, PshUniformInfo,
                          binding->psh.uniform_locs, &psh_values,
                          PshUniform__COUNT);

    r->uniforms_changed = true;
    nv2a_profile_inc_counter(NV2A_PROF_SHADER_UBO_DIRTY);

    NV2A_VK_DGROUP_END();
}

void pgraph_vk_bind_shaders(PGRAPHState *pg)
{
    NV2A_VK_DGROUP_BEGIN("%s", __func__);

    PGRAPHVkState *r = pg->vk_renderer_state;

    r->shader_bindings_changed = false;

    ShaderState new_state = get_shader_state_for_vk(pg);
    if (!r->shader_binding || memcmp(&r->shader_binding->state, &new_state,
                                     sizeof(ShaderState))) {
        r->shader_binding = get_shader_binding_for_state(r, &new_state);
        r->shader_bindings_changed = true;
    } else {
        nv2a_profile_inc_counter(NV2A_PROF_SHADER_BIND_NOTDIRTY);
    }

    update_shader_uniforms(pg);

    NV2A_VK_DGROUP_END();
}

void pgraph_vk_init_shaders(PGRAPHState *pg)
{
    PGRAPHVkState *r = pg->vk_renderer_state;

    pgraph_vk_init_glsl_compiler();
    create_descriptor_pool(pg);
    create_descriptor_set_layout(pg);
    create_descriptor_sets(pg);
    shader_cache_init(pg);

    r->use_push_constants_for_uniform_attrs =
        (r->device_props.limits.maxPushConstantsSize >=
         MAX_UNIFORM_ATTR_VALUES_SIZE);
}

void pgraph_vk_finalize_shaders(PGRAPHState *pg)
{
    shader_cache_finalize(pg);
    destroy_descriptor_sets(pg);
    destroy_descriptor_set_layout(pg);
    destroy_descriptor_pool(pg);
    pgraph_vk_finalize_glsl_compiler();
}
