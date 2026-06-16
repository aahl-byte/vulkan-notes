<link rel="stylesheet" href="./css/globals.css">

# debugging, validation & profiling

Vulkan does almost no error-checking at runtime — by design. That is where its speed comes from. The tradeoff is stark: mistakes that would produce a helpful error in OpenGL silently produce undefined behavior here. A wrong descriptor binding might corrupt memory. A missing layout transition might work fine on your GPU and explode on a customer's. Without tooling, the gap between "code compiles" and "code is correct" is invisible.

This page is about closing that gap. The goal is a workflow that turns silent misbehavior into a pointed message and turns vague slowness into a named bottleneck.

> The workflow in one sentence: **validation-clean first, then capture, then profile.** Never profile something that isn't correct.

---

## why vulkan skips the checks

Vulkan is explicit by philosophy — see [what vulkan actually is](../foundation/what-is-vulkan.md) for the full picture. The short version: every validation check a driver performs costs cycles. Drivers in earlier APIs (OpenGL, D3D11) do this for you at all times. Vulkan moves that cost to *opt-in tooling* so the shipping path pays nothing. The production driver trusts you completely.

This is the correct tradeoff. It means you, the developer, must opt *in* during development.

---

## the safety net: validation layers

Think of <em>validation layers</em> as a quality-control inspector sitting between your application and the Vulkan driver. Your calls go to the inspector first; the inspector checks them against the spec, logs any violations, then forwards the call onward. In production you fire the inspector and calls go straight to the driver — zero overhead.

Layers are not baked into the driver. They are optional shared libraries installed alongside the Vulkan SDK. You enable them at instance-creation time; if they are absent (shipped game) or not requested (release build), they simply do not run.

### enabling the validation layer

Enable `VK_LAYER_KHRONOS_validation` when creating your `VkInstance`. Before that, check that it is present:

```cpp
// Check availability
uint32_t layerCount;
vkEnumerateInstanceLayerProperties(&layerCount, nullptr);
std::vector<VkLayerProperties> available(layerCount);
vkEnumerateInstanceLayerProperties(&layerCount, available.data());

const char* wanted = "VK_LAYER_KHRONOS_validation";
bool found = std::any_of(available.begin(), available.end(),
    [&](const VkLayerProperties& p){ return strcmp(p.layerName, wanted) == 0; });

// Enable at instance creation (debug builds only)
VkInstanceCreateInfo createInfo{};
if (found && isDebugBuild) {
    createInfo.enabledLayerCount   = 1;
    createInfo.ppEnabledLayerNames = &wanted;
}
```

Wrapping this in a compile-time or runtime debug flag keeps the production path clean.

### the debug messenger

Enabling the layer alone is not enough — you also need a callback to receive its output. Create a `VkDebugUtilsMessengerEXT` right after instance creation:

```cpp
// The extension must also be requested at instance creation:
// VK_EXT_debug_utils

auto vkCreateDebugUtilsMessengerEXT =
    (PFN_vkCreateDebugUtilsMessengerEXT)
    vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");

VkDebugUtilsMessengerCreateInfoEXT messengerInfo{
    .sType           = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
    .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                     | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
    .messageType     = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
                     | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
                     | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
    .pfnUserCallback = debugCallback,
};

VkDebugUtilsMessengerEXT messenger;
vkCreateDebugUtilsMessengerEXT(instance, &messengerInfo, nullptr, &messenger);
```

Your callback receives severity, type, and a message string. Print it, log it, or — highly recommended — `assert(false)` on errors so the program stops the moment a violation occurs rather than limping forward into corruption.

### sub-layers: what each one catches

`VK_LAYER_KHRONOS_validation` is an umbrella. Inside it are distinct checkers you can toggle:

| sub-layer | what it watches |
|---|---|
| **core validation** (always on) | API call correctness — wrong types, out-of-range values, objects used after destruction |
| **synchronization validation** | hazards: read-after-write, write-after-write with no barrier; the hardest class of Vulkan bugs to find manually — see [synchronization deep dive](./synchronization-deep-dive.md) |
| **GPU-assisted validation** | descriptor indexing out of bounds, uninitialized descriptor reads; runs a small shader alongside your shaders to catch what the CPU cannot |
| **best practices** | non-spec but performance-impacting patterns — using a feature unsupported on mobile, suboptimal image layouts, redundant clears |
| **shader printf** | `debugPrintfEXT` output from within shaders; lets you add printf-style logging to GLSL/HLSL without a full capture tool |

Turn synchronization validation on. GPU-assisted validation is heavier (it instruments your shaders) but pays off when descriptor corruption is the suspect.

---

## reading validation output

A validation message looks like this:

```
VUID-VkImageMemoryBarrier-oldLayout-01197(ERROR/SPEC):
  msgNum: -123456 | object 0x... | Attempted to transition image from
  UNDEFINED to SHADER_READ_ONLY_OPTIMAL without a prior write.
```

The key piece is the <em>VUID</em> — Valid Usage ID. It is a stable identifier that maps directly to a single requirement in the Vulkan specification. Every VUID is a link. The format `VUID-<struct/command>-<parameter>-<number>` tells you exactly which rule was broken and where in the spec to read the normative text.

**Treat every validation error as a real bug.** No exceptions. The temptation is to dismiss errors that "seem harmless" or that produce visually correct output. Validation errors fire on spec violations, not on visible symptoms — a violation that looks harmless on your GPU today is undefined behavior, and undefined behavior breaks on other hardware and driver versions.

### common categories and where they come from

- **image layout transitions** — using an image in `UNDEFINED` or the wrong layout for the access type. Common in render-pass setup and texture uploads. See the [image layouts](../rendering/image-layouts-and-transitions.md) page.
- **synchronization hazards** — pipeline stages writing and reading without a barrier in between. The synchronization validation sub-layer catches these; the [synchronization deep dive](./synchronization-deep-dive.md) explains why they happen.
- **descriptor mismatches** — binding a buffer where a sampler is expected, or binding nothing to a slot the shader reads. GPU-assisted validation catches the ones that get past the CPU checks.
- **object lifetime violations** — using a `VkBuffer` or `VkPipeline` that has been destroyed, or destroying it while a command buffer is still in flight. Core validation catches these immediately.

---

## debug naming and labels

Validation output and GPU capture tools refer to Vulkan objects by their internal handle — a hex number. `0x000000009b3c10f0` is not a useful name in an error message.

`VK_EXT_debug_utils` (the same extension as the messenger) lets you attach names to any object and annotate command buffer regions with labels. These names propagate into validation messages, RenderDoc captures, and vendor profiler timelines.

### naming an object

```cpp
VkDebugUtilsObjectNameInfoEXT nameInfo{
    .sType        = VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
    .objectType   = VK_OBJECT_TYPE_IMAGE,
    .objectHandle = (uint64_t)shadowMap,
    .pObjectName  = "shadow_map_depth",
};
vkSetDebugUtilsObjectNameEXT(device, &nameInfo);
```

Now when validation prints an error involving this image, it says `shadow_map_depth` instead of a raw handle.

### command buffer labels

```cpp
VkDebugUtilsLabelEXT labelInfo{
    .sType      = VK_STRUCTURE_TYPE_DEBUG_UTILS_LABEL_EXT,
    .pLabelName = "shadow pass",
    .color      = {0.8f, 0.2f, 0.2f, 1.0f},
};
vkCmdBeginDebugUtilsLabelEXT(cmd, &labelInfo);
// ... shadow-pass draw calls ...
vkCmdEndDebugUtilsLabelEXT(cmd);
```

In a RenderDoc capture these regions appear as named, color-coded brackets in the event list. In a profiler timeline they show where one logical pass ends and another begins. This is cheap to leave in debug builds; strip with a compile-time flag for release.

---

## frame debuggers and profilers

Once the code is validation-clean, the next question is either "is this *right*?" or "is this *fast enough*?". Different tools answer different questions.

### which tool for which question

| question | tool |
|---|---|
| Why is this draw wrong? Why is this texture black? | **RenderDoc** |
| Where is the GPU spending time? Which pass is the bottleneck? | vendor profiler (Nsight / RGP / GPA) |
| How long does pass X take? Is the GPU idle between passes? | GPU timestamp queries (in-engine) |
| How many primitives/invocations are going through this pipeline? | pipeline statistics queries (in-engine) |
| Is the bottleneck on the CPU or GPU? | timestamp queries + CPU timer, or vendor profiler |

### renderdoc — inspect a frame

<em>RenderDoc</em> is a free, open-source frame capture tool. It intercepts a single frame, records every Vulkan call, and lets you replay it in a GUI. After a capture you can:

- Walk the event list and jump to any draw call.
- Inspect every bound resource at the moment of that draw — textures, buffers, descriptor sets, pipeline state.
- See the mesh going into the vertex shader and the pixels coming out of the fragment shader.
- Replay individual draw calls in isolation to isolate a visual artifact.

Use RenderDoc first whenever something looks wrong visually. It answers "what was Vulkan actually given" rather than "what did you think you gave it." Debug names and command labels make the event list navigable instead of a wall of `vkCmdDraw` entries.

RenderDoc also has a built-in validation layer integration — it can show validation errors alongside the events that triggered them.

### vendor profilers — find the bottleneck

Vendor profilers understand the specific GPU microarchitecture. They report timing at the hardware counter level:

- **NVIDIA Nsight Graphics** — deep integration with NVIDIA GPUs; per-pass GPU duration, occupancy, cache hit rates, warp efficiency.
- **AMD Radeon GPU Profiler (RGP)** — pipeline stall analysis, barrier visualization, async compute overlap.
- **Intel GPA (Graphics Performance Analyzers)** — frame analysis and GPU timing for Intel integrated and discrete GPUs.

These tools answer "where exactly is time being spent" with a precision that timestamp queries and generic tools cannot match. Use them after you know the code is correct and you have a specific performance hypothesis to test.

### in-engine timing: timestamp queries

For continuous in-engine measurement — not a one-off capture — use Vulkan's own query system.

A <em>GPU timestamp query</em> records the GPU clock at a point in a command buffer. Wrapping a render pass with two queries and subtracting gives its GPU duration:

```cpp
// Pool creation (done once)
VkQueryPoolCreateInfo poolInfo{
    .sType      = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
    .queryType  = VK_QUERY_TYPE_TIMESTAMP,
    .queryCount = 2,
};
VkQueryPool timestampPool;
vkCreateQueryPool(device, &poolInfo, nullptr, &timestampPool);

// In the command buffer
vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,    timestampPool, 0);
// ... render pass commands ...
vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, timestampPool, 1);

// After submission completes, read results
uint64_t timestamps[2];
vkGetQueryPoolResults(device, timestampPool, 0, 2,
    sizeof(timestamps), timestamps, sizeof(uint64_t),
    VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);

// Convert ticks to nanoseconds using the device's timestampPeriod
float gpuMs = (timestamps[1] - timestamps[0])
            * physicalDeviceProperties.limits.timestampPeriod * 1e-6f;
```

`timestampPeriod` is the number of nanoseconds per timestamp tick — query it once from `VkPhysicalDeviceLimits`.

### pipeline statistics queries

A <em>pipeline statistics query</em> counts hardware events over a range of draw calls — input vertices, clipped primitives, fragment shader invocations, compute invocations, and more:

```cpp
VkQueryPoolCreateInfo statsPoolInfo{
    .sType              = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
    .queryType          = VK_QUERY_TYPE_PIPELINE_STATISTICS,
    .queryCount         = 1,
    .pipelineStatistics = VK_QUERY_PIPELINE_STATISTIC_FRAGMENT_SHADER_INVOCATIONS_BIT
                        | VK_QUERY_PIPELINE_STATISTIC_CLIPPING_PRIMITIVES_BIT,
};
```

Use these to verify that your culling is working (are the expected primitives being clipped?) or to measure how many fragment shader invocations a pass generates before and after an optimization.

---

## the workflow

Validation, capture, and profiling are not alternatives — they are a sequence. Running them out of order wastes time.

### step 1: validation-clean first

Run with `VK_LAYER_KHRONOS_validation` enabled, synchronization validation on, and your debug callback set to `assert` on errors. Fix every error before proceeding. A validation error means the behavior is undefined — anything you observe after that point, including correct-looking output, is unreliable.

This phase catches the vast majority of bugs: wrong usage, lifetime errors, sync hazards.

### step 2: capture with renderdoc

Once validation is clean and the output looks wrong (or you want to verify it looks right), take a RenderDoc capture. Walk the event list with your named objects and labeled regions. Verify that each pass is receiving the resources you expect in the state you expect.

This phase answers correctness questions that validation cannot — validation checks the API contract, not "is this the right image to sample from."

### step 3: profile

Only after step 1 and step 2 — when the code is known-correct — add timestamp queries to identify which passes are expensive. Then open a vendor profiler on those passes to find why.

### cpu-bound vs gpu-bound

Before profiling GPU passes, know whether the bottleneck is on the CPU or GPU. A common pattern:

- If the GPU finishes well before the next frame's command buffer arrives (GPU idle time), you are CPU-bound. Adding GPU passes will not help.
- If the CPU is always waiting for the GPU to finish, you are GPU-bound. Optimize the heavy passes.

Timestamp queries on the GPU side paired with a CPU timer on the submission side reveal which is true. Vendor profilers show GPU idle/stall time directly. For the broader performance picture this ties into the multithreading and CPU-side cost topics in the advanced track.

---

## quick reference

**enable for every debug build:**
- `VK_LAYER_KHRONOS_validation` with sync validation on
- `VK_EXT_debug_utils` messenger asserting on errors
- `vkSetDebugUtilsObjectNameEXT` on every long-lived object
- `vkCmdBeginDebugUtilsLabelEXT` around logical passes

**workflow order:** validation-clean → RenderDoc capture → vendor profiler → timestamp queries

**VUIDs:** every error has a stable id that links to the spec. Look it up before dismissing it.
