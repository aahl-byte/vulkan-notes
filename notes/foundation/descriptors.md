<link rel="stylesheet" href="./css/globals.css">

# descriptors

A shader running on the GPU needs to read your buffer or sample your texture. But shaders can't take pointers — there's no heap, no address space to share with the CPU. So how does a shader say "give me that buffer"?

That's the job of the descriptor system. It is the binding glue between the resources you create on the CPU side (see [buffers and memory](./buffers-and-memory.md)) and the slots your shader declares it expects. Get this model right and a huge piece of Vulkan clicks into place.

---

## the mental model — numbered slots the shader reads from

A shader declares the resources it expects as numbered slots — a `set` number and a `binding` number for each — right in the GLSL. It never names a specific buffer or address; it just reads from "set 0, binding 0."

- A <em>descriptor set</em> is a collection of those slots, each pointed at an actual GPU resource you created.
- Before a draw or dispatch, you bind the set to the pipeline. From then on, the shader's `set`/`binding` references resolve to the resources you pointed those slots at.

You connect resources to slots, not pointers to memory. Vulkan translates that into whatever the hardware actually needs to locate the data.

---

## the moving parts

Five things collaborate to make this work. Here they are in the order you create them, with what each one is *for*.

### descriptor set layout — the shape

A <em>descriptor set layout</em> (`VkDescriptorSetLayout`) describes the *shape* of a set: how many slots, what type each slot is, and which shader stages can see it. No actual resources live here — just the blueprint.

```cpp
VkDescriptorSetLayoutBinding uboBinding{};
uboBinding.binding         = 0;
uboBinding.descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
uboBinding.descriptorCount = 1;
uboBinding.stageFlags      = VK_SHADER_STAGE_VERTEX_BIT;

VkDescriptorSetLayoutCreateInfo layoutInfo{};
layoutInfo.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
layoutInfo.bindingCount = 1;
layoutInfo.pBindings    = &uboBinding;

VkDescriptorSetLayout layout;
vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr, &layout);
```

This layout is baked into the pipeline at creation time — the pipeline needs to know what shape of set it expects. This is why you pass layouts to `VkPipelineLayout` when building the graphics or compute pipeline (see [the graphics pipeline object](../rendering/the-graphics-pipeline-object.md)).

### descriptor pool — the allocator

A <em>descriptor pool</em> (`VkDescriptorPool`) is a pre-allocated block of memory for descriptor sets. You tell it upfront how many sets of each type you'll need, and it hands them out without going back to the driver.

```cpp
VkDescriptorPoolSize poolSize{};
poolSize.type            = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
poolSize.descriptorCount = 10; // room for 10 uniform buffer descriptors

VkDescriptorPoolCreateInfo poolInfo{};
poolInfo.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
poolInfo.poolSizeCount = 1;
poolInfo.pPoolSizes    = &poolSize;
poolInfo.maxSets       = 10;

VkDescriptorPool pool;
vkCreateDescriptorPool(device, &poolInfo, nullptr, &pool);
```

The pool is pre-reserved memory for sets: you allocate sets from it instead of going back to the driver each time.

### descriptor set — the filled-in instance

A <em>descriptor set</em> (`VkDescriptorSet`) is one concrete instance of the layout, allocated from the pool. It starts empty — you still have to wire in the actual resources.

```cpp
VkDescriptorSetAllocateInfo allocInfo{};
allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
allocInfo.descriptorPool     = pool;
allocInfo.descriptorSetCount = 1;
allocInfo.pSetLayouts        = &layout;

VkDescriptorSet descriptorSet;
vkAllocateDescriptorSets(device, &allocInfo, &descriptorSet);
```

### vkUpdateDescriptorSets — wiring the resources in

`vkUpdateDescriptorSets` is where you point each slot at an actual buffer or image.

```cpp
VkDescriptorBufferInfo bufferInfo{};
bufferInfo.buffer = myUniformBuffer; // the VkBuffer you created
bufferInfo.offset = 0;
bufferInfo.range  = sizeof(MyUniformData);

VkWriteDescriptorSet write{};
write.sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
write.dstSet          = descriptorSet;
write.dstBinding      = 0;          // matches binding = 0 in the layout
write.descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
write.descriptorCount = 1;
write.pBufferInfo     = &bufferInfo;

vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
```

You can call this as often as you like (outside a render pass), so per-frame or per-object updates are fine.

### vkCmdBindDescriptorSets — binding the set

Finally, at draw/dispatch time, you bind the filled set to the pipeline. From this point, the shader can read from its numbered slots.

```cpp
vkCmdBindDescriptorSets(
    commandBuffer,
    VK_PIPELINE_BIND_POINT_GRAPHICS, // or COMPUTE
    pipelineLayout,
    0,              // set index (which "set" slot to plug into)
    1, &descriptorSet,
    0, nullptr      // dynamic offsets — covered separately
);
```

---

## the shader side — matching set + binding

The GLSL declaration must mirror the layout exactly. The numbers are the contract between CPU and GPU.

```glsl
// vertex shader
layout(set = 0, binding = 0) uniform UniformData {
    mat4 modelViewProj;
} ubo;

void main() {
    gl_Position = ubo.modelViewProj * vec4(inPosition, 1.0);
}
```

`set = 0` means the first descriptor set bound at index 0. `binding = 0` matches the `binding` field in `VkDescriptorSetLayoutBinding`. If these numbers disagree, validation layers will tell you — the GPU will do something undefined.

---

## descriptor types — which one when

Different resource shapes need different descriptor types. This is the "when to reach for it" list:

### `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER`
- Small, read-only, CPU-written data: transforms, lighting constants, material params.
- The GPU implementation is often a dedicated fast path for small constant data.
- **Use when:** the shader reads it but never writes it, and the data is small (kilobytes, not megabytes).

### `VK_DESCRIPTOR_TYPE_STORAGE_BUFFER` (SSBO)
- Large, read-write buffers accessible in shaders.
- Compute shaders live here — particle systems, physics, culling, terrain — anything that needs to write results back.
- See [compute pipelines and shaders](../compute/compute-pipelines-and-shaders.md) for how SSBOs anchor the compute workflow.
- **Use when:** the data is large, the shader writes to it, or you need arbitrary indexing.

### `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`
- A texture and its sampler bundled together — the most common way to bring a texture into a fragment shader.
- **Use when:** you're sampling a texture in a fragment (or any) shader and sampling behavior is fixed at bind time.

### `VK_DESCRIPTOR_TYPE_STORAGE_IMAGE`
- An image the shader can read from and write to at arbitrary coordinates — no sampler involved.
- Used for image-processing compute shaders (blur passes, mip generation, post-processing).
- **Use when:** a compute shader needs to write pixels directly into an image.

---

## the key mental separation — layout vs set

This split is the thing that unlocks efficient Vulkan resource management:

- <em>Layout</em> — the shape. Declared once, baked into the pipeline. Think "compile time." It says: "this pipeline expects a uniform buffer at set 0 binding 0 and a combined image sampler at set 0 binding 1."
- <em>Set</em> — the contents. Filled in and swapped freely. Think "per frame" or "per object." It says: "right now, binding 0 is *this specific* buffer, and binding 1 is *this specific* texture."

Because the pipeline only cares about the shape, you can swap sets without touching the pipeline. Multiple objects can share one layout but each hold their own set — one shape, many filled-in instances.

```
Pipeline         VkDescriptorSetLayout   VkDescriptorSet
──────────       ─────────────────────   ──────────────────────────────
graphics     ←── [ set0: ubo + sampler ] ←── { ubo → myBuffer, sampler → myTexture }
pipeline                                  ←── { ubo → otherBuffer, sampler → otherTex }
```

This is efficient — but it does require you to allocate, fill, and track one set per unique combination of resources. At scale (hundreds of objects, many textures), that management burden grows. It also means you can't index into a resource array dynamically in the shader without extensions.

That tension is exactly what [bindless and descriptor indexing](../advanced/bindless-and-descriptor-indexing.md) solves — worth reading once the model here is comfortable.

---

## summary

- Shaders can't take pointers, so Vulkan uses **numbered slots**: declare them in a layout, fill them in a set, bind the set before drawing.
- The five pieces: layout (shape), pool (allocator), set (instance), `vkUpdateDescriptorSets` (wiring), `vkCmdBindDescriptorSets` (binding).
- The GLSL `layout(set=, binding=)` declaration is the contract — it must match the layout exactly.
- Choose descriptor type by read/write and size: uniform buffer for small constants, SSBO for large/writeable, combined image sampler for textures, storage image for writeable images.
- Keep layout (shape) and set (contents) mentally separate — that split is how you efficiently manage per-object resources.
