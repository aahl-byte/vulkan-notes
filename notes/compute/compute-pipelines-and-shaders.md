<link rel="stylesheet" href="./css/globals.css">

# compute pipelines & shaders

The goal is to run arbitrary code on the GPU — in parallel, across thousands of threads at once. To do that you need two things: a **shader**, which is the program that runs, and a **pipeline**, which is the Vulkan object that packages that shader and tells the GPU how to invoke it. Once you have the pipeline, you bind it and dispatch work.

If you're here because you want to know *why* bother with compute at all, start at [why compute?](./why-compute.md) first.

---

## the coarse model first

Think of a compute pipeline like a **recipe card clipped to a kitchen hook.** The card says which recipe to use and what ingredients it expects. The GPU is the kitchen. When you say "execute," the kitchen pulls down the card and runs the recipe.

The recipe card is small and specific — exactly one recipe (shader), exactly one ingredients list (pipeline layout). That is the entire compute pipeline.

This is also why Vulkan's compute pipeline is the simplest pipeline the API offers.

---

## compute vs graphics: why this is the easy one

A graphics pipeline is sprawling — vertex input, primitive assembly, rasterization, depth testing, blending. Configuring it takes a dozen structs.

A <em>compute pipeline</em> has exactly one stage: the compute shader. No rasterizer, no blend state, no render pass. The full creation struct has three real fields: the shader stage, the pipeline layout, and an optional base pipeline for derivatives.

When to reach for each:

- **compute pipeline** — any workload that does not produce a rasterized image: simulation, physics, image post-processing, AI inference, indirect argument generation.
- **graphics pipeline** — anything that needs fixed-function rasterization to turn geometry into fragments.

If there is no rasterizer in your mental picture of the task, you want a compute pipeline.

---

## the moving parts

### the compute shader

A compute shader is a GLSL source file (`.comp`) that the GPU will execute in parallel across many threads. The key pieces are:

- `#version 450` — required, declares the GLSL version.
- `layout(local_size_x = N, local_size_y = 1, local_size_z = 1) in;` — declares how many threads form one **workgroup**. The meaning of this number is explored in depth on the [dispatch and workgroups](./dispatch-and-workgroups.md) page; for now treat it as "the batch size the shader expects."
- `void main()` — the entry point, runs once per thread.

A minimal compute shader that doubles every element of a buffer:

```glsl
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) buffer DataBuffer {
    float data[];
} buf;

void main() {
    uint i = gl_GlobalInvocationID.x;
    buf.data[i] = buf.data[i] * 2.0;
}
```

Two things to notice here:

1. `gl_GlobalInvocationID.x` is the built-in that gives each thread its unique index. This is how thousands of threads avoid stomping on each other's data.
2. The `layout(set = 0, binding = 0) buffer` line is the shader's claim on a resource. It must match the descriptor set layout you created on the CPU side — see [descriptors](../foundation/descriptors.md) for how that binding is established.

### compiling GLSL to SPIR-V

Vulkan does not accept GLSL source. It consumes <em>SPIR-V</em> — a binary intermediate representation designed to be GPU-vendor-neutral and fast to parse at runtime. You compile offline (or at build time) with either:

- **`glslangValidator`** (reference compiler, ships with the Vulkan SDK): `glslangValidator -V shader.comp -o shader.comp.spv`
- **`glslc`** (Google's compiler, same SDK): `glslc shader.comp -o shader.comp.spv`

Both produce a `.spv` file. Why SPIR-V instead of GLSL source?

- **No runtime compilation overhead** — the driver only needs to translate SPIR-V to its own ISA, which is fast. Parsing and compiling GLSL would be slow and driver-dependent.
- **Portability** — one SPIR-V binary works across AMD, NVIDIA, Intel, and mobile without re-compiling.
- **Determinism** — you validate and optimize the shader in your build pipeline, not at the user's runtime.

### VkShaderModule

Once you have a `.spv` file, you load the bytes and hand them to Vulkan as a <em>VkShaderModule</em>. This is just a thin wrapper around the SPIR-V blob.

```cpp
// load SPIR-V bytes from disk
std::vector<char> code = readFile("shader.comp.spv");

VkShaderModuleCreateInfo moduleInfo{};
moduleInfo.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
moduleInfo.codeSize = code.size();
moduleInfo.pCode    = reinterpret_cast<const uint32_t*>(code.data());

VkShaderModule shaderModule;
vkCreateShaderModule(device, &moduleInfo, nullptr, &shaderModule);
```

The shader module is a one-time creation. After the pipeline is built you can destroy the module — the compiled code lives inside the pipeline object.

### the pipeline layout

Before creating the pipeline, Vulkan needs to know what resources the shader expects. This is the <em>pipeline layout</em> — it lists the descriptor set layouts and push constant ranges the shader will use.

```cpp
VkPipelineLayoutCreateInfo layoutInfo{};
layoutInfo.sType          = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
layoutInfo.setLayoutCount = 1;
layoutInfo.pSetLayouts    = &descriptorSetLayout; // from your descriptor setup
// push constants covered below

VkPipelineLayout pipelineLayout;
vkCreatePipelineLayout(device, &layoutInfo, nullptr, &pipelineLayout);
```

The descriptor set layout here is the same object you created when setting up the SSBO binding — the shader's `layout(set=0, binding=0)` declaration must agree with it. The [descriptors page](../foundation/descriptors.md) walks through building that layout.

### creating the compute pipeline

Now the pipeline itself. The creation struct is deliberately lean:

```cpp
VkPipelineShaderStageCreateInfo stageInfo{};
stageInfo.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
stageInfo.stage  = VK_SHADER_STAGE_COMPUTE_BIT;
stageInfo.module = shaderModule;
stageInfo.pName  = "main"; // entry point name in the GLSL

VkComputePipelineCreateInfo pipelineInfo{};
pipelineInfo.sType  = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
pipelineInfo.stage  = stageInfo;
pipelineInfo.layout = pipelineLayout;

VkPipeline computePipeline;
vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &computePipeline);
```

`vkCreateComputePipelines` accepts an array so you can batch-create pipelines — the driver can compile them in parallel. The second argument is an optional pipeline cache; pass `VK_NULL_HANDLE` to start without one.

After this call, the pipeline is a GPU-resident compiled program ready to run.

---

## the shader-resource connection

The shader's `layout(set = 0, binding = 0) buffer DataBuffer` declaration is a contract. It says:

> "At descriptor set 0, binding slot 0, I expect a storage buffer (`buffer` keyword = SSBO)."

The CPU side must honour that contract by:

1. Creating a `VkDescriptorSetLayout` that declares `binding = 0` as `VK_DESCRIPTOR_TYPE_STORAGE_BUFFER`.
2. Allocating a `VkDescriptorSet` from that layout.
3. Writing the actual `VkBuffer` into that binding via `vkUpdateDescriptorSets`.

The pipeline layout holds the descriptor set layout; the descriptor set holds the actual buffer. When you call `vkCmdBindDescriptorSets` before dispatching, Vulkan connects the live buffer to the shader's binding slot.

See [descriptors](../foundation/descriptors.md) for the full setup.

---

## push constants: tiny fast per-dispatch data

Push constants are a small block of data (typically ≤ 128 bytes) you can update with a single command-buffer call — no descriptor, no buffer, no synchronisation overhead. They're the right tool for data that changes every dispatch: a frame index, a threshold value, grid dimensions.

```cpp
// in the pipeline layout:
VkPushConstantRange pushRange{};
pushRange.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
pushRange.offset     = 0;
pushRange.size       = sizeof(uint32_t); // e.g. element count

// in the shader:
// layout(push_constant) uniform Params { uint count; } params;

// at record time:
uint32_t count = 1024;
vkCmdPushConstants(cmd, pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(count), &count);
```

When to use push constants vs a uniform buffer:

- **push constants** — data that is small (≤ 128 bytes) and changes per dispatch. Zero allocation overhead.
- **uniform buffer** — data that is larger, shared across many shaders, or updated less frequently. Needs a buffer and descriptor.

---

## local_size: declared here, explained next

The shader's `layout(local_size_x = 64)` line is the shader declaring its own workgroup dimensions. You have seen it twice already. The meaning — what a workgroup *is*, how many you dispatch, how threads are indexed — is the subject of [dispatch and workgroups](./dispatch-and-workgroups.md). It lives there because it is inseparable from `vkCmdDispatch`.

For now the rule is: pick a `local_size_x` that is a multiple of 32 or 64 (matching your GPU's warp/wavefront size). 64 is a safe default for most hardware.

---

## putting it in order

To get a compute pipeline running you work through these steps once (at setup time):

1. Write the GLSL `.comp` shader.
2. Compile it to SPIR-V (`glslc` or `glslangValidator`).
3. Create a `VkShaderModule` from the `.spv` bytes.
4. Create a `VkDescriptorSetLayout` describing the shader's bindings.
5. Create a `VkPipelineLayout` referencing that layout (and any push constant ranges).
6. Create the `VkComputePipeline` via `vkCreateComputePipelines`.
7. Destroy the shader module — it is no longer needed.

Then at record time, per dispatch:

- `vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, computePipeline)`
- `vkCmdBindDescriptorSets(...)` — connect the buffers
- `vkCmdPushConstants(...)` — if used
- `vkCmdDispatch(...)` — the actual launch, covered in [dispatch and workgroups](./dispatch-and-workgroups.md)
