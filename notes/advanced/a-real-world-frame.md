<link rel="stylesheet" href="./css/globals.css">

# a real-world frame

You have spent the advanced track acquiring four expensive levers: deliberate synchronization, pooled memory, bindless descriptors, and multithreaded recording. This page is about spending them in one place — a single frame of a real engine rendering a large scene at high FPS.

The goal is not a copy-paste template. It is a mental picture detailed enough that when you open a production renderer, you recognize what you see.

---

## the destination: what a fast frame actually looks like

Imagine a film director shooting a scene with a dozen camera operators working in parallel. Each operator records their own reel independently. The director calls "cut," collects all the reels, splices them in the right order, and sends the final cut to the projector. Nobody waits for anyone else while recording.

A production Vulkan frame works the same way:

- <em>N worker threads each record one secondary command buffer</em> — they work in parallel, each with their own command pool
- the main thread collects those secondaries and executes them in a primary command buffer in the right order
- a handful of pipeline barriers enforce the real dependencies between passes (no more)
- a timeline semaphore governs hand-off between the GPU and the next frame's CPU work
- the swapchain presents, and the cycle repeats for the next frame in flight

A beginner's renderer — the one taught in [../rendering/the-render-loop.md](../rendering/the-render-loop.md) — does all of this on one thread, with one command buffer, and waits for the GPU to finish before the CPU does anything new. The advanced frame does none of those things. It keeps N CPU threads busy while the GPU runs, keeps the GPU busy by having the next frame ready before this one finishes, and never allocates a new descriptor set mid-draw.

---

## the frame timeline

Walk it left to right — this is the order of events for one frame:

```
[acquire swapchain image]
       |
       v
[worker thread 0]  [worker thread 1]  ...  [worker thread N-1]
 record secondary   record secondary         record secondary
 (shadow pass)      (G-buffer pass)           (lighting pass)
       |                  |                        |
       +------------------+------------------------+
                          |
                     [main thread]
               assemble primary command buffer
               execute secondaries in order:
                  shadow → G-buffer → barriers → lighting → post → UI
                          |
                    [submit to queue]
                    signal timeline semaphore (frame N done)
                          |
                     [present]
                          |
                 [frame N+1 CPU work begins
                  when semaphore value says GPU freed its resources]
```

Three things to notice before we go deeper:

1. the CPU records passes in parallel; the GPU executes them in the order the primary enforces
2. there are exactly as many barriers as the real data dependencies require — not one per pass boundary by reflex
3. the CPU never vkDeviceWaitIdle; it waits on a semaphore value for the slot it wants to reuse

---

## each lever in context

### multithreaded recording

One [command pool per thread](./multithreading-and-performance.md) — this is not optional. Pools are not thread-safe. Each worker thread owns its pool for the frame, records into a secondary command buffer (VK_COMMAND_BUFFER_LEVEL_SECONDARY), and hands the secondary back to the main thread when done.

What the main thread records:
- begin render pass (with VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS)
- vkCmdExecuteCommands with the collected secondaries
- end render pass
- the inter-pass barriers (more on those below)

What a worker thread records:
- a render pass or a stretch of draws within one
- resource binding (or bindless index pushes — see below)
- NO barriers that span passes — those belong to the main thread

The payoff: shadow, G-buffer, and lighting passes can be built simultaneously on separate cores. On a 6-core machine that is roughly 3× the recording throughput of a single-thread renderer.

### synchronization between passes

The sync model is explained in detail in [./synchronization-deep-dive.md](./synchronization-deep-dive.md). The key principle here is: <em>only synchronize what is actually dependent, at the stage where the dependency first matters.</em>

In a shadow → G-buffer → lighting → post → UI chain, the real dependencies are:

| transition | what the barrier does |
|---|---|
| shadow → G-buffer | shadow map image: SHADER_READ layout; make shadow writes available/visible to the fragment shader in the G-buffer pass |
| G-buffer → lighting | G-buffer attachments: SHADER_READ layout; make all G-buffer writes available/visible to the lighting compute or fragment stage |
| lighting → post | lighting output: SHADER_READ layout; visible to the post-process stage |
| post → UI | make post output visible before UI draws on top |
| last pass → PRESENT_SRC | swapchain image layout transition before present |

What you do NOT need:
- a barrier between every subpass if the later stage does not actually read the earlier output
- execution barriers on resources that are written by one queue and never read by another in the same frame
- a full pipeline stall (ALL_COMMANDS → ALL_COMMANDS) anywhere in this chain

Use image memory barriers with the tightest src/dst stage and access flags that are actually correct. The [synchronization deep-dive](./synchronization-deep-dive.md) covers available vs. visible, and why the stage flags matter for performance.

### pooled and sub-allocated memory

Every per-frame resource lives in a pre-allocated pool. Nothing is allocated from vkAllocateMemory or vkAllocateDescriptorSets during a live frame.

The [memory management page](./memory-management.md) explains the sub-allocation pattern. Applied here:

- **uniform ring buffer** — a single large buffer divided into F slots (F = frames in flight). Frame N writes to slot N mod F. When the timeline semaphore says frame N-2 is done, that slot is safe to overwrite. No allocation, no free.
- **per-frame descriptor pools** — pre-allocated at startup, reset each frame (vkResetDescriptorPool). Descriptors are claimed from the pool each frame, never individually freed.
- **per-frame command pools** — each worker thread has F command pools (one per frame-in-flight slot). The pool for slot N is reset when the semaphore confirms that frame is retired.

The result: allocation cost during a frame is effectively zero. The frame function touches no Vulkan allocator calls — only writes into pre-owned memory.

### bindless resources

Textures, material buffers, and mesh data live in a [bindless descriptor set](./bindless-and-descriptor-indexing.md) that is bound once per frame — or even once at startup if the scene is stable. Each draw pushes a small push constant (or writes a per-draw index into the uniform ring buffer) that tells the shader which slot in the bindless array holds its material.

This eliminates the per-draw descriptor update that dominates CPU time in a naive renderer. In a scene with 10,000 draw calls, that is 10,000 fewer vkCmdBindDescriptorSets calls. Instead there are zero, plus one push constant write per draw.

The worker threads that record secondary command buffers only touch:
```cpp
vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_ALL, 0, sizeof(DrawIndex), &drawIndex);
vkCmdDrawIndexedIndirect(cmd, drawBuffer, offset, drawCount, stride);
```

No descriptor set churn inside the draw loop.

---

## anatomy of the frame: the resource ledger

A frame touches two categories of resources: <em>things that change every frame</em>, and things that do not.

### per-frame resources (change every frame)
- command pool (reset at frame start, after the semaphore confirms retirement)
- primary and secondary command buffers (re-recorded from scratch)
- uniform ring buffer slot (written with camera, lighting, per-object matrices for this frame)
- per-frame descriptor set snapshot (if any dynamic data needs to be captured at a point in time)

### once (or once-per-scene-update)
- bindless descriptor set — bound once, updated when scene changes
- vertex and index buffers — uploaded once, resident always
- textures — uploaded once via staging buffer (the memory management page covers the staging pattern)
- pipeline objects — created at load time, never during a frame

### what the CPU does during a frame (and for how long)

```
wait on semaphore (target: ~0 ms — the frame-in-flight count absorbs GPU latency)
reset command pool
spawn N worker threads → each records one secondary
join workers
record primary (execute secondaries + barriers)
submit primary
signal semaphore
```

The CPU should be idle for nearly zero time. If it is waiting more than a few milliseconds, one of these is true: frames-in-flight is too low, the GPU is faster than your CPU can feed it, or one worker thread is a bottleneck and the others finish and then sit idle. The profiling discipline from the debugging page is how you find which.

---

## the horizon: GPU-driven rendering

The frame above still has the CPU submitting one draw call per mesh. The next step is to move the draw list itself onto the GPU: fill an indirect draw buffer in a compute pass, cull in parallel across all draws, then issue a single vkCmdDrawIndexedIndirect with drawCount equal to the surviving draws.

The CPU's job shrinks to: update scene data, dispatch the cull pass, submit. The GPU decides what to draw. This pattern — sometimes called GPU-driven or indirect rendering — is the natural next step once bindless and indirect draws are in place.

---

## the through-line of the whole site

The foundation gave you ownership: you control memory, you control synchronization, you decide what lives where. The compute and rendering tracks used that ownership to build correct programs. The advanced track spent it deliberately — choosing where to synchronize instead of everywhere, allocating once instead of every frame, binding once instead of every draw.

A frame like this is the payoff. It is not more complex than the beginner render loop in [../rendering/the-render-loop.md](../rendering/the-render-loop.md) — it is the same structure, with every naive assumption replaced by a deliberate choice.

What keeps a frame like this honest is the validation and profiling discipline: run the validation layers while building it, profile to confirm the parallelism is real and the barriers are not stalling what they should not. The levers only work if the measurements say they work.

> build it naive, measure it, then spend each of these levers exactly once where the measurement says to.
