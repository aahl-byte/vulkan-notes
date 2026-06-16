<link rel="stylesheet" href="./css/globals.css">

# hello triangle

You want a single colored triangle visible in a window. That's it. But to get there,
Vulkan asks you to wire up nearly every subsystem at once — shaders, a pipeline, a
render pass, framebuffers, a command buffer, and the swapchain. This page walks each
step in order, keeps synchronization to the simplest possible form (one submit, wait
idle), and hands off to [the render loop](./the-render-loop.md) for everything that
follows.

This is the rite of passage because it forces you to get the whole chain right. A
compute dispatch can skip rasterization entirely. A triangle can't. It is the smallest
thing that proves your rendering stack works end-to-end.

---

## the bird's eye view

Assume you already have a `VkDevice` and a swapchain producing images (covered in
[swapchain and presentation](./swapchain-and-presentation.md)). The remaining chain is
short but every link is load-bearing:

1. **vertex buffer** — upload 3 vertices (position + color) to GPU-visible memory.
2. **shaders** — a GLSL vertex shader and fragment shader, compiled to SPIR-V modules.
3. **graphics pipeline** — vertex input layout, render pass / dynamic rendering
   attachment format, viewport, rasterization state, color blend. See
   [the graphics pipeline object](./the-graphics-pipeline-object.md).
4. **render pass + framebuffers** — one render pass that clears and writes the
   swapchain image; one framebuffer per swapchain image view. See
   [render passes and framebuffers](./render-passes-and-framebuffers.md).
5. **command buffer** — record: begin render pass → bind pipeline → bind vertex buffer
   → `vkCmdDraw(3, 1, 0, 0)` → end render pass.
6. **submit** — hand the command buffer to the graphics queue.
7. **present** — return the finished image to the swapchain for display.

Read this list once as the map. The rest of the page is one step per section.

---

## the shaders

Concept first: a vertex shader runs once per vertex and outputs a clip-space position;
the fragment shader runs once per rasterized pixel and outputs a color. For a triangle,
each shader is five lines.

**vertex shader (`triangle.vert`):**

```glsl
#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec3 inColor;

layout(location = 0) out vec3 fragColor;

void main() {
    gl_Position = vec4(inPosition, 0.0, 1.0);
    fragColor = inColor;
}
```

**fragment shader (`triangle.frag`):**

```glsl
#version 450

layout(location = 0) in vec3 fragColor;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(fragColor, 1.0);
}
```

Compile both to SPIR-V before the app runs:

```bash
glslc triangle.vert -o triangle.vert.spv
glslc triangle.frag -o triangle.frag.spv
```

Then load each `.spv` file into a `VkShaderModule` with `vkCreateShaderModule`. The
module is just a byte-stream holder — it does nothing on its own until it is plugged
into a pipeline stage.

---

## the vertex buffer

Three vertices, each carrying a 2D position and an RGB color — six floats per vertex.
Define them as plain C++ data in normalized device coordinates (NDC): x and y in
[-1, 1] with +Y pointing *down* — so (0, -0.5) is near the top, (0.5, 0.5) is
bottom-right, and (-0.5, 0.5) is bottom-left.

```cpp
struct Vertex {
    float pos[2];
    float color[3];
};

const std::vector<Vertex> vertices = {
    {{ 0.0f, -0.5f}, {1.0f, 0.0f, 0.0f}},  // top, red
    {{ 0.5f,  0.5f}, {0.0f, 1.0f, 0.0f}},  // bottom-right, green
    {{-0.5f,  0.5f}, {0.0f, 0.0f, 1.0f}},  // bottom-left, blue
};
```

Upload this into a `VkBuffer` backed by `VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` memory,
then `memcpy` the data in. (For a triangle this is fine. A real app would use a staging
buffer and device-local memory for performance, but that is a later concern.)

The vertex layout must match what the pipeline's vertex input state declares — the
binding description and attribute descriptions. If these descriptions disagree with the
struct layout, the pipeline will silently read garbage or the validation layer will
catch it immediately.

---

## the render pass and framebuffers

A render pass is the contract: <em>how the pipeline should treat the attachment before, during, and after drawing.</em>
For a triangle:

- one color attachment — the swapchain image
- `loadOp = CLEAR`, `storeOp = STORE`
- layout transitions: `UNDEFINED → COLOR_ATTACHMENT_OPTIMAL` on load, `COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR` on store

Create one `VkFramebuffer` per swapchain image view, each wrapping the same render
pass. See [render passes and framebuffers](./render-passes-and-framebuffers.md) for the
full attachment description and subpass setup.

---

## the graphics pipeline

The pipeline is the largest setup object. Its job is to describe the fixed-function
state the GPU needs before it can rasterize anything. The pieces that matter most for
a triangle:

- **vertex input state** — the binding stride (sizeof(Vertex)) and two attribute
  descriptions (location 0 = 2 floats at offset 0, location 1 = 3 floats at offset 8).
- **input assembly** — `VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST`, `primitiveRestartEnable = VK_FALSE`.
- **viewport and scissor** — match the swapchain extent exactly. Mismatch here is one
  of the most common "nothing shows up" bugs.
- **rasterization** — `polygonMode = FILL`, `cullMode = NONE` for a first triangle
  (winding order catches newcomers; disable culling until the triangle appears, then
  re-enable).
- **color blend** — no blending; write all four channels.

See [the graphics pipeline object](./the-graphics-pipeline-object.md) for the full
`VkGraphicsPipelineCreateInfo` walkthrough.

---

## recording the command buffer

Now all the pieces exist. Recording is straightforward — it mirrors the bird's eye list
from the top:

```cpp
VkCommandBufferBeginInfo beginInfo{};
beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
vkBeginCommandBuffer(commandBuffer, &beginInfo);

VkClearValue clearColor = {{{0.0f, 0.0f, 0.0f, 1.0f}}};

VkRenderPassBeginInfo renderPassInfo{};
renderPassInfo.sType       = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
renderPassInfo.renderPass  = renderPass;
renderPassInfo.framebuffer = framebuffers[imageIndex];
renderPassInfo.renderArea  = {{0, 0}, swapchainExtent};
renderPassInfo.clearValueCount = 1;
renderPassInfo.pClearValues    = &clearColor;

vkCmdBeginRenderPass(commandBuffer, &renderPassInfo,
                     VK_SUBPASS_CONTENTS_INLINE);

vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

VkDeviceSize offset = 0;
vkCmdBindVertexBuffers(commandBuffer, 0, 1, &vertexBuffer, &offset);

vkCmdDraw(commandBuffer, 3, 1, 0, 0);  // 3 verts, 1 instance, first vert 0, first instance 0

vkCmdEndRenderPass(commandBuffer);
vkEndCommandBuffer(commandBuffer);
```

`vkCmdDraw(3, 1, 0, 0)` is the draw call. Four numbers: vertex count, instance count,
first vertex, first instance. For one triangle: 3, 1, 0, 0.

---

## submit and present

For a first frame, use the simplest possible synchronization: submit, then wait for
the device to go idle before presenting. This is safe and slow. The real multi-frame
loop (semaphores, fences, frames-in-flight) is exactly what
[the render loop](./the-render-loop.md) covers — do not add that complexity here.

```cpp
// acquire the next swapchain image
uint32_t imageIndex;
vkAcquireNextImageKHR(device, swapchain, UINT64_MAX,
                      VK_NULL_HANDLE, VK_NULL_HANDLE, &imageIndex);

// record (see above) ...

// submit
VkSubmitInfo submitInfo{};
submitInfo.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
submitInfo.commandBufferCount   = 1;
submitInfo.pCommandBuffers      = &commandBuffer;
vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);

// wait — not what you do in production, but correct for one frame
vkDeviceWaitIdle(device);

// present
VkPresentInfoKHR presentInfo{};
presentInfo.sType          = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
presentInfo.swapchainCount = 1;
presentInfo.pSwapchains    = &swapchain;
presentInfo.pImageIndices  = &imageIndex;
vkQueuePresentKHR(presentQueue, &presentInfo);
```

`vkDeviceWaitIdle` blocks until the GPU finishes. It is correct but it serializes CPU
and GPU completely. [The render loop](./the-render-loop.md) replaces this with fences
and semaphores so both run in parallel.

---

## classic first-triangle bugs

Nothing shows up is the most common outcome. Work through this checklist before
assuming something is fundamentally broken:

### nothing renders (black screen)

- **viewport/scissor mismatch** — if viewport dimensions don't match the swapchain
  extent the geometry lands outside the visible area. <em>Check that the viewport width
  and height exactly equal `swapchainExtent.width` and `swapchainExtent.height`.</em>
- **pipeline/render-pass mismatch** — the pipeline was compiled against a different
  render pass than the one used during recording. Vulkan doesn't catch this at draw
  time; it just silently misrenders or crashes.
- **backface culling** — the default winding order is counter-clockwise. If your
  vertices happen to be clockwise, the triangle is culled. Set `cullMode = NONE` while
  debugging, then fix the winding.

### validation errors

The validation layer is not optional for development — it is the debugger. Enable
`VK_LAYER_KHRONOS_validation` at instance creation. It will name the exact struct or
call that is wrong. A triangle with a silent validation error is a triangle that will
break on a different driver. Fix all errors before moving on.

### image layout errors

If the validation layer reports an image layout violation on present, the render pass's
`finalLayout` for the attachment is wrong. It must be
`VK_IMAGE_LAYOUT_PRESENT_SRC_KHR`. Everything else (e.g., `GENERAL`,
`COLOR_ATTACHMENT_OPTIMAL`) will present incorrectly or trigger a validation error.

### vertex data not matching pipeline description

If the binding stride or attribute offset in `VkVertexInputAttributeDescription` doesn't
match the struct layout, the GPU reads the wrong bytes. The validation layer catches
most mismatches. When in doubt, print `sizeof(Vertex)` and `offsetof(Vertex, color)`
and compare to the attribute offset you declared.

---

## what comes next

This page covered getting one frame correct. The steady-state loop — double-buffering,
semaphores for image-ready and render-complete signals, fences for CPU/GPU
synchronization, and cycling through frames-in-flight — is
[the render loop](./the-render-loop.md). Once that is running, a triangle becomes an
animated triangle, and you have a rendering harness you can build on.
