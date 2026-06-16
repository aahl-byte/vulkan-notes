<link rel="stylesheet" href="./css/globals.css">

# buffers & memory

your GPU needs somewhere to put things — vertex data, textures, uniform constants, simulation state. in Vulkan, you are responsible for creating that space yourself and wiring it to the objects that use it. this page is about that: where GPU data lives, how you bring it into existence, and how you get it there from the CPU.

---

## memory and resources are separate things

Vulkan splits "a block of memory" from "a thing that uses memory," and you wire them together yourself.

- <em>VkDeviceMemory</em> is a raw allocation of bytes — no type, no layout, just storage.
- A **resource handle** (`VkBuffer`, `VkImage`) describes the *shape* of some data — "this is a vertex buffer," "this is a 512×512 RGBA texture." It holds no storage on its own.
- **Binding** (`vkBindBufferMemory` / `vkBindImageMemory`) attaches a resource handle to a region of a memory allocation. Until you bind, the handle is a description without a home.

This is the opposite of `malloc`, which allocates space and hands you a usable pointer in one step. Vulkan separates allocation from the resource on purpose, and that separation is the whole story — it's what lets you allocate once and place many resources inside that one block.

---

## the two resource types

Vulkan draws a hard line between two shapes of data.

### VkBuffer — linear bytes

<em>VkBuffer</em> is a flat, untyped sequence of bytes. it has no notion of format, dimensions, or layout — it's just a run of memory you can slice and interpret however you need.

reach for a `VkBuffer` when the data is:

- **vertex data** — the positions, normals, UVs that feed the vertex shader
- **index data** — the triangle index lists that reference vertex data
- **uniform data** — per-draw constants (matrices, material params) read by shaders
- **storage buffers (SSBOs)** — large read/write arrays used in compute or rendering
- **transfer staging** — a CPU-writable scratch buffer used to load data into GPU-only memory (more on this below)

because it's just bytes, a single `VkBuffer` can hold multiple kinds of data with manual offsets — vertex data for multiple meshes, for example.

### VkImage — multi-dimensional, formatted, tiled

<em>VkImage</em> is a multi-dimensional resource with an explicit format, extent, and mip chain. the GPU driver is free to store it in a vendor-specific tiled layout that is faster to sample.

reach for a `VkImage` when the data is:

- **textures** — color maps, normal maps, environment maps
- **render targets** — the color and depth attachments your pipeline writes to
- **swapchain images** — the final frames displayed to screen (these are pre-created for you by the swapchain)

the key contrast: `VkBuffer` is what you read/write with raw byte offsets; `VkImage` is what you sample with coordinates, format conversions, and filtering. shaders access them through fundamentally different descriptor types — see [./descriptors.md](./descriptors.md).

---

## the two-step that surprises newcomers

in most APIs, creating a resource also allocates its memory. in Vulkan, those are deliberately separate steps.

**step 1: create the resource handle**

you describe the shape of the resource (size, usage flags, format). Vulkan gives you back an opaque handle — a `VkBuffer` or `VkImage`. at this point it has no backing storage.

```cpp
VkBufferCreateInfo bufferInfo{};
bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
bufferInfo.size  = sizeof(Vertex) * vertexCount;
bufferInfo.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

VkBuffer vertexBuffer;
vkCreateBuffer(device, &bufferInfo, nullptr, &vertexBuffer);
```

**step 2: query, allocate, and bind**

you ask Vulkan what the resource actually needs (`vkGetBufferMemoryRequirements`), pick a compatible memory type from the physical device, allocate a `VkDeviceMemory` block, then bind it to the handle.

```cpp
VkMemoryRequirements memReqs;
vkGetBufferMemoryRequirements(device, vertexBuffer, &memReqs);

VkMemoryAllocateInfo allocInfo{};
allocInfo.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
allocInfo.allocationSize  = memReqs.size;
allocInfo.memoryTypeIndex = findMemoryType(memReqs.memoryTypeBits,
                                VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

VkDeviceMemory bufferMemory;
vkAllocateMemory(device, &allocInfo, nullptr, &bufferMemory);

vkBindBufferMemory(device, vertexBuffer, bufferMemory, /*offset=*/0);
```

#### why the separation?

because you control placement. a single `VkDeviceMemory` allocation can back multiple resources at different offsets (sub-allocation). allocating once and partitioning it yourself is dramatically faster than calling `vkAllocateMemory` per resource — the driver has limits on how many allocations the GPU supports, often in the low thousands. in practice, most applications use a library like VMA to manage this; the deep strategy is in [../advanced/memory-management.md](../advanced/memory-management.md).

---

## memory properties — coarse view

when you call `findMemoryType`, you're filtering by **memory property flags**. two matter immediately:

### DEVICE_LOCAL — fast, GPU-side

<em>DEVICE_LOCAL</em> memory lives on the GPU's own VRAM. the GPU can read and write it at full speed. the CPU generally cannot access it directly. this is where your final vertex buffers, textures, and render targets should live.

### HOST_VISIBLE — mappable from the CPU

<em>HOST_VISIBLE</em> memory can be mapped with `vkMapMemory` so the CPU can write directly into it. the trade-off: on discrete GPUs, host-visible memory is often in system RAM (or a small CPU-accessible slice of VRAM) and is slower for the GPU to read.

#### the staging pattern in one sentence

to get data into DEVICE_LOCAL memory: write it into a HOST_VISIBLE staging buffer first, then issue a copy command that the GPU executes — [./commands-and-queues.md](./commands-and-queues.md) covers how those commands are recorded and submitted.

---

## when to map directly vs when to stage

the choice is simple at this level:

| situation | approach |
|---|---|
| data changes every frame (uniforms, per-frame params) | HOST_VISIBLE + `vkMapMemory` — avoid the copy overhead |
| data is written once, read many times (meshes, textures) | stage through HOST_VISIBLE, copy to DEVICE_LOCAL, discard staging buffer |
| integrated GPU (shared memory) | HOST_VISIBLE is often also DEVICE_LOCAL — check both flags, skip staging |

- **map directly** when: the CPU writes the data every frame anyway, latency from the copy would add more than the bandwidth savings gain
- **stage** when: the data is static or rarely updated and the GPU will read it millions of times — the one-time copy cost is trivial against a frame's worth of faster reads

the full nuance — write-combining, persistent mapping, HOST_COHERENT vs HOST_CACHED, heap budgets — is in [../advanced/memory-management.md](../advanced/memory-management.md).

---

## how the pieces connect

once your buffer is allocated and bound, you don't pass it directly to a draw call the way you'd pass a pointer. for uniform buffers and storage buffers, you point shaders at them through descriptor sets — [./descriptors.md](./descriptors.md) is the mechanism for that. vertex and index buffers are bound directly in command buffers at draw time, which is part of how [./commands-and-queues.md](./commands-and-queues.md) works.

the model to carry forward: **you allocate the memory, you create the resources, and you move the data in yourself.** Vulkan exposes each of those steps separately; wiring them together is your job.
