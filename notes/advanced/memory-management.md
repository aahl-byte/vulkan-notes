<link rel="stylesheet" href="./css/globals.css">

# memory management

A real Vulkan app at runtime holds thousands of buffers and images — mesh data, textures, uniform blocks, staging scratch space, render targets. If you called `vkAllocateMemory` for every one of them you would hit the driver's hard limit (typically ~4 096 total allocations) within seconds, and every call is slow. The goal of memory management is to make **very few large allocations** from the driver, then carve them up yourself. Everything below is the strategy for doing that.

---

## the coarse model

GPU memory is exposed as a small number of <em>heaps</em> — physical pools of memory. A discrete GPU typically has one fast heap on the GPU itself (device-local VRAM) and one slower heap in system RAM that the GPU reaches across the bus. Each heap offers one or more <em>memory types</em>, which differ in whether the CPU can access them and how caching behaves.

The core strategy: make a few large `vkAllocateMemory` calls, then partition each block yourself and hand sub-ranges to individual resources. The driver only counts the large allocations — not how you subdivide them. The rest of this page makes that precise.

---

## heaps and types — what the driver exposes

<em>A memory heap is a physical pool; a memory type is a usage flavor within a heap.</em>

Call `vkGetPhysicalDeviceMemoryProperties` and you get two arrays:

- `memoryHeaps[]` — each entry is a physical budget: its size and whether it is device-local (`VK_MEMORY_HEAP_DEVICE_LOCAL_BIT`). A discrete GPU typically exposes two heaps: ~8 GB of VRAM and ~16 GB of system RAM. An integrated GPU often exposes one heap for both.
- `memoryTypes[]` — each entry is a flavor, identified by which heap it draws from and a `propertyFlags` bitmask. Only these flags matter in practice:

| Flag | Means |
|------|-------|
| `VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT` | lives in VRAM — fastest GPU access |
| `VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` | CPU can map and write to it |
| `VK_MEMORY_PROPERTY_HOST_COHERENT_BIT` | CPU writes are immediately visible to the GPU; no explicit flush needed |
| `VK_MEMORY_PROPERTY_HOST_CACHED_BIT` | reads are cached on the CPU; fast for CPU readback, requires flush/invalidate |

### picking a type

`vkGetBufferMemoryRequirements` (or the image variant) returns a `memoryTypeBits` field — a bitmask where bit *i* is set if type *i* is compatible with this resource. You iterate the types, check the bit, then check your desired `propertyFlags`:

```cpp
uint32_t findMemoryType(VkPhysicalDevice physDev,
                        uint32_t         typeBits,
                        VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mem;
    vkGetPhysicalDeviceMemoryProperties(physDev, &mem);

    for (uint32_t i = 0; i < mem.memoryTypeCount; i++) {
        bool compatible    = (typeBits >> i) & 1;
        bool hasAllProps   = (mem.memoryTypes[i].propertyFlags & props) == props;
        if (compatible && hasAllProps)
            return i;
    }
    throw std::runtime_error("no suitable memory type");
}
```

The concept: you ask for the *minimum* set of property flags your use case requires. Device-local-only resources ask only for `DEVICE_LOCAL`. Staging buffers ask for `HOST_VISIBLE | HOST_COHERENT`.

### the special case — ReBAR

<em>ReBAR (Resizable BAR) is a memory type that is both `DEVICE_LOCAL` and `HOST_VISIBLE`.</em>

On systems that support it (most modern discrete GPUs with the feature enabled in firmware), one memory type carries both flags. It lets the CPU write directly into VRAM — no staging copy required. Useful for:

- Per-frame uniform data updated every frame (small, frequently changing)
- Mesh streaming on high-bandwidth systems

Not universally available, so always probe for it; fall back to the staging pattern if absent.

---

## the staging pattern

A resource that lives in `DEVICE_LOCAL` memory cannot be mapped by the CPU — the CPU has no direct path to VRAM. You bridge the gap with a temporary buffer in host-visible memory, then issue a GPU-side copy.

**The pattern, step by step:**

1. Allocate a *staging buffer* with `VK_BUFFER_USAGE_TRANSFER_SRC_BIT` in `HOST_VISIBLE | HOST_COHERENT` memory.
2. `vkMapMemory` → `memcpy` your data in → `vkUnmapMemory`.
3. Allocate your *destination resource* (buffer or image) in `DEVICE_LOCAL` memory with `VK_BUFFER_USAGE_TRANSFER_DST_BIT`.
4. Record `vkCmdCopyBuffer` or `vkCmdCopyBufferToImage` into a command buffer and submit it.
5. Wait for the transfer queue to finish (fence or semaphore), then destroy the staging buffer.

```cpp
// CPU side — fill the staging buffer
void* ptr;
vkMapMemory(device, stagingMemory, 0, dataSize, 0, &ptr);
memcpy(ptr, srcData, dataSize);
vkUnmapMemory(device, stagingMemory);

// GPU side — copy to device-local destination
VkBufferCopy region{ .srcOffset = 0, .dstOffset = 0, .size = dataSize };
vkCmdCopyBuffer(cmd, stagingBuffer, destBuffer, 1, &region);
```

### when to stage vs map directly

Staging is worth the overhead for resources that are written once (or rarely) and read many times by the GPU. For small, per-frame data the round-trip cost is not worth it.

| Situation | Strategy |
|-----------|----------|
| Static mesh data, textures, BLAS geometry | stage into `DEVICE_LOCAL` |
| Per-frame uniform buffers (small, changes every frame) | map `HOST_VISIBLE` directly; skip staging |
| CPU readback (screenshots, query results) | use `HOST_VISIBLE | HOST_CACHED`; invalidate before reading |
| ReBAR available + per-frame data is large | write directly to `DEVICE_LOCAL | HOST_VISIBLE`; no staging |

How staging fits into a full frame is shown in [./a-real-world-frame.md](./a-real-world-frame.md).

---

## sub-allocation — making one big block serve many resources

<em>Sub-allocation means the app allocates one large `VkDeviceMemory` block from the driver, then partitions it internally and hands ranges to individual resources.</em>

The driver caps `vkAllocateMemory` calls (the Vulkan spec minimum is 4 096; drivers rarely go higher). Sub-allocation lets you stay orders of magnitude under that cap.

### alignment constraints you must satisfy

Two hardware-mandated alignment rules apply when you pack resources into a block:

- **`bufferImageGranularity`** — when a linear resource (buffer) and a non-linear resource (image) share the same `VkDeviceMemory`, they must be separated by at least this many bytes (typically 64 KB on desktop GPUs). Pack buffers together and images together; avoid interleaving them in the same block unless you pad for granularity.
- **`nonCoherantAtomSize`** — when manually flushing non-coherent memory, the flush range start and size must be multiples of this value (typically 64 bytes). It only matters if you chose a non-coherent memory type.

Both values come from `VkPhysicalDeviceLimits`.

### a pool allocator in one sentence

Keep a free-list of ranges within each block; when a resource is destroyed, return its range to the free-list. Coalesce adjacent free ranges to prevent fragmentation.

### aliasing memory between transient resources

Two resources whose lifetimes do not overlap may share the same memory range — the G-buffer normals texture and the shadow map might both live at offset 0 in the same block if they are never live at the same time. This is valid in Vulkan provided you issue the correct barriers between uses. Useful for tightly-constrained memory budgets.

---

## why use VMA instead of writing this yourself

The Vulkan Memory Allocator (VMA) is an MIT-licensed C library (with a C++ wrapper) by AMD that implements everything above:

- Type selection using a preference priority: tries device-local first, falls back gracefully.
- Sub-allocation with internal pools, alignment handling, `bufferImageGranularity` padding.
- Optional defragmentation pass.
- Optional `VMA_MEMORY_USAGE_AUTO` which picks the right type based on usage flags — no manual `findMemoryType` needed.

```cpp
VmaAllocationCreateInfo allocInfo{};
allocInfo.usage = VMA_MEMORY_USAGE_AUTO;
allocInfo.flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT; // for staging

VkBuffer buffer;
VmaAllocation alloc;
vmaCreateBuffer(allocator, &bufferCI, &allocInfo, &buffer, &alloc, nullptr);
```

### roll your own vs VMA — the choice

| | Roll your own | Use VMA |
|--|--------------|---------|
| Control | total | high (pools, custom types still accessible) |
| Correctness risk | high — alignment bugs are silent | low — extensively tested |
| Defragmentation | you write it | built-in |
| Time to ship | days–weeks | minutes |

**Recommendation:** use VMA as the default. Write your own allocator only if VMA's internal structure genuinely conflicts with your architecture (rare). The coarse strategy — few big allocations, sub-divided — is what matters; VMA implements that strategy correctly.

---

## flushing non-coherent memory

<em>HOST_COHERENT memory makes CPU writes automatically visible to the GPU. HOST_CACHED without COHERENT requires explicit synchronization.</em>

If you allocate a non-coherent type (has `HOST_CACHED` but not `HOST_COHERENT`):

- After writing on the CPU, call `vkFlushMappedMemoryRanges` before the GPU reads. This pushes the cached writes into the backing memory where the GPU can see them.
- Before reading on the CPU (readback), call `vkInvalidateMappedMemoryRanges` so the CPU cache reflects what the GPU wrote.

Both calls require ranges aligned to `nonCoherantAtomSize`. This is why staging buffers use `HOST_COHERENT` — you never want to think about flushing in the hot upload path.

For the available/visible distinction that explains why these calls exist at all, see [../foundation/buffers-and-memory.md](../foundation/buffers-and-memory.md).

---

## the strategy, restated

- Make ~tens of `vkAllocateMemory` calls; sub-allocate everything else yourself (or let VMA do it).
- Stage static data into device-local. Map host-visible directly for small, per-frame data.
- Respect `bufferImageGranularity` when mixing buffers and images in one block.
- Prefer `HOST_COHERENT` for staging buffers to avoid manual flushing.
- Use VMA unless there is a specific reason not to.
