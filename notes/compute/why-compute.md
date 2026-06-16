<link rel="stylesheet" href="./css/globals.css">

# why compute & the parallel model

You have millions of things to process — pixels in a frame, particles in a simulation, rows in a matrix — and the same operation applies to each one. The goal is to run that operation on all of them as fast as possible. A compute shader is how you hand that workload to the GPU and get the answer back, with no window, no render pass, no rasterizer in the way.

This page builds the mental model. The mechanics of dispatch sizes, workgroups, and synchronization come on the pages that follow.

---

## CPU vs. GPU — two different shapes of fast

A CPU has a handful of cores, each one very fast at running a single stream of instructions: it handles branches, exceptions, and data dependencies well, but it works through items more or less one at a time per core.

A GPU has thousands of simpler execution units that run the *same* instruction across many data elements at once. It is slower per item and worse at branchy, unpredictable code, but when the same operation applies independently to a huge number of elements, it finishes all of them in roughly the time the CPU would take for a handful.

The tradeoff:

- the **CPU wins** when the work is sequential, branchy, or data-dependent — each step informs the next.
- the **GPU wins** when the work is **wide and uniform** — the same operation applies independently to every element.

Most GPU workloads land in the second category: blur every pixel, advance every particle, multiply every matrix element. The GPU wins by a factor of hundreds or thousands.

---

## the data-parallel mental model

The precise term for the GPU's strength is <em>data-parallel execution</em>: one program runs over many data elements at the same time.

In GPU compute, that program is called a **kernel** (or a compute shader in Vulkan's vocabulary). Every time the kernel runs on one element, that single run is called an <em>invocation</em>. Each invocation gets a unique index — its position in the grid — and uses that index to reach into the input data, do its work, and write its result.

Concretely:

- you have an input buffer of N values
- you launch N invocations of the same shader
- invocation `i` reads `input[i]`, computes something, writes `output[i]`
- all of this happens in parallel across the GPU's execution units

Picture a grid of invocations laid over your data. The shader doesn't loop — the parallelism *is* the loop. How that grid is shaped (workgroups, local vs. global size) is the subject of [dispatch and workgroups](./dispatch-and-workgroups.md). For now, hold onto the core idea: a grid of invocations, each owning one slice of data.

---

## why compute is the best on-ramp to Vulkan

Vulkan is famously explicit. A "hello triangle" requires a swapchain, a window surface, a render pass, a framebuffer, a graphics pipeline, vertex buffers, and synchronization primitives you can't yet reason about.

A compute program needs almost none of that. The minimal path is:

1. create a **device** (the logical handle to the GPU) — covered in [what is Vulkan](../foundation/what-is-vulkan.md)
2. allocate an **input buffer** and fill it with data
3. compile a **compute shader** and wrap it in a pipeline
4. record a command buffer that dispatches the shader
5. submit it and read the **output buffer**

No window. No swapchain. No rasterizer. No image layouts. Just: data in → GPU work → data out. That minimal surface area means every piece you add has a clear job, and you can see Vulkan actually run your code on the first attempt.

The first real page of this track — [compute pipelines and shaders](./compute-pipelines-and-shaders.md) — builds exactly that path.

---

## when to reach for compute

Not every problem belongs on the GPU. The choice always comes back to one question: is the work wide and uniform, or branchy and sequential?

### compute vs. the CPU

Reach for compute when:

- you have **large arrays** of independent work items (thousands or millions)
- the operation on each item is the **same program**, just different data
- the items don't need to communicate results to each other (or do so only in structured, predictable ways)

Stay on the CPU when:

- the work is **sequential** — step N depends on step N-1
- the **branch rate is high** — different items take wildly different code paths
- the dataset is **small** — the overhead of scheduling GPU work outweighs the speedup

### compute vs. the graphics pipeline

The graphics pipeline is the right tool when you are turning geometry into pixels — rasterization, interpolation, depth testing, blending. It has fixed-function stages optimized for exactly that.

Compute is the right tool when you do **not** need rasterization. Examples:

- **image processing** — blur, sharpen, color grading, tone-mapping a finished frame
- **physics / particles** — advance positions, resolve collisions, update velocities
- **simulations** — fluid, cloth, cellular automata
- **ML-adjacent kernels** — matrix multiply, convolution, softmax
- **post-processing** — SSAO, temporal anti-aliasing, bloom — often faster as compute than as a screen-space draw call

The decision rule: if you would write a `for` loop over an array on the CPU, compute probably belongs on the GPU.

---

## the road ahead in this track

This page planted the mental model. The rest of the compute track builds the machinery on top of it:

| page | what it covers |
|------|----------------|
| [compute pipelines and shaders](./compute-pipelines-and-shaders.md) | how to compile a GLSL compute shader, wrap it in a `VkPipeline`, and hook up descriptors |
| [dispatch and workgroups](./dispatch-and-workgroups.md) | the execution grid — local size, global dispatch, how the GPU maps invocations to hardware threads |
| barriers and async | keeping the GPU busy safely — pipeline barriers, semaphores, async compute queues |
| compute walkthrough | a full end-to-end example: buffer allocation through readback |

Start at [compute pipelines and shaders](./compute-pipelines-and-shaders.md) when you are ready to write code.
