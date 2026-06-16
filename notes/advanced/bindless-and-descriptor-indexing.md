<link rel="stylesheet" href="./css/globals.css">

# bindless & descriptor indexing

A modern renderer draws thousands of objects — each with a different albedo map, normal map, material buffer. In the classic descriptor model from [descriptors](../foundation/descriptors.md), each unique combination of resources requires its own bound descriptor set. The CPU spends its frame budget on `vkCmdBindDescriptorSets` calls, layout compatibility checks, and descriptor set management, and the GPU has to stop and re-read new binding state between every draw.

<em>Bindless</em> is the escape from that loop. Instead of telling the GPU "here is the resource for this draw," you upload every resource into one giant global array at startup and then just tell the GPU "use index 42." The shader looks up the resource itself. The CPU never rebinds.

This is what makes GPU-driven rendering possible — and it's available as a first-class Vulkan feature since Vulkan 1.2.

---

## the problem — one draw, one set

The classic one-set-per-draw model works well when you have a handful of materials. At scale, it breaks down in three ways.

- **Per-draw CPU overhead.** Every object that uses a different texture means a `vkCmdBindDescriptorSets` call. At 10,000 objects that's 10,000 binding commands per frame — before any geometry is even submitted.
- **Pipeline layout churn.** Descriptor set layouts are baked into the pipeline. Switching sets with incompatible layouts forces a pipeline state change, which stalls the GPU.
- **Incompatibility with GPU-driven rendering.** If the GPU is generating draw calls itself (via an indirect draw buffer), the CPU can't interleave `vkCmdBindDescriptorSets` between them — the GPU is in charge of the draw stream, not the CPU.

The underlying assumption in the classic model — that the CPU picks the right resource before every draw — falls apart as scene complexity grows. Bindless inverts that assumption.

---

## the mental model — index into one big array

Bindless replaces "bind the right resource before this draw" with "load every resource once, then pass an index."

- One enormous descriptor array holds every resource — tens of thousands of combined image samplers, all in a single binding slot.
- Each object carries a material index, stored per-object in a buffer or supplied through a push constant.
- The shader reads that index and reaches directly into the array: `texture(textures[idx], uv)`.

The CPU's only job is to populate the array at load time and give each object its index. There is no descriptor rebinding during the draw loop.

---

## the moving parts

### VK_EXT_descriptor_indexing (core in Vulkan 1.2)

The extension that makes this possible. In Vulkan 1.2 and later it is promoted to core, but you still have to explicitly enable the features you use. The relevant ones are queried from `VkPhysicalDeviceDescriptorIndexingFeatures`:

- <em>runtimeDescriptorArray</em> — allows GLSL to declare arrays without a compile-time size: `sampler2D textures[]`. Without this you need a fixed upper bound.
- <em>descriptorBindingPartiallyBound</em> — allows the array to have gaps: you can allocate 4096 slots but only fill 800 of them. The shader must promise not to access the empty ones.
- <em>descriptorBindingUpdateAfterBind</em> — allows you to update the descriptor array after you've already recorded command buffers that reference it. Critical for streaming assets in at runtime.
- <em>descriptorBindingVariableDescriptorCount</em> — allows the last binding in a layout to have a count decided at allocation time (rather than layout-creation time). Lets you create one layout and allocate arrays of different sizes from it.

Enable what you need during device creation:

```cpp
VkPhysicalDeviceDescriptorIndexingFeatures indexingFeatures{};
indexingFeatures.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES;
indexingFeatures.runtimeDescriptorArray                    = VK_TRUE;
indexingFeatures.descriptorBindingPartiallyBound           = VK_TRUE;
indexingFeatures.descriptorBindingUpdateAfterBind          = VK_TRUE;
indexingFeatures.descriptorBindingSampledImageUpdateAfterBind = VK_TRUE;

VkPhysicalDeviceFeatures2 features2{};
features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
features2.pNext = &indexingFeatures;

VkDeviceCreateInfo deviceInfo{};
deviceInfo.pNext = &features2;
// ... rest of device creation
```

### the big descriptor array

Instead of a layout binding with `descriptorCount = 1`, you declare a binding with a large count — tens of thousands of combined image samplers. This one binding covers every texture in the scene.

```cpp
VkDescriptorSetLayoutBinding bigArrayBinding{};
bigArrayBinding.binding         = 0;
bigArrayBinding.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
bigArrayBinding.descriptorCount = 65536; // the whole texture table
bigArrayBinding.stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT;
```

The key is the binding flags you attach to it, which require a `VkDescriptorSetLayoutBindingFlagsCreateInfo` chained onto the layout create info.

### binding flags — what each permits

<em>update-after-bind</em> (`VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT`) and <em>partially bound</em> (`VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT`) are the two workhorses:

```cpp
VkDescriptorBindingFlags bindingFlags =
    VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT |
    VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT   |
    VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;

VkDescriptorSetLayoutBindingFlagsCreateInfo flagsInfo{};
flagsInfo.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
flagsInfo.bindingCount  = 1;
flagsInfo.pBindingFlags = &bindingFlags;

VkDescriptorSetLayoutCreateInfo layoutInfo{};
layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
layoutInfo.pNext = &flagsInfo;
layoutInfo.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
// ...
```

And the pool must match:

```cpp
poolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;
```

| flag | what it unlocks |
|------|----------------|
| `UPDATE_AFTER_BIND_BIT` | descriptor writes can happen after the set is bound in a command buffer — essential for streaming textures |
| `PARTIALLY_BOUND_BIT` | slots in the array can be empty, as long as the shader never accesses them |
| `VARIABLE_DESCRIPTOR_COUNT_BIT` | the last binding's count is set at allocation time, not layout-creation time |

### the GLSL side — nonuniformEXT

The shader side is where the "indexing" in descriptor indexing lives. You declare the array without a fixed size, and index into it with an integer.

```glsl
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform sampler2D textures[];

layout(push_constant) uniform PC {
    uint textureIndex;
} pc;

void main() {
    vec4 color = texture(textures[nonuniformEXT(pc.textureIndex)], inUV);
    outColor = color;
}
```

The `nonuniformEXT` wrapper around the index is not optional. Without it, the GPU assumes every thread in a warp uses the *same* index — a "uniform" value — and can short-circuit the lookup. In practice different fragments will have different `textureIndex` values (a dragon uses texture 12, the floor uses texture 847). Without `nonuniformEXT` the results are undefined; some drivers will silently use the wrong texture, others will crash. It's a one-word fix for a very confusing bug.

---

## how indices flow — the data path

The data flow is simple once you see it laid out:

```
CPU (load time)
  ↓  upload every texture, write descriptors into slot [0..N] of the big array
  ↓  store per-object material index in an SSBO or push constant

GPU (draw time, per fragment/vertex)
  ↓  read materialIndex from push constant or per-instance SSBO
  ↓  textures[nonuniformEXT(materialIndex)]  ← single array lookup
  ↓  sample, shade, output
```

There are two common ways to pass the index to the shader:

- **Push constants** — simplest. One `uint` pushed per draw. Fine when you're still issuing individual draws from the CPU; `vkCmdPushConstants` is cheaper than `vkCmdBindDescriptorSets`.
- **Per-instance SSBO** — for GPU-driven rendering, store material indices in a buffer indexed by `gl_InstanceIndex` or `gl_DrawID`. The GPU reads its own index with no CPU involvement per draw.

---

## tradeoffs — when it's worth it vs classic sets

Bindless is not free. It trades binding overhead for a different set of costs.

### go bindless when

- The scene has hundreds or thousands of unique materials/textures.
- You want GPU-driven rendering (indirect draws, compute-generated draw calls).
- You need to stream assets in and out at runtime without rebuilding descriptor sets.
- CPU draw-call overhead is a measured bottleneck.

See [a real-world frame](./a-real-world-frame.md) for where bindless sits in the pipeline of a production renderer.

### stick with classic sets when

- You have a small, fixed set of materials (menu UI, simple mobile game).
- Your team is just learning Vulkan — bindless adds surface area before the classic model is comfortable.
- You need broad device compatibility: `VK_EXT_descriptor_indexing` is core in 1.2, but not all older drivers implement every feature cleanly.

### what bindless costs

- **Harder debugging.** A missing `nonuniformEXT`, a partially-bound slot accidentally accessed, or an index that's off by one produces incorrect rendering rather than a validation error. You lose the compile-time safety of "this binding must be a specific type."
- **Shader complexity.** Shaders that can access any texture in the scene are harder to reason about statically; GPU-assisted validation (`VK_EXT_descriptor_indexing` validation features) helps but adds overhead.
- **Driver maturity.** `UPDATE_AFTER_BIND` on some older drivers (especially mobile) had subtle bugs. Test early on target hardware.
- **Synchronization responsibility.** Because you can update descriptors after binding, you own the guarantee that the GPU isn't reading a slot you're writing. The driver can't infer this anymore.

---

## summary

- The classic model from [descriptors](../foundation/descriptors.md) binds a unique set per material — fine for small scenes, hostile to GPU-driven rendering at scale.
- Bindless replaces "bind the right resource" with "pass an integer and let the shader index."
- The mechanism: a single huge descriptor array, enabled by `VK_EXT_descriptor_indexing` features (`runtimeDescriptorArray`, `partiallyBound`, `updateAfterBind`).
- The two critical flags: `PARTIALLY_BOUND` (allow gaps) and `UPDATE_AFTER_BIND` (allow runtime streaming).
- In GLSL, always wrap a non-uniform index with `nonuniformEXT` — skipping it silently gives wrong results.
- Indices flow via push constants (simple) or per-instance SSBOs (GPU-driven).
- Bindless pays off at scale and is essential for GPU-driven rendering; it costs debugging clarity and adds synchronization responsibility.
