<!-- _sidebar.md — organized by onion tier. Nav files use ABSOLUTE paths (/...).
     Top-level <li> = a DOMAIN; **bold** = the domain label, <small> = its sub-label;
     pages are listed in onion order (foundation → building blocks → cross-cutting →
     synthesis). The architect rewrites this per topic. -->

- **GLOBAL FOUNDATION** <small>the shared mental model</small>
  - [what is vulkan](/foundation/what-is-vulkan.md)
  - [instances & devices](/foundation/instances-and-devices.md)
  - [commands & queues](/foundation/commands-and-queues.md)
  - [buffers & memory](/foundation/buffers-and-memory.md)
  - [descriptors](/foundation/descriptors.md)

- **VULKAN-COMPUTE** <small>c++ · the simplest path</small>
  - [why compute & the parallel model](/compute/why-compute.md)
  - [compute pipelines & shaders](/compute/compute-pipelines-and-shaders.md)
  - [dispatch & workgroups](/compute/dispatch-and-workgroups.md)
  - [compute barriers & async](/compute/compute-barriers-and-async.md)
  - [compute walkthrough](/compute/compute-walkthrough.md)

- **VULKAN-RENDERING** <small>c++ · pixels on screen</small>
  - [from vertices to pixels](/rendering/from-vertices-to-pixels.md)
  - [the graphics pipeline object](/rendering/the-graphics-pipeline-object.md)
  - [swapchain & presentation](/rendering/swapchain-and-presentation.md)
  - [render passes & framebuffers](/rendering/render-passes-and-framebuffers.md)
  - [textures & sampling](/rendering/textures-and-sampling.md)
  - [image layouts & transitions](/rendering/image-layouts-and-transitions.md)
  - [hello triangle](/rendering/hello-triangle.md)
  - [the render loop](/rendering/the-render-loop.md)

- **VULKAN-ADVANCED** <small>c++ · scale & performance</small>
  - [the explicit bargain](/advanced/the-explicit-bargain.md)
  - [synchronization deep-dive](/advanced/synchronization-deep-dive.md)
  - [memory management](/advanced/memory-management.md)
  - [bindless & descriptor indexing](/advanced/bindless-and-descriptor-indexing.md)
  - [multithreading & performance](/advanced/multithreading-and-performance.md)
  - [debugging, validation & profiling](/advanced/debugging-validation-and-profiling.md)
  - [a real-world frame](/advanced/a-real-world-frame.md)

- **&nbsp;**
  - [search](/search.md)

<!-- house rules for editors live in [CLAUDE.md](/CLAUDE.md) — referenced here so the
     verifier doesn't flag it as an orphan; kept in a comment so it stays out of nav. -->

