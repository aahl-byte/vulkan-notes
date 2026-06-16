<link rel="stylesheet" href="./css/globals.css">

# compute barriers & async

You run a compute dispatch that fills a buffer, then a second dispatch that reads it. In any other programming environment you'd assume the results are there. On the GPU, they may not be — and Vulkan won't warn you. This page is about making one piece of GPU work **safely see another's results**.

---

## the problem: "after" in code is not "after" on the GPU

The GPU is a deeply pipelined, out-of-order factory. Hundreds of shader threads are in flight at once, and the hardware actively reorders operations to keep its execution units busy. "Dispatch B comes after dispatch A in my command buffer" only means B was *submitted* after A. It does **not** mean A's writes have reached memory — or that B's caches have been told to look for them — by the time B's first thread reads.

Think of a large factory with many parallel assembly lines and its own internal mail system. One line finishes producing parts and puts them in an outbox. Another line needs those parts, but unless someone stops both lines at a checkpoint, posts the new stock, and tells the receiving line "the inbox is updated," the second line may grab whatever was sitting on the shelf before the first line was done. The checkpoint is the barrier.

Without a barrier between dispatch A and dispatch B:

- A's writes may still be sitting in a write buffer, not yet visible in main GPU memory.
- B's shader caches may hold stale data from before A ran.
- The GPU may even start B's threads before all of A's threads have finished.

A <em>pipeline barrier</em> is the explicit checkpoint that closes those gaps. You install it between the two dispatches in your command buffer.

---

## what a barrier actually controls

A barrier does two independent jobs. Both are required for a read-after-write to be safe.

### execution dependency

Guarantees **completion order**: all work in A that the barrier cites must reach a specified pipeline stage before any work in B that the barrier cites is allowed to begin that stage.

- `srcStageMask` — the stage(s) in A that must finish first.
- `dstStageMask` — the stage(s) in B that must wait.

For compute dispatches both are `VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT`. The barrier says: "every compute shader invocation in A must complete its shader stage before any compute shader invocation in B begins."

Execution dependency alone is not enough. It stops B from *starting*, but caches may still hold stale data.

### memory dependency

Guarantees **visibility**: A's writes are flushed out of internal caches (made *available*) and B's caches are invalidated so it re-fetches (made *visible* to B).

- `srcAccessMask` — how A was writing: `VK_ACCESS_SHADER_WRITE_BIT`.
- `dstAccessMask` — how B will read: `VK_ACCESS_SHADER_READ_BIT`.

Together, the two dependencies close the race: A finishes, its writes are flushed, then B is allowed to start reading from fresh data.

---

## the three hazard types

Three hazard patterns exist between any two pieces of GPU work. Know them by name — they tell you which direction the dependency arrow points.

| hazard | what happens | example |
|---|---|---|
| <em>read-after-write</em> (RAW) | B reads data A wrote | fill buffer → process buffer |
| write-after-read (WAR) | B overwrites data A was reading | process buffer → clear buffer |
| write-after-write (WAW) | B overwrites data A wrote | two passes both write the same buffer |

RAW is by far the most common compute case. Every "dispatch A fills a buffer, dispatch B consumes it" pattern is RAW. The fix is always a barrier with `SHADER_WRITE → SHADER_READ`.

WAR and WAW hazards also require barriers but the access masks differ. The full stage and access taxonomy — including layout transitions for images and the `VK_DEPENDENCY_BY_REGION_BIT` flag — lives in [../advanced/synchronization-deep-dive.md](../advanced/synchronization-deep-dive.md).

---

## writing the barrier in C++

The concept first: you're inserting a `vkCmdPipelineBarrier` call between the two dispatch calls in the same command buffer. It carries a `VkBufferMemoryBarrier` that names the SSBO being handed off.

```cpp
VkBufferMemoryBarrier bufBarrier{};
bufBarrier.sType               = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
bufBarrier.srcAccessMask       = VK_ACCESS_SHADER_WRITE_BIT;
bufBarrier.dstAccessMask       = VK_ACCESS_SHADER_READ_BIT;
bufBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;  // same queue
bufBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
bufBarrier.buffer              = mySSBO;
bufBarrier.offset              = 0;
bufBarrier.size                = VK_WHOLE_SIZE;

vkCmdDispatch(cmd, groupsX, groupsY, groupsZ);  // dispatch A — fills mySSBO

vkCmdPipelineBarrier(
    cmd,
    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // srcStageMask: A's stage
    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // dstStageMask: B's stage
    0,                                       // dependencyFlags
    0, nullptr,                              // no global memory barriers
    1, &bufBarrier,                          // our buffer barrier
    0, nullptr                               // no image barriers
);

vkCmdDispatch(cmd, groupsX, groupsY, groupsZ);  // dispatch B — reads mySSBO
```

A few details worth noting:

- `srcQueueFamilyIndex` and `dstQueueFamilyIndex` are both `VK_QUEUE_FAMILY_IGNORED` when both dispatches run on the **same queue family** — no ownership transfer needed.
- `size = VK_WHOLE_SIZE` covers the whole buffer; narrow it if you know only a sub-range is in play.
- The barrier sits *between* the two dispatch calls, not after both. Order in the command buffer is how you express which work is A and which is B.

For how dispatches themselves work and what `groupsX/Y/Z` means, see [./dispatch-and-workgroups.md](./dispatch-and-workgroups.md). For the queue and command buffer mechanics, see [../foundation/commands-and-queues.md](../foundation/commands-and-queues.md).

---

## async compute: overlapping work on a separate queue

Most barriers so far assume both dispatches share the same queue. GPUs often expose a **dedicated compute queue family** — separate hardware units that can run compute work *in parallel* with the graphics queue, not just interleaved with it. This is async compute.

What you gain: a long compute dispatch (say, skinning or particle simulation) can be in flight at the same time as the GPU draws the previous frame's geometry. True overlap, not just a different scheduling order.

What it costs:

- You no longer use `vkCmdPipelineBarrier` alone — cross-queue sync requires **semaphores** to serialize submission, plus a <em>queue family ownership transfer</em> barrier (the same `VkBufferMemoryBarrier`, but with `srcQueueFamilyIndex` and `dstQueueFamilyIndex` filled in) on both the releasing and acquiring queue.
- Debugging becomes harder: two queues running independently means timing-dependent bugs that may not reproduce under validation layers.

#### when async compute is worth it

- The compute work is long enough to actually overlap with something else. Short dispatches are dominated by synchronization overhead.
- The compute and graphics workloads genuinely use different GPU resources (the compute queue has its own shader units on some hardware).
- You have the engineering bandwidth to manage the extra sync objects correctly.

If in doubt, start with a single queue and a pipeline barrier. Add a dedicated compute queue only once profiling shows the graphics queue is the bottleneck and overlap would help.

The full queue-family and semaphore mechanics are in [../foundation/commands-and-queues.md](../foundation/commands-and-queues.md). Advanced synchronization primitives (timeline semaphores, events) are in [../advanced/synchronization-deep-dive.md](../advanced/synchronization-deep-dive.md).

---

## summary

- The GPU does not guarantee that dispatch A's writes are visible to dispatch B just because A was submitted first.
- A pipeline barrier installs an explicit checkpoint: execution dependency (A finishes before B starts) + memory dependency (A's writes are flushed and B's caches are invalidated).
- For the common compute RAW case: `srcStage/dstStage = COMPUTE_SHADER`, `srcAccess = SHADER_WRITE`, `dstAccess = SHADER_READ`, with a `VkBufferMemoryBarrier` on the SSBO.
- Three hazard patterns exist — RAW, WAR, WAW — RAW is the one to recognize on sight.
- Async compute (a separate compute queue family) enables true overlap with graphics but requires semaphores and ownership transfers on top of barriers.
