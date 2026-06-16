<link rel="stylesheet" href="./css/globals.css">

# image layouts & transitions

A single image is used in several completely different ways across one frame — copied
into from a buffer, rendered into by the GPU, sampled from by a shader, then handed to
the display engine. Each of those uses wants the image's pixels stored in a different
hardware-optimal arrangement in memory. You are responsible for moving the image between
those arrangements at exactly the right moment, or the GPU reads back garbage and
behavior is undefined.

That explicit move is a <em>layout transition</em>, and it is the concern that threads
through swapchain, render targets, and textures alike. Get it right in all three places
and the frame renders cleanly. Miss it once and you get a black screen, corruption, or
a validation-layer scream.

---

## the shared workshop table

Think of every image as a workshop table that multiple trades use across a shift.

- When the carpenter uses it, the table is laid out for **cutting** — tools at the
  left, raw stock at the right, a straight-edge clamped along the top edge.
- When the painter takes over, they re-arrange it for **painting** — pots in the
  centre, protective sheets everywhere, nothing sharp exposed.
- At the end of the shift it is laid out for **display** — product centred, everything
  else cleared away.

The table is the same physical surface the whole time, but each trade needs a different
arrangement to work efficiently and safely. You — the foreman — schedule each
re-arrangement. You don't wait until the painter is already trying to work on a cutting
layout; you re-arrange *before* the trade starts.

The image is the table. An <em>image layout</em> is the hardware-level arrangement of
its pixels. A layout transition is the foreman's act of re-arranging it for the next
job. You schedule that re-arrangement in your command buffer.

---

## why this exists at all

OpenGL made a single global decision: every texture is stored in one neutral layout at
all times, and the driver silently re-arranges it whenever it needs to. That hides
complexity but forces the driver to guess — sometimes re-arranging when it didn't need
to, sometimes re-arranging too late.

Vulkan hands that decision to you, for two reasons:

- **You know the plan.** You know that an image will be written into by a transfer and
  then immediately sampled — the driver doesn't. You can transition once, at the right
  moment, with zero redundant work.
- **The GPU's optimal storage is opaque and hardware-specific.** A tile-based mobile
  GPU stores an image completely differently from a discrete desktop GPU. The "optimal"
  layouts are named constants whose bit-level representation the driver owns; you pick
  the right *name* and the driver handles the bits.

The practical upshot: `VK_IMAGE_LAYOUT_GENERAL` is readable and writable in every
situation, but it is the neutral layout from OpenGL — deliberately sub-optimal. Every
other layout is a specialist, faster for its one job and unusable for everything else.
Vulkan gives you the fast paths; you have to steer between them.

---

## the common layouts, each tied to a use

Think of each layout as a job title, not a property. An image doesn't *have* a layout
forever — it *holds* one until you transition it to a different job.

### `VK_IMAGE_LAYOUT_UNDEFINED` — the blank slate

- Used at image creation time, and whenever you don't care about existing content.
- The hardware makes no promise about the arrangement.
- **Use it as `oldLayout`** when you are about to overwrite the entire image anyway
  (e.g., a freshly allocated texture before the first upload). Transitioning *from*
  UNDEFINED skips any preservation work.
- Never use it as a destination — you'll never be able to read anything useful back out.

### `VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL` — ready to receive a copy

- Optimal for being the *target* of a `vkCmdCopyBufferToImage` or `vkCmdBlitImage`.
- The typical first real layout for a texture: you upload pixel data via a staging
  buffer (see [textures and sampling](./textures-and-sampling.md)), so the image needs
  to be in this layout before the copy command.

### `VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL` — ready to be rendered into

- Optimal for the GPU's raster pipeline writing pixel colours to the image.
- This is what a swapchain image (or any render target) needs to be in when a render
  pass begins drawing. The render pass mechanism can handle this transition for you —
  more on that below.

### `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL` — ready to be sampled

- Optimal for a fragment (or compute) shader reading the image through a sampler
  descriptor.
- The end-state for a texture after its upload is finished. Everything in
  [textures and sampling](./textures-and-sampling.md) lands here.

### `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR` — ready for the display engine

- Required by the swapchain before `vkQueuePresentKHR` hands the image to the
  compositor.
- This is the final layout for a rendered swapchain image each frame. The journey of a
  swapchain image is covered in [swapchain and presentation](./swapchain-and-presentation.md).

### `VK_IMAGE_LAYOUT_GENERAL` — the escape hatch

- Valid for every operation but optimal for none.
- Reach for it only when an image genuinely needs to be both written and read in the
  same operation (e.g., an image used as both storage and sampled in a compute shader)
  or when debugging — never as a default.

---

## typical lifecycles

Two sequences worth memorising:

**A texture (uploaded once, sampled forever)**
```
UNDEFINED
  → TRANSFER_DST_OPTIMAL   (one-time upload from staging buffer)
  → SHADER_READ_ONLY_OPTIMAL  (stays here for the rest of its life)
```

**A swapchain image (cycled every frame)**
```
UNDEFINED / PRESENT_SRC_KHR  (acquired, previous frame done)
  → COLOR_ATTACHMENT_OPTIMAL  (render pass draws into it)
  → PRESENT_SRC_KHR           (handed back to the compositor)
```

---

## how you actually transition

There are two mechanisms. Choose the right one for the situation.

### explicit barrier — `vkCmdPipelineBarrier`

You record a barrier directly into your command buffer. This is the fully general path
and the one to understand first.

A barrier carries three things:
- **`oldLayout` → `newLayout`** — the layout pair being transitioned.
- **`srcStageMask` / `srcAccessMask`** — what work must be *finished* before the
  transition.
- **`dstStageMask` / `dstAccessMask`** — what work must *wait* until after the
  transition.

The stage and access masks are the synchronization side of the barrier — they are not
layout-specific concepts. See [synchronization deep-dive](../advanced/synchronization-deep-dive.md) for the full taxonomy; here, focus on the
layout pair.

**Concept:** you are telling the GPU "finish all `srcStage` writes to this image,
re-arrange its memory for the new layout, then let `dstStage` proceed."

**Example — transitioning a freshly allocated texture for an upload:**
```cpp
VkImageMemoryBarrier barrier{};
barrier.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
barrier.oldLayout           = VK_IMAGE_LAYOUT_UNDEFINED;
barrier.newLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
barrier.image               = textureImage;
barrier.subresourceRange    = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

// Nothing wrote to the image yet — no src access to wait for.
barrier.srcAccessMask = 0;
// The transfer command will write — make it wait until the transition is done.
barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

vkCmdPipelineBarrier(
    commandBuffer,
    VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,   // src: nothing to wait for
    VK_PIPELINE_STAGE_TRANSFER_BIT,       // dst: transfer must wait
    0,
    0, nullptr,   // no memory barriers
    0, nullptr,   // no buffer barriers
    1, &barrier   // one image barrier
);
```

The command buffer records this barrier. The GPU executes it at submission time,
between whatever came before and the copy command that follows. See
[commands and queues](../foundation/commands-and-queues.md) for how command buffers
are recorded and submitted.

### implicit transition — render pass attachment layouts

If an image is used as a render pass attachment, the render pass description itself
can carry the transition. You set `initialLayout` and `finalLayout` in
`VkAttachmentDescription`:

```cpp
VkAttachmentDescription colorAttachment{};
colorAttachment.format         = swapchainFormat;
colorAttachment.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;       // don't care about old content
colorAttachment.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR; // ready for present when done
```

- At `vkCmdBeginRenderPass`, Vulkan transitions the image from `initialLayout` to the
  layout declared in the subpass (`VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL`).
- At `vkCmdEndRenderPass`, it transitions again to `finalLayout`.

This is the idiomatic path for swapchain images and render targets — the render pass
handles the bookkeeping so you don't need explicit barriers around it.

**When to use which:**

| Situation | Mechanism to use |
|-----------|-----------------|
| Image is a render pass attachment | Implicit via `initialLayout`/`finalLayout` |
| Uploading a texture (transfer path) | Explicit `vkCmdPipelineBarrier` |
| Compute shader reads a render target | Explicit barrier between render pass and dispatch |
| General-purpose transitions between any two layouts | Explicit barrier |

---

## the "who's responsible" pitfalls

Layout transitions are manual. The validation layers catch many mistakes, but here is
the short checklist to run through when something looks wrong:

- **Forgetting the transition entirely.** The most common mistake. If you start copying
  into an image that is still in `UNDEFINED` layout instead of `TRANSFER_DST_OPTIMAL`,
  the copy produces undefined results. The layout is not automatic.
- **Wrong `oldLayout`.** You must pass the layout the image is *currently in* as
  `oldLayout`. If you pass `UNDEFINED` when the image actually holds colour data, Vulkan
  is permitted to discard that content — because you said it didn't matter.
- **Transitioning at the wrong pipeline stage.** The barrier's `srcStageMask` must
  cover the last operation that touched the image. If you transition too early — before
  the render pass has actually finished writing — the sampler in the next pass may read
  stale data. The stage/access masks are the mechanism; the
  [synchronization deep-dive](../advanced/synchronization-deep-dive.md) is where to
  learn them properly.
- **Forgetting `subresourceRange`.** A barrier applies to a specific mip level range
  and array layer range, not the whole image unless you set the range to cover it.
  Partially-transitioned images behave as if each sub-resource is independently tracked.
- **Relying on render pass transitions for non-attachment uses.** The implicit mechanism
  only covers the attachment use inside that render pass. If you sample the image later
  in a compute pass, you still need an explicit barrier after `vkCmdEndRenderPass`.
