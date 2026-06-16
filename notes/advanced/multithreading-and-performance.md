<link rel="stylesheet" href="./css/globals.css">

# multithreading & performance

A AAA frame might issue 50,000 draw calls. A single CPU thread recording those calls sequentially cannot keep a modern GPU fed — the bottleneck is the CPU, not the hardware you paid for. Vulkan's headline answer is that command recording is designed to happen on all your cores at once, so the GPU never waits for one thread to catch up.

This page is about how you actually get that win — and the cost discipline that makes every other Vulkan decision add up.

---

## the shape of the problem

Think of a film crew shooting a feature. One director calling every shot sequentially is the bottleneck. The smart answer is a second-unit crew filming in parallel: each team records its own footage independently, and the editor assembles the final cut at the end.

Vulkan's model works the same way:

- Each thread records its own **command buffer** — the footage reel.
- A <em>command pool</em> is the thread's private supply of recording equipment.
- Queue submission — handing the assembled reels to the GPU — happens once, from a single hand-off point.

The critical insight: recording is where the CPU time lives. Submission is cheap. Maximize parallel recording, minimize the cost of submission.

For the basics of how command buffers and queues work, see [commands & queues](../foundation/commands-and-queues.md).

---

## the threading model

### what you can do in parallel

Vulkan is explicit about thread safety so you can reason about it precisely.

These operations are <em>free-threaded</em> — no external synchronization required:

- Creating and destroying objects (pipelines, descriptor sets, buffers, image views, …)
- Recording into separate command buffers from separate threads
- Allocating memory from separate allocators

These operations require <em>external synchronization</em> — protect them yourself:

- Any two operations on the **same** `VkCommandPool` from different threads (the pool is not internally synchronized)
- Any two operations on the **same** `VkQueue` from different threads (queue submission must be serialized)
- Any two operations on the **same** `VkDevice` object when the spec says "externally synchronized" (rare outside of pools and queues)

The rule of thumb: object *creation* is safe; shared *mutation* is not.

### one pool per thread

The central pattern is <em>one pool per thread</em> — give each recording thread its own `VkCommandPool` and allocate command buffers from it exclusively. Because no two threads share a pool, recording is fully parallel with zero locking.

```cpp
// At startup: one pool per thread
std::vector<VkCommandPool> threadPools(threadCount);
for (int i = 0; i < threadCount; ++i) {
    VkCommandPoolCreateInfo info{};
    info.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    info.queueFamilyIndex = graphicsFamily;
    info.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    vkCreateCommandPool(device, &info, nullptr, &threadPools[i]);
}

// Each thread records independently into its own buffer
// (no mutex needed — different pools)
```

### secondary command buffers

When you want to record pieces in parallel and then assemble them into one submission, reach for <em>secondary command buffers</em>.

- A **primary** command buffer is submitted to a queue. It can execute secondary buffers inside a render pass.
- A **secondary** command buffer records a portion of work (a range of draw calls, a set of dispatches) and is executed by the primary via `vkCmdExecuteCommands`.

The pattern:

1. Spin up N threads. Each thread records a secondary command buffer from its own pool covering its slice of the draw list.
2. The main thread assembles a primary command buffer, calls `vkCmdExecuteCommands` with all N secondaries inside the render pass.
3. Submit the primary to the queue — one submission, N threads' worth of recording work.

```cpp
// Sketch: parallel secondary recording, then assembly
std::vector<VkCommandBuffer> secondaries(threadCount);

// Each runs on its own thread, its own pool
auto recordThread = [&](int i) {
    VkCommandBufferInheritanceInfo inherit{};
    inherit.sType      = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    inherit.renderPass = mainRenderPass;
    inherit.subpass    = 0;

    VkCommandBufferBeginInfo begin{};
    begin.sType            = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags            = VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT;
    begin.pInheritanceInfo = &inherit;

    vkBeginCommandBuffer(secondaries[i], &begin);
    // ... record draws[i * sliceSize .. (i+1) * sliceSize] ...
    vkEndCommandBuffer(secondaries[i]);
};

// Join threads, then assemble
vkCmdExecuteCommands(primaryCmd, threadCount, secondaries.data());
```

### submitting from one thread

Queue submission is inexpensive but must be serialized. The cleanest approach: one dedicated submission thread, or a mutex around every `vkQueueSubmit` call. Batching multiple `VkSubmitInfo` structures into a single `vkQueueSubmit` call is always cheaper than multiple separate submits — the driver does less work per batch.

---

## the cost model

Vulkan's philosophy is "you control the cost." Every operation has a price; here is where the budget goes:

### barriers and layout transitions

Every `vkCmdPipelineBarrier` stall is CPU and GPU time spent on synchronization. The GPU must drain in-flight work before the barrier takes effect. Unnecessary barriers are one of the most common Vulkan perf mistakes.

The discipline: insert barriers at the latest possible moment, with the narrowest possible scope. See [synchronization deep dive](./synchronization-deep-dive.md) for how to size them correctly.

### descriptor set changes

Binding a new descriptor set mid-frame has overhead — it may force the driver to re-validate state or flush caches. The cost rises with the frequency of changes.

- Sort draws so they share descriptor sets as long as possible.
- Use push constants for per-draw data that changes every call — they are the cheapest mechanism for small updates.
- At scale, bindless descriptors eliminate per-draw binding entirely (covered in `./bindless.md`).

### pipeline switches

Switching `VkPipeline` (the compiled shader + fixed-function state object) forces the GPU's shader cache to flush. Minimize switches by sorting draw calls by pipeline. A <em>pipeline cache</em> (`VkPipelineCache`) amortizes the compile cost across runs and devices — always create one, serialize it to disk at shutdown, and restore it at startup.

### allocations

`vkAllocateMemory` is a slow path — the driver calls into the OS. In practice a single frame should call `vkAllocateMemory` zero times: allocate large blocks up front and sub-allocate from them using offsets. See `./memory-management.md` for the sub-allocation pattern.

### render pass load/store ops

On tiled GPUs (most mobile, Apple Silicon, many integrated GPUs) the `loadOp` and `storeOp` on each attachment control whether attachment data is read from or written to main memory at render pass boundaries:

- `LOAD_OP_CLEAR` + `STORE_OP_DONT_CARE` for a color attachment you clear and never read back = no main-memory traffic. Free.
- `LOAD_OP_LOAD` = read the previous frame's pixels from memory. Costs bandwidth.
- `STORE_OP_STORE` = write the result to memory. Costs bandwidth.

Be deliberate. The depth buffer is often `DONT_CARE` for both — never read back, cleared at start, discarded at end.

---

## practical wins

These are the highest-leverage changes, roughly ordered by effort-to-payoff ratio.

### pre-record and reuse command buffers

If a pass produces the same commands every frame (a shadow map with static geometry, a fullscreen blit), record the command buffer once and resubmit it repeatedly. The CPU recording cost becomes zero. Use `VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT` only on pools whose buffers you actually reset; static buffers live in a pool without that flag.

### batch submits aggressively

Each `vkQueueSubmit` call has a fixed driver overhead. Submit once per frame with all work batched into one call rather than submitting after each pass. If multiple passes share a queue, pack their `VkSubmitInfo` structs into a single submit.

### minimize host-visible round-trips

Reading data back from the GPU to the CPU (mapping a host-visible buffer, calling `vkMapMemory`, reading it) inserts an implicit GPU-CPU sync — the CPU waits for the GPU to finish writing. This kills parallelism.

- Avoid per-frame readbacks unless required (occlusion queries, statistics).
- When you need readback, double-buffer the result: read frame N-1's data while frame N is still in flight.

### timeline semaphores reduce CPU stalls

Binary semaphores require the CPU to track which signals have been consumed. <em>Timeline semaphores</em> (`VkSemaphoreTypeTimeline`) carry a monotonically-increasing 64-bit counter: you signal value N and wait for value N from any thread, without coordinating who "owns" the signal. This enables fine-grained CPU-GPU pipelining without the bookkeeping cost.

- Use a timeline semaphore as the per-frame "this frame is done" signal.
- The CPU can wait on a specific value and immediately begin recording the next frame once that value is reached.

See [synchronization deep dive](./synchronization-deep-dive.md) for the full timeline semaphore API.

### GPU-driven rendering (teaser)

The logical endpoint of CPU-side batching is to move the draw list to the GPU entirely: the GPU reads a buffer of indirect draw commands, culls them in a compute shader, and issues the surviving draws without any CPU involvement. This is <em>GPU-driven rendering</em> — it sidesteps the CPU-thread bottleneck altogether. See [a real-world frame](./a-real-world-frame.md) for how the pieces come together.

---

## the discipline: measure before you optimize

Vulkan gives you control, but control without measurement is guesswork. Before touching a single barrier or pool, answer two questions:

**Is the frame CPU-bound or GPU-bound?**

- CPU-bound: the GPU is idle waiting for the CPU to submit work. Parallel command recording helps. Reduce submission overhead.
- GPU-bound: the CPU submits work faster than the GPU can consume it. More CPU threads do nothing. Optimize shaders, reduce bandwidth, cut overdraw.

**Where on the GPU is the time going?**

- Vertex/geometry bound vs. fragment bound vs. memory bandwidth bound require completely different interventions.

A profiler answers both questions in seconds. Guessing costs days. See `./debugging-and-profiling.md` for the tools — RenderDoc, Nsight, and the GPU vendor's own profiling layers.

---

## quick reference

| concern | what helps | what to avoid |
|---|---|---|
| command recording throughput | one pool per thread, parallel recording | sharing a pool across threads |
| submission overhead | batch into one `vkQueueSubmit` | one submit per pass |
| descriptor overhead | sort by set, push constants, bindless | frequent set rebinds |
| pipeline overhead | sort by pipeline, pipeline cache | random pipeline order |
| allocation cost | sub-allocate from large blocks | per-frame `vkAllocateMemory` |
| tiled GPU bandwidth | `DONT_CARE` store ops | `STORE_OP_STORE` on transient targets |
| CPU-GPU sync cost | timeline semaphores, double-buffered readback | per-frame `vkMapMemory` stalls |
