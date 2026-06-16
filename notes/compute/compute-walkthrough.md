<link rel="stylesheet" href="./css/globals.css">

# compute walkthrough — ssbo in, dispatch, read back

you want to run a computation on a large array of floats and get the results back. by the end of this page you will have done exactly that — every element multiplied by a constant, the transformed values sitting in host-readable memory, verified on the CPU. that is the concrete goal.

this page assembles every concept from the compute track into one working sequence. if something looks unfamiliar, the links below lead back to its home page — this page is the synthesis, not the foundation.

---

## the bird's-eye sequence

before a single line of code, here is the full flow in plain English. read it once, then we will walk each step with a snippet and a one-line "why."

1. **pick a device and a compute queue** — the GPU that will do the work and the channel we will send commands through.
2. **create an SSBO for input and one for output** — shader storage buffers hold the data; see [../foundation/buffers-and-memory.md](../foundation/buffers-and-memory.md) for how Vulkan thinks about buffer memory.
3. **fill the input buffer** — write the float array into GPU-accessible memory, either directly (host-visible) or through a staging copy.
4. **describe the layout, allocate a descriptor set, write it** — tell Vulkan which bindings the shader expects, then wire the actual buffers to those slots.
5. **build the compute pipeline from the GLSL shader** — compile the shader to SPIR-V, wrap it in a pipeline; details in [./compute-pipelines-and-shaders.md](./compute-pipelines-and-shaders.md).
6. **record a command buffer** — bind the pipeline, bind the descriptor set, `vkCmdDispatch` with the right group count; the dispatch math lives in [./dispatch-and-workgroups.md](./dispatch-and-workgroups.md).
7. **insert a pipeline barrier** — stall the pipeline so the shader writes are visible before the CPU reads; the reason this matters is in [./compute-barriers-and-async.md](./compute-barriers-and-async.md).
8. **copy or map the output buffer** — bring the results back to the CPU.
9. **submit and wait on a fence** — enqueue the command buffer, then block until the GPU is done.
10. **read and verify** — map the output, check the numbers.

that is the whole shape. the rest of this page is that same list with code attached.

---

## the shader — what runs on the gpu

the computation is <em>SAXPY-lite</em>: multiply every element of array `x` by constant `a` and write it into array `y`. one thread per element, bounds-checked so out-of-range invocations are harmless.

```glsl
// multiply.comp
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0) readonly buffer InputBuf  { float x[]; };
layout(set = 0, binding = 1)          buffer OutputBuf { float y[]; };

layout(push_constant) uniform Params {
    float a;
    uint  n;
} params;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= params.n) return;   // bounds-check — every real shader needs this
    y[i] = params.a * x[i];
}
```

the `local_size_x = 64` means each workgroup launches 64 threads. the global index `gl_GlobalInvocationID.x` is computed by Vulkan from the group count you pass to `vkCmdDispatch`. the bounds-check (`if (i >= params.n) return`) is not optional — when `N` is not a multiple of 64 the last workgroup has threads that point past the end of the array.

compile to SPIR-V before use:

```
glslc multiply.comp -o multiply.comp.spv
```

---

## step 1 — device and compute queue

pick a `VkPhysicalDevice` that exposes a queue family with `VK_QUEUE_COMPUTE_BIT`. create a `VkDevice` and retrieve the queue. this is identical to the setup in [../foundation/instances-and-devices.md](../foundation/instances-and-devices.md) — nothing compute-specific here except which queue family flag you filter on.

```cpp
// find a queue family index that supports compute
uint32_t computeQueueFamily = UINT32_MAX;
for (uint32_t i = 0; i < queueFamilyCount; ++i) {
    if (queueFamilies[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
        computeQueueFamily = i;
        break;
    }
}

VkQueue computeQueue;
vkGetDeviceQueue(device, computeQueueFamily, 0, &computeQueue);
```

why: every GPU command must be submitted to a queue that declares support for the operation. picking the wrong family gives a validation error immediately.

---

## step 2 — create input and output ssbos

an <em>SSBO (shader storage buffer object)</em> is a `VkBuffer` bound as `VK_BUFFER_USAGE_STORAGE_BUFFER_BIT`. create two: one for input, one for output.

```cpp
const uint32_t N = 1024 * 1024;  // 1 M floats
const VkDeviceSize bufSize = N * sizeof(float);

// same helper called twice — only the usage flags differ
VkBuffer     inputBuf,  outputBuf;
VkDeviceMemory inputMem, outputMem;

createBuffer(device, physicalDevice, bufSize,
    VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    inputBuf, inputMem);

createBuffer(device, physicalDevice, bufSize,
    VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    outputBuf, outputMem);
```

why `HOST_VISIBLE | HOST_COHERENT` for both here: for a first walkthrough this is the simplest path — the CPU can write and read without a staging copy. the tradeoff section at the bottom explains when to use device-local memory instead.

`createBuffer` is a thin wrapper around `vkCreateBuffer` + `vkAllocateMemory` + `vkBindBufferMemory`. the full implementation is not reproduced here; it is the standard pattern from [../foundation/buffers-and-memory.md](../foundation/buffers-and-memory.md).

---

## step 3 — fill the input buffer

with host-visible memory, writing is a `vkMapMemory` → `memcpy` → `vkUnmapMemory`:

```cpp
void* ptr;
vkMapMemory(device, inputMem, 0, bufSize, 0, &ptr);

float* data = static_cast<float*>(ptr);
for (uint32_t i = 0; i < N; ++i)
    data[i] = static_cast<float>(i);  // 0.0, 1.0, 2.0, ...

vkUnmapMemory(device, inputMem);
```

why: `vkMapMemory` returns a CPU pointer into the buffer's backing memory. `HOST_COHERENT` means we do not need an explicit flush — the GPU sees the write as soon as `vkUnmapMemory` returns.

---

## step 4 — descriptor set layout, pool, and set

Vulkan does not let shaders access buffers directly. you describe *what kind of resource sits at each binding* (the layout), allocate a container (the pool and set), then plug in the actual buffers (the write).

```cpp
// --- layout ---
VkDescriptorSetLayoutBinding bindings[2] = {};
bindings[0].binding         = 0;
bindings[0].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
bindings[0].descriptorCount = 1;
bindings[0].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;

bindings[1].binding         = 1;
bindings[1].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
bindings[1].descriptorCount = 1;
bindings[1].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;

VkDescriptorSetLayoutCreateInfo layoutInfo{};
layoutInfo.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
layoutInfo.bindingCount = 2;
layoutInfo.pBindings    = bindings;

VkDescriptorSetLayout descSetLayout;
vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr, &descSetLayout);

// --- pool ---
VkDescriptorPoolSize poolSize{};
poolSize.type            = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
poolSize.descriptorCount = 2;

VkDescriptorPoolCreateInfo poolInfo{};
poolInfo.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
poolInfo.maxSets       = 1;
poolInfo.poolSizeCount = 1;
poolInfo.pPoolSizes    = &poolSize;

VkDescriptorPool descPool;
vkCreateDescriptorPool(device, &poolInfo, nullptr, &descPool);

// --- allocate ---
VkDescriptorSetAllocateInfo allocInfo{};
allocInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
allocInfo.descriptorPool     = descPool;
allocInfo.descriptorSetCount = 1;
allocInfo.pSetLayouts        = &descSetLayout;

VkDescriptorSet descSet;
vkAllocateDescriptorSets(device, &allocInfo, &descSet);

// --- write (wire the actual buffers) ---
VkDescriptorBufferInfo inBufInfo{};
inBufInfo.buffer = inputBuf;
inBufInfo.offset = 0;
inBufInfo.range  = bufSize;

VkDescriptorBufferInfo outBufInfo{};
outBufInfo.buffer = outputBuf;
outBufInfo.offset = 0;
outBufInfo.range  = bufSize;

VkWriteDescriptorSet writes[2] = {};
writes[0].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
writes[0].dstSet          = descSet;
writes[0].dstBinding      = 0;
writes[0].descriptorCount = 1;
writes[0].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
writes[0].pBufferInfo     = &inBufInfo;

writes[1].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
writes[1].dstSet          = descSet;
writes[1].dstBinding      = 1;
writes[1].descriptorCount = 1;
writes[1].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
writes[1].pBufferInfo     = &outBufInfo;

vkUpdateDescriptorSets(device, 2, writes, 0, nullptr);
```

why three steps: the layout is reusable (multiple sets can share it). the pool is a memory budget. the write is what actually connects buffer → binding.

---

## step 5 — build the compute pipeline

load the SPIR-V, wrap it in a `VkShaderModule`, then create the pipeline. push constants carry `a` and `n` without touching descriptor sets.

```cpp
// load SPIR-V bytes from disk (omitted for brevity — read file into vector<uint32_t>)

VkShaderModuleCreateInfo smInfo{};
smInfo.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
smInfo.codeSize = spirvCode.size() * sizeof(uint32_t);
smInfo.pCode    = spirvCode.data();

VkShaderModule shaderModule;
vkCreateShaderModule(device, &smInfo, nullptr, &shaderModule);

// push constant range for { float a, uint n }
VkPushConstantRange pcRange{};
pcRange.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
pcRange.offset     = 0;
pcRange.size       = sizeof(float) + sizeof(uint32_t);

VkPipelineLayoutCreateInfo plInfo{};
plInfo.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
plInfo.setLayoutCount         = 1;
plInfo.pSetLayouts            = &descSetLayout;
plInfo.pushConstantRangeCount = 1;
plInfo.pPushConstantRanges    = &pcRange;

VkPipelineLayout pipelineLayout;
vkCreatePipelineLayout(device, &plInfo, nullptr, &pipelineLayout);

VkComputePipelineCreateInfo cpInfo{};
cpInfo.sType  = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
cpInfo.stage.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
cpInfo.stage.stage  = VK_SHADER_STAGE_COMPUTE_BIT;
cpInfo.stage.module = shaderModule;
cpInfo.stage.pName  = "main";
cpInfo.layout       = pipelineLayout;

VkPipeline computePipeline;
vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cpInfo, nullptr, &computePipeline);
```

a compute pipeline has exactly one stage (the compute shader). there is no rasterizer, no vertex input, no render pass. this is why [./compute-pipelines-and-shaders.md](./compute-pipelines-and-shaders.md) is short — the pipeline is as minimal as they come.

---

## step 6 — record the command buffer

```cpp
VkCommandPool cmdPool;
VkCommandPoolCreateInfo cpoolInfo{};
cpoolInfo.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
cpoolInfo.queueFamilyIndex = computeQueueFamily;
vkCreateCommandPool(device, &cpoolInfo, nullptr, &cmdPool);

VkCommandBuffer cmd;
VkCommandBufferAllocateInfo cmdAllocInfo{};
cmdAllocInfo.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
cmdAllocInfo.commandPool        = cmdPool;
cmdAllocInfo.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
cmdAllocInfo.commandBufferCount = 1;
vkAllocateCommandBuffers(device, &cmdAllocInfo, &cmd);

VkCommandBufferBeginInfo beginInfo{};
beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
vkBeginCommandBuffer(cmd, &beginInfo);

    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, computePipeline);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE,
                            pipelineLayout, 0, 1, &descSet, 0, nullptr);

    struct { float a; uint32_t n; } pc{ 2.0f, N };
    vkCmdPushConstants(cmd, pipelineLayout,
                       VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);

    // dispatch ceil(N / 64) groups
    uint32_t groupCount = (N + 63) / 64;
    vkCmdDispatch(cmd, groupCount, 1, 1);

vkEndCommandBuffer(cmd);
```

the group count formula `(N + 63) / 64` is integer division that rounds up. that is the dispatch math from [./dispatch-and-workgroups.md](./dispatch-and-workgroups.md) — every element gets a thread, and the shader's bounds-check neutralises any threads that go past `N`.

---

## step 7 — barrier before readback

the GPU can reorder work. without a barrier, a CPU `vkMapMemory` might read stale data from before the shader finished writing.

```cpp
// record this BEFORE vkEndCommandBuffer, immediately after vkCmdDispatch
VkMemoryBarrier memBarrier{};
memBarrier.sType         = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
memBarrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
memBarrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;

vkCmdPipelineBarrier(
    cmd,
    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,  // wait for this stage to finish...
    VK_PIPELINE_STAGE_HOST_BIT,            // ...before this stage proceeds
    0,
    1, &memBarrier,
    0, nullptr,
    0, nullptr
);
```

why `HOST_BIT` as the destination: the read happens on the CPU (host), not in another shader stage. the barrier tells Vulkan "the compute shader's writes must be visible to the host before the host reads." the full reasoning for why barriers exist at all is in [./compute-barriers-and-async.md](./compute-barriers-and-async.md).

---

## step 8 — submit and wait on a fence

```cpp
VkFence fence;
VkFenceCreateInfo fenceInfo{};
fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
vkCreateFence(device, &fenceInfo, nullptr, &fence);

VkSubmitInfo submitInfo{};
submitInfo.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
submitInfo.commandBufferCount = 1;
submitInfo.pCommandBuffers    = &cmd;
vkQueueSubmit(computeQueue, 1, &submitInfo, fence);

// block until the GPU finishes
vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
```

why a fence instead of just waiting: the CPU and GPU run concurrently. `vkQueueSubmit` returns immediately — the GPU has not finished. `vkWaitForFences` is the explicit sync point that blocks the CPU until the fence signals. without it you would read output before the shader ran.

---

## step 9 — read back and verify

```cpp
void* outPtr;
vkMapMemory(device, outputMem, 0, bufSize, 0, &outPtr);

float* result = static_cast<float*>(outPtr);
bool   ok     = true;
for (uint32_t i = 0; i < N; ++i) {
    if (result[i] != 2.0f * static_cast<float>(i)) { ok = false; break; }
}

vkUnmapMemory(device, outputMem);
printf(ok ? "PASS\n" : "FAIL\n");
```

success: every `result[i]` equals `2.0 * i`. the GPU ran your code, the numbers are right, and you read them back on the CPU.

---

## three things beginners get wrong

### 1. forgetting the bounds-check in the shader

when `N` is not a multiple of `local_size_x`, the last workgroup has threads with `gl_GlobalInvocationID.x >= N`. without `if (i >= params.n) return` those threads write to memory past the end of the buffer — undefined behaviour and likely a crash or corruption.

- always pass `N` into the shader (push constant or a UBO field)
- always bounds-check before any memory access

### 2. forgetting the barrier before readback

the GPU does not automatically flush writes to the CPU. without `vkCmdPipelineBarrier` after the dispatch, the CPU may read the output buffer before the shader writes have propagated. the barrier is not optional — it is the instruction that makes the writes visible.

- source stage: `VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT`
- destination stage: `VK_PIPELINE_STAGE_HOST_BIT`
- access masks: `SHADER_WRITE` → `HOST_READ`

### 3. host-visible vs device-local memory

| memory type | CPU writes | GPU throughput | right for |
|---|---|---|---|
| `HOST_VISIBLE \| HOST_COHERENT` | direct map+memcpy | lower — memory is in the CPU's address space | small buffers, prototyping, staging buffers |
| `DEVICE_LOCAL` | not directly — needs a staging copy | highest — memory is on the GPU | large buffers in production |

this walkthrough uses host-visible for both input and output because it keeps the code short. in a real application with large data:

- allocate a <em>staging buffer</em> (`HOST_VISIBLE`) and a <em>device-local buffer</em> for each SSBO
- copy input from staging → device-local via `vkCmdCopyBuffer` before the dispatch
- copy output from device-local → staging after the barrier
- map and read from the staging buffer on the CPU

that extra copy is worth it because device-local memory is typically 5–10× faster for the GPU to read and write.

---

## cleanup

always destroy in reverse creation order:

```cpp
vkDestroyFence(device, fence, nullptr);
vkFreeCommandBuffers(device, cmdPool, 1, &cmd);
vkDestroyCommandPool(device, cmdPool, nullptr);
vkDestroyPipeline(device, computePipeline, nullptr);
vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
vkDestroyShaderModule(device, shaderModule, nullptr);
vkDestroyDescriptorPool(device, descPool, nullptr);
vkDestroyDescriptorSetLayout(device, descSetLayout, nullptr);
vkFreeMemory(device, outputMem, nullptr);
vkDestroyBuffer(device, outputBuf, nullptr);
vkFreeMemory(device, inputMem, nullptr);
vkDestroyBuffer(device, inputBuf, nullptr);
```

---

## what to change to make this real

the walkthrough above is the minimal skeleton. here is what a production compute job looks like in contrast:

- **bigger data / device-local memory** — add staging buffers as described above; allocate with `VMA` (Vulkan Memory Allocator) rather than raw `vkAllocateMemory` to avoid hitting `maxMemoryAllocationCount`.
- **multiple dispatches in one command buffer** — record several `vkCmdDispatch` calls with barriers between stages. submitting one large command buffer is cheaper than many small submissions.
- **async compute** — use a separate compute queue (different queue family) and synchronize with semaphores between the compute work and graphics work. the async model and its pitfalls are in [./compute-barriers-and-async.md](./compute-barriers-and-async.md).
- **reuse the command buffer** — instead of `ONE_TIME_SUBMIT_BIT`, record once and submit many times. reset the pool when you need a fresh recording.
- **where rendering picks up** — rendering builds on exactly this skeleton: swap SSBOs for image attachments, add a graphics pipeline, a render pass, and a swapchain. the compute foundation you just built (queues, pipelines, descriptors, sync) is reused unchanged.

---

## summary — what you just assembled

| piece | vulkan object | purpose |
|---|---|---|
| data in/out | `VkBuffer` + `VkDeviceMemory` | holds the float arrays on the GPU |
| resource wiring | `VkDescriptorSetLayout`, `VkDescriptorPool`, `VkDescriptorSet` | tells the shader where to find the buffers |
| the program | `VkShaderModule`, `VkPipeline`, `VkPipelineLayout` | the compiled GLSL + the pipeline that runs it |
| the work order | `VkCommandBuffer`, `vkCmdDispatch` | records what to do |
| the visibility guarantee | `vkCmdPipelineBarrier` | ensures shader writes are done before the CPU reads |
| the sync point | `VkFence` | blocks the CPU until the GPU is finished |
