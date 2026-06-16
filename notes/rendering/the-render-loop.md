<link rel="stylesheet" href="./css/globals.css">

# the render loop

A real application does not draw one triangle and stop. It draws thousands of frames — each one acquiring a fresh image, recording commands, submitting them to the GPU, and handing the result to the display — all while the CPU races ahead preparing the next frame. This page is the loop that does that safely: no GPU stall, no image corruption, no race between CPU and GPU over the same resources.

If you started from [hello-triangle.md](./hello-triangle.md), you have already seen the single-frame skeleton. This page turns that skeleton into a steady-state loop by wiring in real synchronization and a frames-in-flight strategy.

---

## the coarse mental model

The CPU and the GPU run in parallel. The CPU records and submits frames; the GPU executes them and hands finished images to the display. For this to run smoothly without either side stalling or stepping on shared resources, you need two kinds of coordination:

1. **Ordering between GPU operations** — e.g. "don't display this image until rendering into it has finished," or "don't render into this image until the display engine has released it." That's the job of a <em>semaphore</em>: it's signaled by one GPU operation and waited on by another, entirely on the GPU timeline.
2. **The CPU knowing when the GPU is done** — so it can safely reuse a frame's command buffer and other resources. That's the job of a <em>fence</em>: the GPU signals it, and the CPU waits on it.

In short: semaphores order GPU work against other GPU work; fences let the CPU wait for the GPU.

---

## the per-frame skeleton

Every frame traces the same dependency chain. Following it in order is the most important thing to internalize before looking at any code.

```
wait on this frame's fence          ← CPU blocks until GPU is done with this frame's resources
  │
acquire swapchain image             ← GPU signals imageAvailable semaphore when an image is ready
  │
record commands into command buffer ← CPU work; safe because fence told us the buffer is free
  │
submit command buffer               ← GPU waits on imageAvailable, executes, signals renderFinished + fence
  │
present                             ← GPU waits on renderFinished, then gives image to display
```

Each arrow is a dependency. Skip one and you either block the CPU unnecessarily or hand the GPU a resource it is still writing.

The [swapchain and presentation page](./swapchain-and-presentation.md) covers the acquire/present handshake in depth. Here we care about how synchronization *stitches* those two points together.

---

## the two sync primitives — by role, not by API

Vulkan gives you two tools. Understanding what each is *for* is the entire lesson; the API details follow naturally.

### semaphores — GPU↔GPU ordering

<em>A semaphore coordinates two GPU operations across submit/acquire/present boundaries. The CPU never waits on a semaphore and never signals one.</em>

- `imageAvailable`: signaled by `vkAcquireNextImageKHR` when the display engine releases an image, waited on by the submit call before commands touch that image.
- `renderFinished`: signaled by the submit call when rendering completes, waited on by `vkQueuePresentKHR` before displaying.

The CPU submits these as pipeline stage masks; it does not touch them again. Semaphores are "fire and forget" from the CPU's point of view — they exist entirely on the GPU timeline.

**Do not reuse a semaphore across frames without a reset.** A semaphore in the signaled state that is never consumed will cause a validation error on the next `vkAcquireNextImageKHR` call.

### fences — GPU→CPU notification

<em>A fence lets the CPU poll or block until the GPU has finished a batch of work.</em>

- Created in the signaled state (`VK_FENCE_CREATE_SIGNALED_BIT`) so the very first `vkWaitForFences` at frame 0 returns immediately.
- Reset with `vkResetFences` after the wait, before recording.
- Signaled by the submit call (`VkSubmitInfo.pSignalFences`) when the GPU is done.

The fence is the gatekeeper for the CPU: it tells you when a frame's command buffer, semaphores, and swapchain image are safe to reuse. Without it you'd be recording into a command buffer the GPU is still reading.

**Quick contrast:**

| | semaphore | fence |
|---|---|---|
| who signals | GPU (acquire, submit) | GPU (submit) |
| who waits | GPU (submit, present) | CPU (`vkWaitForFences`) |
| reset required | no (auto-reset on wait) | yes (`vkResetFences`) |
| purpose | GPU↔GPU ordering | GPU→CPU notification |

For the full internals — binary vs. timeline semaphores, pipeline stage masks, and why you can't poll a semaphore from the CPU — see [../advanced/synchronization-deep-dive.md](../advanced/synchronization-deep-dive.md).

---

## frames in flight

Running the loop one frame at a time defeats the purpose. While the GPU executes frame N, the CPU should already be recording frame N+1. This is the <em>frames-in-flight</em> pattern.

The idea: keep N independent sets of per-frame resources, cycling through them. Frame 0 uses set 0, frame 1 uses set 1, frame 2 uses set 0 again, and so on.

**What belongs in each set:**
- One command buffer (per thread that records)
- One `imageAvailable` semaphore
- One `renderFinished` semaphore
- One in-flight fence

**The classic setup:**

```cpp
constexpr int MAX_FRAMES_IN_FLIGHT = 2;

// per-frame resources
VkCommandBuffer commandBuffers[MAX_FRAMES_IN_FLIGHT];
VkSemaphore     imageAvailableSemaphores[MAX_FRAMES_IN_FLIGHT];
VkSemaphore     renderFinishedSemaphores[MAX_FRAMES_IN_FLIGHT];
VkFence         inFlightFences[MAX_FRAMES_IN_FLIGHT];

uint32_t currentFrame = 0;
```

**Each frame:**

```cpp
// 1. wait — block CPU until this slot's GPU work is done
vkWaitForFences(device, 1, &inFlightFences[currentFrame], VK_TRUE, UINT64_MAX);
vkResetFences(device, 1, &inFlightFences[currentFrame]);

// 2. acquire — get a swapchain image; GPU signals imageAvailable when ready
uint32_t imageIndex;
VkResult result = vkAcquireNextImageKHR(device, swapchain, UINT64_MAX,
    imageAvailableSemaphores[currentFrame], VK_NULL_HANDLE, &imageIndex);

if (result == VK_ERROR_OUT_OF_DATE_KHR) { recreateSwapchain(); continue; }

// 3. record — command buffer is provably free because fence said so
vkResetCommandBuffer(commandBuffers[currentFrame], 0);
recordCommandBuffer(commandBuffers[currentFrame], imageIndex);

// 4. submit — GPU waits on imageAvailable, signals renderFinished + fence
VkSemaphore waitSemaphores[]   = { imageAvailableSemaphores[currentFrame] };
VkSemaphore signalSemaphores[] = { renderFinishedSemaphores[currentFrame] };
VkPipelineStageFlags waitStages[] = { VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT };

VkSubmitInfo submitInfo{};
submitInfo.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
submitInfo.waitSemaphoreCount   = 1;
submitInfo.pWaitSemaphores      = waitSemaphores;
submitInfo.pWaitDstStageMask    = waitStages;
submitInfo.commandBufferCount   = 1;
submitInfo.pCommandBuffers      = &commandBuffers[currentFrame];
submitInfo.signalSemaphoreCount = 1;
submitInfo.pSignalSemaphores    = signalSemaphores;

vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlightFences[currentFrame]);

// 5. present — GPU waits on renderFinished before displaying
VkPresentInfoKHR presentInfo{};
presentInfo.sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
presentInfo.waitSemaphoreCount = 1;
presentInfo.pWaitSemaphores    = signalSemaphores;
presentInfo.swapchainCount     = 1;
presentInfo.pSwapchains        = &swapchain;
presentInfo.pImageIndices      = &imageIndex;

result = vkQueuePresentKHR(presentQueue, &presentInfo);
if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR)
    recreateSwapchain();

// advance to next slot
currentFrame = (currentFrame + 1) % MAX_FRAMES_IN_FLIGHT;
```

The command buffer background — pools, allocation, reset semantics — lives in [../foundation/commands-and-queues.md](../foundation/commands-and-queues.md).

### how many frames in flight?

<em>Frames in flight</em> is the number of frames the CPU is allowed to be ahead of the GPU simultaneously.

- **1** — every submit blocks until the GPU is done. Safe but wastes the CPU-GPU overlap. Useful for debugging.
- **2** — one frame on the GPU, one being prepared. The sweet spot for most apps: low latency, real overlap.
- **3** — one frame displaying, one on the GPU, one on the CPU. Useful when the GPU is the bottleneck; adds a frame of latency.
- **> 3** — rarely useful. You get more memory consumption, more input lag, and the GPU still can't go faster than one frame per display interval.

**Rule of thumb:** start with 2. Only go to 3 if profiling shows the GPU is consistently starved.

Note: `MAX_FRAMES_IN_FLIGHT` is not the same as swapchain image count. The swapchain may have 3 images while you only allow 2 frames in flight. The fence is what limits concurrency, not the swapchain.

---

## swapchain recreation in the loop

The swapchain can become invalid at any time — the window was resized, the surface went fullscreen, or the OS reclaimed the display. Vulkan tells you via two return codes:

- `VK_ERROR_OUT_OF_DATE_KHR` — the swapchain is no longer compatible. You must not use it.
- `VK_SUBOPTIMAL_KHR` — the swapchain still works but is not optimal (e.g., wrong size). You may continue this frame but should rebuild soon.

These can appear on either `vkAcquireNextImageKHR` or `vkQueuePresentKHR`. Handle both.

```
on OUT_OF_DATE from acquire:  immediately recreate, skip this frame (no image to render into)
on SUBOPTIMAL from acquire:   continue the frame, recreate after present
on OUT_OF_DATE/SUBOPTIMAL from present: recreate before next frame
```

Rebuild means: wait for the device to be idle, destroy the old swapchain and its image views, create a new one at the new surface size, and recreate any framebuffers or render-pass attachments that reference the swapchain images. The [swapchain and presentation page](./swapchain-and-presentation.md) details the full teardown/rebuild sequence.

---

## common loop bugs

These are the mistakes validation catches (and that cost you hours when validation is off).

### reusing a command buffer that is still in flight

You did not wait on the fence before calling `vkResetCommandBuffer`. The GPU is mid-execution; recording over it corrupts the command stream. The fix is `vkWaitForFences` at the top of the loop, every frame, without exception.

### semaphore reuse across frames

A semaphore from a previous frame is still pending (signaled but not consumed) and you try to use it again. This produces undefined behavior — on some drivers a silent hang, on others an immediate validation error. The frames-in-flight pattern prevents this by giving each frame its own semaphore pair. Make sure the index into that pair advances in lockstep with `currentFrame`.

### not resetting the fence before the new submit

You waited, reset, recorded, then forgot `vkResetFences` before submit. The fence was already in the unsignaled state after the wait/reset pair at the top of the frame — so this is usually fine. The danger is resetting *after* a submit: you now have a signaled fence you just cleared, and the GPU signals it again next frame, which looks correct until a race hits you. Always reset immediately after the wait, before recording or submitting.

### validation as the safety net

Run validation layers during development. The synchronization validator (`VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT`) specifically catches hazards the above bugs create. It is not optional; Vulkan's explicit model makes silent errors easy. See [../advanced/synchronization-deep-dive.md](../advanced/synchronization-deep-dive.md) for how to read its output.

---

## the dependency chain, summarized

```
CPU frame loop
    │
    ├─ vkWaitForFences          ← CPU blocks on GPU (fence)
    ├─ vkAcquireNextImageKHR    ← GPU signals imageAvailable (semaphore)
    ├─ record command buffer     ← CPU only; fence proved the buffer is free
    ├─ vkQueueSubmit            ← GPU waits on imageAvailable, signals renderFinished + fence
    └─ vkQueuePresentKHR        ← GPU waits on renderFinished
```

Every arrow in the chain has exactly one Vulkan object enforcing it. Remove any one and a dependency goes unenforced. The loop is only as correct as its sync objects are complete.
