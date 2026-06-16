<link rel="stylesheet" href="./css/globals.css">

# render passes & framebuffers

Every draw call has to write somewhere. A color pixel needs a destination image. A depth test needs somewhere to read and write depth values. Before Vulkan can execute a single draw, you have to declare those destinations — what images are involved, what to do with each one at the start and end of the session, and what state they should be in when you're done. That declaration is a <em>render pass</em>.

A render pass is the contract between your drawing commands and the GPU: "here are the surfaces we're working on, here's what we're allowed to do to them, and here's what the GPU can expect at the end." The GPU uses this contract to schedule work efficiently, especially on mobile hardware.

---

## what a render pass declares upfront

A render pass is a declaration you make before any drawing happens. It states:

- which images are in play for this drawing session (the attachments)
- what to do with each one at the *start* — wipe it to a clear value, or preserve its existing content
- what to do with each one at the *end* — keep the result in memory, or discard it once it's been used

The GPU needs all of this before it executes a single draw, because it uses the information to schedule memory traffic efficiently — especially on mobile hardware, where reading and writing image memory is the main cost. A render pass is a first-class API object with precise semantics, not just a description.

---

## the moving parts

A render pass is made of four interlocking pieces. Together they describe the session and bind it to real images.

### attachment descriptions — the image slots

An <em>attachment</em> is one image slot in a render pass — a color buffer, a depth/stencil buffer, or a resolve target. Each attachment is described with:

- **format** — the pixel format (`VK_FORMAT_B8G8R8A8_SRGB`, `VK_FORMAT_D32_SFLOAT`, etc.)
- **samples** — sample count for multisampling
- **loadOp / stencilLoadOp** — what to do with existing content at the start (covered in detail below)
- **storeOp / stencilStoreOp** — what to do with the result at the end (covered below)
- **initialLayout / finalLayout** — the image layout the attachment arrives in, and the layout it should be in when the pass ends

The layout fields plug directly into Vulkan's image layout transition system. The render pass performs those transitions implicitly at its boundaries — see [image layouts and transitions](./image-layouts-and-transitions.md) for how that works.

```cpp
VkAttachmentDescription colorAttachment{};
colorAttachment.format         = swapchainImageFormat;
colorAttachment.samples        = VK_SAMPLE_COUNT_1_BIT;
colorAttachment.loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR;
colorAttachment.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
colorAttachment.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED;
colorAttachment.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
```

### subpasses — the drawing phases within the pass

A <em>subpass</em> is one discrete rendering phase inside a render pass. Most applications use exactly one subpass. Each subpass references a subset of the pass's attachments via `VkAttachmentReference`, telling the GPU which slot is the color target, which is depth, and so on.

```cpp
VkAttachmentReference colorRef{};
colorRef.attachment = 0;  // index into the attachment description array
colorRef.layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

VkSubpassDescription subpass{};
subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
subpass.colorAttachmentCount = 1;
subpass.pColorAttachments    = &colorRef;
```

Multiple subpasses matter most on **tile-based deferred rendering (TBDR) GPUs** — the mobile architecture where Mali, Apple, and Qualcomm chips work. When passes are merged, the GPU can keep intermediate results on tile memory instead of flushing to main memory. That's a significant bandwidth win on battery-powered devices. For desktop, one subpass is nearly always the right answer.

### subpass dependencies — the built-in sync

A <em>subpass dependency</em> tells Vulkan how memory and execution order relate across subpass boundaries (or between a subpass and work outside the render pass). Without them, the GPU has no guarantee that a write in one subpass is visible to a read in the next.

```cpp
VkSubpassDependency dependency{};
dependency.srcSubpass    = VK_SUBPASS_EXTERNAL;
dependency.dstSubpass    = 0;
dependency.srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
dependency.dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
dependency.srcAccessMask = 0;
dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
```

`VK_SUBPASS_EXTERNAL` refers to anything outside the render pass — the dependency above says: wait for whatever was happening with the color attachment output before this subpass starts writing. Subpass dependencies are a specialized form of Vulkan's broader synchronization model; see the sync deep-dive in the advanced track for the full picture.

### the framebuffer — connecting descriptions to real images

The render pass describes *slots*. The <em>framebuffer</em> fills those slots with real `VkImageView` objects — the concrete images that draw calls will actually read from and write to.

A framebuffer is always created against a specific render pass, and its attachments must match that pass's descriptions in count, format, and order.

```cpp
VkFramebufferCreateInfo fbInfo{};
fbInfo.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
fbInfo.renderPass      = renderPass;
fbInfo.attachmentCount = 1;
fbInfo.pAttachments    = &swapchainImageView;  // the real image
fbInfo.width           = swapchainExtent.width;
fbInfo.height          = swapchainExtent.height;
fbInfo.layers          = 1;

vkCreateFramebuffer(device, &fbInfo, nullptr, &framebuffer);
```

For a swapchain you typically create one framebuffer per swapchain image, then pick the right one each frame.

### recording: begin, draw, end

Once you have a render pass and a framebuffer, you bracket your draw calls with `vkCmdBeginRenderPass` and `vkCmdEndRenderPass`. Everything between those two calls executes within the pass's contract.

```cpp
VkRenderPassBeginInfo beginInfo{};
beginInfo.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
beginInfo.renderPass        = renderPass;
beginInfo.framebuffer       = framebuffer;
beginInfo.renderArea.offset = {0, 0};
beginInfo.renderArea.extent = swapchainExtent;
beginInfo.clearValueCount   = 1;
beginInfo.pClearValues      = &clearColor;  // used if loadOp = CLEAR

vkCmdBeginRenderPass(cmd, &beginInfo, VK_SUBPASS_CONTENTS_INLINE);
// ... draw calls, bind pipeline, etc.
vkCmdEndRenderPass(cmd);
```

The graphics pipeline bound inside a render pass must have been created against a compatible render pass — the pipeline and the pass have to agree on attachment formats and sample counts. See [the graphics pipeline object](./the-graphics-pipeline-object.md) for how that compatibility is declared.

---

## load/store ops — the performance lever

These two settings are where you earn or waste memory bandwidth, especially on mobile.

### loadOp

What happens to existing attachment content at the start of the subpass:

| op | what it does | when to use it |
|----|-------------|----------------|
| `CLEAR` | GPU fills the attachment with the clear value | first pass each frame — or any time previous content is garbage |
| `LOAD` | preserves whatever was already in the image | you need to composite on top of a prior render |
| `DONT_CARE` | content is undefined — GPU may do anything | initial frame, or when you're about to overwrite every pixel anyway |

### storeOp

What happens to the attachment's content at the end of the subpass:

| op | what it does | when to use it |
|----|-------------|----------------|
| `STORE` | result is written back to memory | color attachment going to the display or sampled next |
| `DONT_CARE` | result is discarded | depth buffer you won't read again — this is the common case |

#### pick the cheapest op that's correct

- Use `CLEAR` instead of `LOAD` whenever previous content doesn't matter. Clear is cheaper than a full image read on TBDR hardware.
- Use `DONT_CARE` for store whenever the attachment isn't read after the pass. Depth is the classic example: it's used during the pass, but once the frame is composited you don't need it anymore. Storing it wastes bandwidth.
- Avoid `LOAD` on attachments that are going to be fully overdrawn. You're paying to read data the GPU will immediately discard.

These choices are invisible on desktop discrete GPUs — bandwidth is abundant. On mobile, they directly affect battery life and thermal headroom.

---

## dynamic rendering — the modern alternative

Vulkan 1.3 (and the `VK_KHR_dynamic_rendering` extension for older drivers) provides an alternative that skips `VkRenderPass` and `VkFramebuffer` objects entirely.

Instead of creating objects upfront and recording a begin/end pair, you pass your attachments inline at record time using `vkCmdBeginRendering`:

```cpp
VkRenderingAttachmentInfo colorAttachInfo{};
colorAttachInfo.sType       = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
colorAttachInfo.imageView   = swapchainImageView;
colorAttachInfo.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
colorAttachInfo.loadOp      = VK_ATTACHMENT_LOAD_OP_CLEAR;
colorAttachInfo.storeOp     = VK_ATTACHMENT_STORE_OP_STORE;
colorAttachInfo.clearValue  = clearColor;

VkRenderingInfo renderingInfo{};
renderingInfo.sType                = VK_STRUCTURE_TYPE_RENDERING_INFO;
renderingInfo.renderArea           = {{0,0}, swapchainExtent};
renderingInfo.layerCount           = 1;
renderingInfo.colorAttachmentCount = 1;
renderingInfo.pColorAttachments    = &colorAttachInfo;

vkCmdBeginRendering(cmd, &renderingInfo);
// ... draw calls ...
vkCmdEndRendering(cmd);
```

You're still responsible for image layout transitions — they don't happen automatically without a render pass object to drive them. You issue those explicitly via pipeline barriers. See [image layouts and transitions](./image-layouts-and-transitions.md).

### classic render pass vs dynamic rendering

| | classic render pass | dynamic rendering |
|---|---|---|
| objects | `VkRenderPass` + `VkFramebuffer` | none |
| attachment info | baked at object creation | passed at record time |
| layout transitions | implicit, from initial/finalLayout | explicit barriers |
| flexibility | attachments fixed at pipeline creation | attachments can vary per draw |
| TBDR subpass merging | supported | limited (driver-dependent) |
| complexity | higher | lower |

**when to use classic render passes:**
- targeting mobile/TBDR hardware where subpass merging matters
- working with a codebase or tutorial written before Vulkan 1.3
- you need the guarantee of implicit layout transitions at pass boundaries

**when to use dynamic rendering:**
- Vulkan 1.3 or the extension is available and you don't need TBDR subpass merging
- you want to avoid the boilerplate of framebuffer-per-swapchain-image
- your pipeline configuration changes frequently enough that baking attachments into objects is a maintenance burden

Dynamic rendering is the preferred path for new desktop-targeted Vulkan code. If you're writing for mobile or targeting the widest hardware range, weigh the TBDR tradeoff carefully.

---

## the bigger picture

A render pass sits between two other major systems:

- **the pipeline** must be created against a compatible render pass (or with `VK_DYNAMIC_RENDERING_UNUSED` for dynamic rendering). If your pipeline and render pass disagree on attachment formats, recording will fail. See [the graphics pipeline object](./the-graphics-pipeline-object.md).
- **the attachments** are `VkImageView`s wrapping `VkImage`s. Images used as inputs from a previous pass — not just render targets — are how you feed a rendered scene into a later shading step. See [textures and sampling](./textures-and-sampling.md) for how images become shader inputs.
