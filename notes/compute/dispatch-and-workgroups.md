<link rel="stylesheet" href="./css/globals.css">

# dispatch & workgroups

You call one function — `vkCmdDispatch(x, y, z)` — and the GPU fans out into thousands of shader invocations running at once, each one picking a unique slice of your data and computing on it independently. This page explains how that fan-out works and, critically, how each invocation knows which data element belongs to it.

---

## the big picture — what you're actually doing

The goal is to run one shader function once per data element, all in parallel.

Say you have an array of 1 000 000 floats to multiply by 2. On the CPU you'd loop. On the GPU you declare a shader that does the multiply for a single element, dispatch enough work to cover all elements, and the GPU runs every copy of that shader simultaneously.

`vkCmdDispatch` is the trigger. Everything else — workgroups, local size, built-in indices — exists to answer one question: *which copy of the shader should touch which element?*

---

## the stadium analogy — a coarse but true mental model

Picture a stadium with a grid of seats.

- The **whole stadium** is your dispatch: all the work you want done.
- The stadium is divided into **sections** — blocks of seats that sit near each other and share a whiteboard on the wall. A section is a <em>workgroup</em>.
- Each **individual seat** in a section is one <em>invocation</em> — one running copy of your shader.

The GPU fills all seats simultaneously. Every person in their seat executes the same shader but holds a unique ticket that tells them their seat number — and from that they figure out which data element is theirs.

Two key facts that follow directly from this picture:

- People in the same section can pass notes via the shared whiteboard (= GPU shared memory). People in different sections cannot.
- `vkCmdDispatch` specifies how many **sections** to create, not how many seats. The number of seats per section is baked into the shader itself.

---

## the two-level structure

### dispatch counts workgroups, not invocations

`vkCmdDispatch(groupX, groupY, groupZ)` launches a 3-D grid of workgroups. The total workgroup count is `groupX × groupY × groupZ`. This is the "how many sections" number.

### local_size lives in the shader

Inside the compute shader, a layout qualifier declares the size of one workgroup — the number of invocations (seats) per section:

```glsl
// declare before main(): 64 invocations per workgroup, 1-D
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
```

See [compute pipelines and shaders](./compute-pipelines-and-shaders.md) for where this declaration lives and how it gets compiled into the pipeline.

### the total invocation count

```
total invocations = groupX × local_size_x
                  × groupY × local_size_y
                  × groupZ × local_size_z
```

That is the total number of shader copies the GPU launches. Each one runs independently.

---

## finding your data — the built-in variables

Every invocation gets a set of read-only built-in variables from the GPU. Think of them as the invocation's "ticket."

### the four key built-ins

| built-in | what it gives you |
|---|---|
| <em>gl_WorkGroupID</em> | which workgroup (section) this invocation belongs to |
| <em>gl_LocalInvocationID</em> | the seat number within that workgroup |
| <em>gl_GlobalInvocationID</em> | the combined global position in the full grid |
| <em>gl_NumWorkGroups</em> | the total workgroup count (matches the dispatch call) |

All four are `uvec3` — they carry x, y, z components even if you only use x.

### the standard index pattern

For a 1-D dispatch over an array, the pattern every compute shader uses:

```glsl
layout(local_size_x = 64) in;

void main() {
    uint index = gl_GlobalInvocationID.x;
    // use index to address your buffer
    data[index] = data[index] * 2.0;
}
```

`gl_GlobalInvocationID.x` is equivalent to `gl_WorkGroupID.x * local_size_x + gl_LocalInvocationID.x` — the GPU computes it for you.

For a 2-D image dispatch, use both `.x` and `.y` to address a pixel:

```glsl
layout(local_size_x = 16, local_size_y = 16) in;

void main() {
    uvec2 pixel = gl_GlobalInvocationID.xy;
    image[pixel] = process(image[pixel]);
}
```

---

## the rounding-up pitfall — the #1 beginner bug

Your data has N elements. Your local_size is 64. You need to dispatch enough groups to cover all N elements. That means:

```cpp
uint32_t groupCount = (N + 63) / 64;   // integer ceil(N / 64)
vkCmdDispatch(groupCount, 1, 1);
```

Because N is rarely a perfect multiple of 64, `groupCount × 64` will be **larger than N**. The last workgroup has more invocations than data elements to process.

The invocations past the end of your array will compute a valid-looking but out-of-bounds index. Without a guard, they write garbage to memory or read beyond your buffer.

**Every compute shader needs a bounds check:**

```glsl
void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= N) return;   // guard: early-out for over-dispatched invocations

    data[index] = data[index] * 2.0;
}
```

This is not optional boilerplate — it's load-bearing. Omitting it causes silent corruption.

---

## choosing local_size

The local size you declare in the shader is a compile-time constant. The right value depends on what the shader does.

### why multiples of 32 or 64 matter

GPU hardware executes invocations in lockstep groups called **warps** (NVIDIA, 32 lanes) or **wavefronts** (AMD, 64 lanes). The hardware name for this concept is the <em>warp/wavefront size</em>.

- If your local_size is not a multiple of the warp size, the last warp runs with some lanes idle — you pay for hardware that does no work.
- 64 is the safe conservative choice: it's a multiple of both 32 and 64, so it wastes nothing on either vendor.

### shared memory within a workgroup

All invocations in the same workgroup can read and write a fast on-chip scratchpad:

```glsl
shared float scratch[64];
```

This memory only exists for the lifetime of the workgroup and is only visible within it — no cross-workgroup communication. If your algorithm needs cooperation between invocations (prefix sums, reductions), size local_size to match the cooperation group.

### rules of thumb

- **1-D array work:** `local_size_x = 64`, y = z = 1. Simple and portable.
- **2-D image work:** `local_size_x = 16, local_size_y = 16` (256 invocations total, fits a warp boundary, maps naturally to pixel tiles).
- **Algorithms using shared memory:** match local_size to the size of the data-sharing group — e.g. 32 for a per-warp reduction.
- **Profile before over-tuning:** the GPU scheduler is good at hiding latency; a 2× change in local_size rarely changes throughput 2×.

### 1-D vs 2-D vs 3-D dispatch

| shape | when to use |
|---|---|
| 1-D `(groupX, 1, 1)` | linear arrays, buffers, element-wise ops |
| 2-D `(groupX, groupY, 1)` | images, 2-D grids — index with `.xy` |
| 3-D `(groupX, groupY, groupZ)` | volume data, 3-D textures |

Use the dimensionality that matches your data layout. Flattening a 2-D image into a 1-D dispatch works but loses the natural tile alignment that 2-D gives you for free.

---

## putting it together — the dispatch call in context

```cpp
// CPU side — record into a command buffer
uint32_t N = 1'000'000;
uint32_t localSize = 64;
uint32_t groupCount = (N + localSize - 1) / localSize;

vkCmdDispatch(commandBuffer, groupCount, 1, 1);
```

The GPU executes this later when the command buffer is submitted. Results written to a buffer or image are not guaranteed visible to subsequent work until you insert a pipeline barrier — see [compute barriers and async](./compute-barriers-and-async.md) for when and how to do that.

---

## summary

- `vkCmdDispatch(x, y, z)` launches a grid of workgroups; `local_size` (in the shader) sets invocations per workgroup.
- Total invocations = dispatch dims × local_size dims.
- Each invocation reads `gl_GlobalInvocationID` to compute its unique data index.
- Always dispatch `ceil(N / local_size)` groups and guard with `if (index >= N) return;`.
- Use local_size multiples of 64 for general work; use shared memory when invocations need to cooperate within a workgroup.
