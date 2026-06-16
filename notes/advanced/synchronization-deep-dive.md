<link rel="stylesheet" href="./css/globals.css">

# synchronization deep-dive

GPU work runs as fast as physics allows — thousands of operations overlapping in time. Synchronization is not about slowing that down. It is about stating the exact ordering constraints that correctness requires, and nothing more. The goal is **maximum parallelism within the rules**, not safety through brute-force serialization.

This page is the authoritative treatment of Vulkan's synchronization primitives. Earlier pages — the [render loop](../rendering/the-render-loop.md), compute [barriers and async](../compute/compute-barriers-and-async.md) — deferred the full picture here.

---

## the mental model: a massively pipelined machine

The GPU is not a sequential processor that happens to be fast. It is a deep pipeline — vertex fetch, rasterization, depth testing, fragment shading, blending, memory writeback — and dozens of draw calls are in-flight across those stages simultaneously. Two operations that touch the same memory can overlap unless you explicitly say they cannot.

Vulkan gives you the language to say exactly what must not overlap: the `vkCmdPipelineBarrier` family and a small set of other primitives. No more, no less.

### two completely separate problems

Think of a relay race. Two things have to be true before the baton can safely change hands:

1. The first runner must reach the exchange zone — that is an **execution dependency**: stage A must finish before stage B can start.
2. The baton must physically be in the second runner's hand, not still rolling across the track — that is a **memory dependency**: the written data must travel from where A left it to where B can read it.

Vulkan requires you to state both. Getting only one right is still a data race.

#### the cache problem — available then visible

Modern GPUs have a hierarchy of caches, just like CPUs. A write from a fragment shader lands in that shader's L1 cache first. Before another stage — say, a texture sampler — can see it, two things must happen:

- <em>available</em>: the write is flushed out of the source cache into a shared backing store (like L2 or main GPU memory).
- <em>visible</em>: the destination cache (the sampler's cache) is invalidated so it will re-fetch from that backing store.

Beginners expect "flush the write" to be enough. It is not. If the destination still holds a stale cache line from before the write, it reads the old value. Both the flush (make available) and the invalidation (make visible) are required. Vulkan's access masks control exactly these two operations.

A correct coarse model: **execution dependency** = ordering in time; **memory dependency** = cache flush + cache invalidate. You need both when the same memory is written then read.

---

## pipeline stages and access masks

The two-part dependency maps directly to two pairs of fields on every barrier.

### stage masks: when

`srcStageMask` and `dstStageMask` answer the execution question:

- `srcStageMask` — which pipeline stages of the *before* work must complete.
- `dstStageMask` — which pipeline stages of the *after* work must wait.

Common stages:

| stage flag | what it covers |
|---|---|
| `VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT` | writing to color attachments |
| `VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT` | fragment shader reads/writes |
| `VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT` | compute shader reads/writes |
| `VK_PIPELINE_STAGE_TRANSFER_BIT` | `vkCmdCopy*`, `vkCmdBlit*` |
| `VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT` | logical start — before any stage |
| `VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT` | logical end — after all stages |
| `VK_PIPELINE_STAGE_ALL_COMMANDS_BIT` | everything (useful for debugging, not shipping) |

### access masks: what moved through caches

`srcAccessMask` and `dstAccessMask` answer the memory question:

- `srcAccessMask` — which kinds of writes to flush (make available).
- `dstAccessMask` — which kinds of reads/writes to invalidate for (make visible).

Common access flags:

| access flag | meaning |
|---|---|
| `VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT` | color attachment was written |
| `VK_ACCESS_SHADER_READ_BIT` | shader reads (sampled image, storage buffer, etc.) |
| `VK_ACCESS_SHADER_WRITE_BIT` | shader writes |
| `VK_ACCESS_TRANSFER_WRITE_BIT` | transfer destination write |
| `VK_ACCESS_TRANSFER_READ_BIT` | transfer source read |
| `VK_ACCESS_MEMORY_READ_BIT` | any read — broad, for read-side invalidation |
| `VK_ACCESS_MEMORY_WRITE_BIT` | any write — broad, for flush |

### a worked barrier: render-target to sampled image

Scenario: you rendered a color attachment in one pass. Now you want to sample it in a shader in the next pass.

```cpp
VkImageMemoryBarrier barrier{};
barrier.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
barrier.srcAccessMask       = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; // flush the write
barrier.dstAccessMask       = VK_ACCESS_SHADER_READ_BIT;            // invalidate before the read
barrier.oldLayout           = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
barrier.newLayout           = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
barrier.image               = colorImage;
barrier.subresourceRange    = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

vkCmdPipelineBarrier(
    cmd,
    VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,  // src: after attachment writes finish
    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,          // dst: before fragment shader reads
    0,           // dependency flags
    0, nullptr,  // memory barriers
    0, nullptr,  // buffer barriers
    1, &barrier  // image barrier
);
```

Reading the barrier out loud: "wait until color attachment output finishes, flush the color-attachment write, then let fragment shading start, with the sampler cache invalidated." The layout transition from `COLOR_ATTACHMENT_OPTIMAL` to `SHADER_READ_ONLY_OPTIMAL` is also declared here — image layout transitions are a synchronization operation in Vulkan.

### synchronization2 — the cleaner version

`VK_KHR_synchronization2` (core in Vulkan 1.3) replaces the split-mask confusion with unified stage+access flags per side, and bundles everything into `VkDependencyInfo`:

```cpp
VkImageMemoryBarrier2 barrier2{};
barrier2.sType         = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
barrier2.srcStageMask  = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
barrier2.srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
barrier2.dstStageMask  = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
barrier2.dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
// ... layout and image fields ...

VkDependencyInfo depInfo{};
depInfo.sType                   = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
depInfo.imageMemoryBarrierCount = 1;
depInfo.pImageMemoryBarriers    = &barrier2;

vkCmdPipelineBarrier2(cmd, &depInfo);
```

Prefer sync2 for new code. The stage and access flags are better named, per-barrier is easier to reason about, and `VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT` finally covers all transfer ops in one flag.

---

## the full primitive lineup

Vulkan provides five tools. Each has a specific role and a specific scope. Reaching for the wrong one either doesn't work or pays an unnecessary cost.

### pipeline barriers (within a submission)

A pipeline barrier inside a command buffer creates a dependency between commands *recorded before it* and commands *recorded after it*, within the same queue submission. This is the workhorse: it handles both memory and execution dependencies in one call.

Three flavors — global memory barrier, buffer memory barrier, image memory barrier — let you scope the cost. An image barrier is more expensive than a buffer barrier because the driver may need to perform a layout transition. Use the narrowest scope that is correct.

- Use when: same queue, two operations touch the same resource.
- Does: execution dep + memory dep + optional image layout transition.

### subpass dependencies (within a render pass)

Render passes have multiple subpasses. The transition between them uses `VkSubpassDependency` (or `VkSubpassDependency2`) in the render pass descriptor, not a barrier in the command buffer.

Subpass dependencies are conceptually identical to pipeline barriers, but scoped inside the render pass — the driver can use them to schedule tile-based operations more efficiently on mobile hardware. If you render to an attachment in subpass 0 and read it in subpass 1, declare a dependency between them rather than ending the render pass to insert a barrier.

- Use when: attachment produced in one subpass is consumed in another subpass of the same render pass.
- Does: execution dep + memory dep — driver may optimize across subpass boundaries.

### events — split barriers

A pipeline barrier is a wall between *before* and *after*. An event splits that wall in two: `vkCmdSetEvent` marks the end of the source work; `vkCmdWaitEvents` declares where the destination work must wait. GPU work between the set and the wait point can still run.

Events allow you to overlap the source synchronization cost with unrelated work. They are underused and harder to reason about. For most cases, a regular pipeline barrier is clearer.

- Use when: you want to overlap unrelated GPU work between the source dependency and the destination wait.
- Does: the same execution + memory dependency as a barrier, but split at two points in the command buffer.

### semaphores — queue-to-queue ordering

A semaphore orders work across queues (or across submissions to the same queue). See [commands and queues](../foundation/commands-and-queues.md) for the queue model that semaphores sit on top of.

#### binary semaphore

The original Vulkan 1.0 primitive. One queue signals it on submit; another queue waits on it on submit. Binary: can only be signaled once before being waited on.

```cpp
// Submit to graphics queue; signal the semaphore when done
VkSubmitInfo submitInfo{};
submitInfo.signalSemaphoreCount = 1;
submitInfo.pSignalSemaphores    = &renderFinishedSemaphore;
vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);

// Submit to present queue; wait on the semaphore before presenting
VkPresentInfoKHR presentInfo{};
presentInfo.waitSemaphoreCount = 1;
presentInfo.pWaitSemaphores    = &renderFinishedSemaphore;
vkQueuePresentKHR(presentQueue, &presentInfo);
```

The render loop uses a semaphore exactly this way. See [the render loop](../rendering/the-render-loop.md) for the full per-frame setup.

#### timeline semaphore

A <em>timeline semaphore</em> replaces the binary signal/wait dance with a monotonically-increasing counter. Instead of "signal once, wait once," you signal a value (say, 5) and wait for a value (say, 5 or greater). Multiple waiters can wait on the same value; you can wait on CPU or GPU side.

```cpp
// Create
VkSemaphoreTypeCreateInfo typeInfo{};
typeInfo.sType         = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
typeInfo.initialValue  = 0;

VkSemaphoreCreateInfo semCI{};
semCI.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
semCI.pNext = &typeInfo;
vkCreateSemaphore(device, &semCI, nullptr, &timelineSemaphore);

// GPU wait: signal value 1 after this batch
VkTimelineSemaphoreSubmitInfo tlSubmit{};
tlSubmit.signalSemaphoreValueCount = 1;
uint64_t signalVal = 1;
tlSubmit.pSignalSemaphoreValues    = &signalVal;

// CPU wait: block until the GPU has signaled >= 1
VkSemaphoreWaitInfo waitInfo{};
waitInfo.sType          = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
waitInfo.semaphoreCount = 1;
waitInfo.pSemaphores    = &timelineSemaphore;
waitInfo.pValues        = &signalVal;
vkWaitSemaphores(device, &waitInfo, UINT64_MAX);
```

Timeline semaphores are the modern general-purpose synchronization tool:

- Replace most uses of binary semaphores and fences.
- Enable CPU–GPU and GPU–GPU synchronization with one object.
- Allow multiple frames in flight without a fence-per-frame or ring of binary semaphores.
- Core in Vulkan 1.2.

When to use binary vs timeline:

| situation | use |
|---|---|
| swapchain acquire/present (requires binary by spec) | binary semaphore |
| GPU→GPU between queues | timeline semaphore |
| CPU waiting on GPU completion | timeline semaphore (or fence) |
| frame-in-flight tracking | timeline semaphore |

### fences — GPU-to-CPU notification

A fence signals the CPU when a GPU submission completes. You submit with a fence, then call `vkWaitForFences` on the CPU to block until the GPU is done.

```cpp
// Submit with a fence
vkQueueSubmit(graphicsQueue, 1, &submitInfo, frameFence);

// CPU blocks until the GPU signals the fence
vkWaitForFences(device, 1, &frameFence, VK_TRUE, UINT64_MAX);
vkResetFences(device, 1, &frameFence);
```

Fences cannot synchronize GPU work to GPU work — they exist only for the CPU to know the GPU is done (so it can safely free resources, map buffers, or start the next frame).

Timeline semaphores can replace fences for most CPU-wait scenarios. Fences remain useful for their simplicity and for integrating with Vulkan's swapchain operations.

- Use when: CPU must know a GPU batch has finished (read-back, resource teardown, simple frame pacing).
- Does not do: GPU→GPU ordering.

### comparison: which primitive for what

| need | primitive |
|---|---|
| two passes touch the same buffer/image, same queue | pipeline barrier |
| two subpasses share an attachment | subpass dependency |
| overlap unrelated GPU work around a dependency | event |
| one queue signals, another waits | semaphore (binary or timeline) |
| CPU waits for GPU batch to finish | fence or timeline semaphore |
| swapchain acquire/present ordering | binary semaphore |
| general-purpose GPU↔GPU and CPU↔GPU | timeline semaphore |

---

## the cardinal sins

### over-synchronization — correct but slow

Inserting `ALL_COMMANDS → ALL_COMMANDS` barriers everywhere, or signaling a fence after every submit, is safe. It also serializes the GPU completely and throws away the parallelism Vulkan was built to expose.

Signs you are over-synchronizing:
- GPU utilization drops between commands where you expect overlap.
- You reach for `VK_PIPELINE_STAGE_ALL_COMMANDS_BIT` in production code.
- Every compute dispatch has a full barrier before it even when the previous dispatch wrote to a different buffer.

### under-synchronization — fast but corrupt

Skipping barriers when they are actually needed produces undefined behavior. The GPU may read stale data, see torn values, or operate on an image in the wrong layout. The results are often non-deterministic: correct on one driver, broken on another, or correct at one resolution and broken at another.

Signs you are under-synchronizing:
- Validation layers report hazards (`SYNC-HAZARD-WRITE_AFTER_WRITE`, `SYNC-HAZARD-READ_BEFORE_WRITE`).
- Visual corruption appears only at certain workloads or on certain hardware.
- Removing a barrier makes a test pass but breaks another.

The goal is the <em>minimal correct dependency</em>: the narrowest stage masks, the narrowest access masks, and no barrier at all when none is needed.

---

## how this connects to the rest of the site

Synchronization is the mechanism that makes everything else safe at scale:

- The [render loop](../rendering/the-render-loop.md) uses binary semaphores for swapchain acquire/present ordering and fences for CPU frame-pacing — the specific calls now have a complete model behind them.
- The compute [barriers and async](../compute/compute-barriers-and-async.md) page works through practical barrier placement for compute-to-compute and compute-to-graphics handoffs — the access mask choices trace directly back to the flush/invalidate model here.
- [Commands and queues](../foundation/commands-and-queues.md) is the substrate: queues are the unit of submission, semaphores are the queue-level ordering tool, and barriers live inside the command buffers that queues execute.
- [Multithreading and performance](./multithreading-and-performance.md) builds on this page: recording command buffers in parallel is safe precisely because you can express the inter-buffer dependencies with the primitives above, and the compiler-like analysis of what actually needs to be ordered is the same skill.
