<link rel="stylesheet" href="./css/globals.css">

# start here

these are living study notes on <em>Vulkan</em> — the low-level, explicit GPU API.
they're built to hand you a mental model first and the fine print last, so you can
stop at any depth and still understand the shape of things.

the big idea up front: where older APIs (OpenGL) let the driver make decisions for
you, Vulkan makes you <em>state everything explicitly</em> — you boot a device,
allocate your own memory, describe resources to shaders, bake pipelines, record
commands, synchronize them yourself, and submit to queues. more work, but total
control and almost no hidden cost.

## how these notes are structured

one shared **foundation**, then three C++ tracks — each its own little onion
(mental model → moving parts → cross-cutting concerns → a worked example).

- **global foundation** — the core both compute and rendering stand on: what Vulkan
  is, devices & queues, command buffers, memory, and descriptors.
- **vulkan-compute** — the simplest end-to-end path: run a compute shader over a
  buffer. no window, no rasterizer — the cleanest way to *first* see Vulkan work.
- **vulkan-rendering** — pixels on screen: the graphics pipeline, swapchain, render
  passes, textures, and the frame loop that draws a triangle and beyond.
- **vulkan-advanced** — cashing in the control: deep synchronization, memory
  strategy, bindless, multithreading, debugging, and a real-world frame.

## where to start

- **brand new to Vulkan?** read the **global foundation** top-to-bottom, then do
  **vulkan-compute** — it's the gentlest place to watch the GPU actually run your code.
- **here to draw things?** foundation → **vulkan-rendering**.
- **already shipping Vulkan?** jump straight to **vulkan-advanced**.
- looking for something specific? use [search](./search.md).
