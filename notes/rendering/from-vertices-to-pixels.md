<link rel="stylesheet" href="./css/globals.css">

# from vertices to pixels

You want a lit, textured 3D scene showing in a window — or even just a colored triangle. This rendering track is the road to that. This page is the map of the road: it installs the mental model that makes every page that follows make sense.

If you have not yet seen how Vulkan fits into the GPU landscape at all, start with [what is vulkan](../foundation/what-is-vulkan.md) first.

---

## the factory floor

Think of a factory with a conveyor belt running through it. Raw materials enter at one end. At each station, one worker does exactly one job: cuts, stamps, paints. Nobody upstream knows what the next station will do. At the far end, finished products roll out.

The graphics pipeline is that factory. Raw triangle data enters one end. A window full of pixels comes out the other. Each station along the belt does one job — some of those stations you program yourself; others are fixed machines with knobs but no open chassis.

That is the whole model. Every piece of rendering machinery in this track is either a station on that belt, a description of how the belt is configured, or a place for the finished products to land.

---

## the stations, one by one

Walk the belt left to right. No API yet — just what each station is *for*.

### vertex input

Raw coordinates arrive here: position, normal, UV. Think of them as the raw sheet metal. This station does no math; it just feeds data onto the belt in the format the next station expects.

### vertex shader (programmable)

The first station you write code for. It takes one vertex and outputs one vertex — transformed into the coordinate space the rasterizer understands (more on that coordinate journey below). This is where you apply the model-view-projection transform: moving geometry from where it lives in your scene into where it sits on the virtual camera film.

Because you write this code, the vertex shader is called <em>programmable</em>.

### primitive assembly (fixed-function)

Groups the transformed vertices into triangles (or lines, or points). You do not write this code — you set a knob on the machine: "treat every three vertices as one triangle." Fixed-function means the station always exists and always does the same job; you configure it, you do not replace it.

### rasterization (fixed-function)

The pivotal station. <em>Rasterization</em> is the process of converting a geometric triangle into a set of discrete pixel-sized candidates — one per pixel cell the triangle covers on screen. Each candidate is called a <em>fragment</em>. A fragment carries interpolated data (color, UV, depth) from the triangle's corners.

One triangle in → potentially thousands of fragments out. This is the moment the continuous geometric world becomes the discrete pixel grid.

### fragment shader (programmable)

You write this one too. It runs once per fragment and outputs a color (and optionally a depth). This is where lighting calculations, texture sampling, and surface detail live. It answers the question: "given everything I know about this point on this triangle, what color should it be?"

### depth and blend tests (fixed-function)

Before a fragment's color commits to the image, fixed-function tests decide whether it survives:

- **depth test** — if another fragment already won this pixel and was closer to the camera, discard this one.
- **blend** — if the surface is transparent, mix this fragment's color with what is already in the image rather than replacing it.

Again, you configure these with knobs; you do not program the logic.

### framebuffer

The landing zone — a block of GPU memory that holds the finished image. Once all fragments have been tested and blended, the framebuffer contains the rendered frame ready to show on screen.

---

## programmable vs fixed-function at a glance

- **programmable stations** (you write shaders): vertex shader, fragment shader.
- **fixed-function stations** (you configure, not replace): primitive assembly, rasterizer, depth/stencil test, blending.

The fixed-function stations exist because those operations are the same for almost every application — GPU vendors have spent decades optimizing them in silicon. Programmable stages exist where the meaning of the data is application-specific.

---

## the coordinate journey

The vertex shader's main job is a coordinate transformation. Here is just enough to ground every page that uses "clip space" or "screen space":

- Vertices start in <em>model space</em> — coordinates relative to the object's own origin.
- The vertex shader multiplies through a chain of matrices and outputs a position in <em>clip space</em> — a standardized frustum coordinate that the hardware knows how to map onto the screen.
- The rasterizer divides by the W component (perspective divide) and maps the result to actual pixel coordinates on screen.

Model space → clip space is your job (vertex shader). Clip space → pixels is the rasterizer's job (fixed-function). That is the full journey.

---

## how rendering differs from the compute path

If you have worked through the [compute track](../compute/why-compute.md), you already know Vulkan's general pipeline pattern. Rendering reuses that foundation but adds substantially more ceremony — for good reasons.

| what | compute | graphics |
|---|---|---|
| pipeline stages | one compute shader | six+ stages |
| window integration | not needed | swapchain (see below) |
| output description | just a buffer | render pass + attachments |
| fixed-function knobs | almost none | rasterizer, depth, blend, etc. |
| pipeline state object size | small | large |

The extra machinery exists because rasterization has many fixed-function knobs that need to be locked in ahead of time — Vulkan bakes them together into one big pipeline state object so the driver never has to recompile shader microcode mid-frame.

Set your expectations: the rendering track has considerably more setup than compute. That setup pays off in deterministic, fast frame production once it is in place.

---

## what you need beyond the pipeline

The pipeline describes how pixels are produced. You also need:

- **swapchain** — owns the chain of framebuffer images that feed the window. You acquire one image, render into it, then present it. The swapchain is what connects GPU output to the display.
- **render pass** — tells Vulkan what attachments (color, depth) you will render into, what their initial and final states are, and what to do with them at the start and end of the pass (clear, load, store, discard). The GPU can optimize memory traffic across subpasses with this information.
- **pipeline state object** — the compiled, immutable bundle of all your shader code plus all the fixed-function configuration. The [graphics pipeline object](./the-graphics-pipeline-object.md) is the first real stop in this track.

---

## the road ahead — rendering track roadmap

This track builds left to right through the factory:

1. **graphics pipeline object** — bake shaders and fixed-function config into one state object. [First stop.](./the-graphics-pipeline-object.md)
2. **swapchain** — connect the pipeline's output to the window.
3. **render passes** — declare the attachments and how they are used each frame.
4. **textures** — sample image data in the fragment shader.
5. **image layouts** — Vulkan's system for expressing which GPU operations can safely access an image.
6. **hello-triangle** — the first end-to-end frame: clear, draw, present.
7. **the render loop** — acquire, record, submit, present, repeat.

Each page assumes this factory-floor mental model. When a concept seems opaque, return here: find which station on the belt it belongs to, and why that station exists.
