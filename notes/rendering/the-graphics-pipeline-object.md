<link rel="stylesheet" href="./css/globals.css">

# the graphics pipeline object

to draw anything in Vulkan, you pre-bake the entire configuration of the GPU's drawing machinery — shaders plus every fixed-function setting — into one <em>immutable pipeline object</em>. then you bind it once and issue draws. almost no state changes happen at draw time; you swap whole pipelines instead.

that upfront baking is the whole design decision. understand it and the rest of this page falls into place.

---

## why you bake everything upfront

think of a traditional kitchen that has every burner, oven, and tool set up exactly as the chef wants *before* service begins. during dinner service the kitchen just executes — no rearranging equipment mid-order.

OpenGL worked the opposite way: a mutable global state machine where the driver couldn't know what settings you'd change next. every draw call forced the driver to re-validate state, speculatively compile shaders, and guess at pipeline combinations. predictable performance was nearly impossible.

Vulkan flips this. you pay the cost — validation, shader compilation, compatibility checks — exactly once at pipeline creation. then:

- draw calls are cheap and predictable (no hidden recompilation)
- the GPU driver knows the full pipeline configuration in advance and can optimize for it
- multi-threaded recording is safe because there's no shared mutable state to race on

the tradeoff is real though: different material, different blend mode, different topology — each is a different `VkPipeline`. you accumulate permutations. two escape hatches exist for when that becomes painful: [dynamic state](#dynamic-state) and the pipeline cache.

---

## the coarse mental model — one object per assembly-line configuration

the [full rasterization journey](./from-vertices-to-pixels.md) is an assembly line: vertices in, pixels out, with many fixed stations in between. the `VkPipeline` object is the blueprint for that entire line — every station's settings locked in together.

you don't configure stations individually at draw time. you describe the whole line once, hand it to Vulkan, and receive back a single handle. binding that handle is binding all of it.

```
VkPipeline myPipeline;   // one handle — the whole configured assembly line
vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, myPipeline);
vkCmdDraw(cmd, vertexCount, 1, 0, 0);  // draw — all state already locked in
```

that's it at the outer skin. now let's peel back to the moving parts.

---

## walking the create-info: one knob per station

`VkGraphicsPipelineCreateInfo` is a struct that bundles pointers to sub-structs, one per assembly-line station. you fill them all, then call `vkCreateGraphicsPipelines`. here's the full shape before we look at each piece:

```cpp
VkGraphicsPipelineCreateInfo pipelineInfo{};
pipelineInfo.sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
pipelineInfo.stageCount          = 2;
pipelineInfo.pStages             = shaderStages;       // vertex + fragment
pipelineInfo.pVertexInputState   = &vertexInput;       // how to read your VBO
pipelineInfo.pInputAssemblyState = &inputAssembly;     // topology
pipelineInfo.pViewportState      = &viewportState;     // viewport + scissor
pipelineInfo.pRasterizationState = &rasterizer;        // cull, poly mode, winding
pipelineInfo.pMultisampleState   = &multisampling;     // MSAA
pipelineInfo.pDepthStencilState  = &depthStencil;      // depth test/write
pipelineInfo.pColorBlendState    = &colorBlending;     // blending per attachment
pipelineInfo.pDynamicState       = &dynamicState;      // escape hatch — see below
pipelineInfo.layout              = pipelineLayout;     // descriptor sets + push constants
pipelineInfo.renderPass          = renderPass;         // must be compatible
pipelineInfo.subpass             = 0;
```

walk these in order.

### shader stages — the programmable stations

you attach compiled SPIR-V modules for the vertex and fragment stages. each `VkPipelineShaderStageCreateInfo` names one stage and its entry point.

```cpp
VkPipelineShaderStageCreateInfo vertStage{};
vertStage.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
vertStage.stage  = VK_SHADER_STAGE_VERTEX_BIT;
vertStage.module = vertShaderModule;   // your compiled VkShaderModule
vertStage.pName  = "main";

VkPipelineShaderStageCreateInfo fragStage{};
fragStage.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
fragStage.stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
fragStage.module = fragShaderModule;
fragStage.pName  = "main";
```

`VkShaderModule` is just a thin wrapper around the SPIR-V bytecode — it's not compiled to GPU machine code until it's linked into a pipeline here.

### vertex input — how to read your vertex buffer

this station tells Vulkan the shape of the raw bytes in your vertex buffer. two concepts work together:

- a <em>vertex binding</em> describes one buffer: its index slot and how many bytes to advance per vertex (or per instance).
- a <em>vertex attribute</em> describes one field within that buffer: which binding it comes from, which `location` it feeds in the shader, its format (e.g. `VK_FORMAT_R32G32B32_SFLOAT` for a `vec3`), and its byte offset within the vertex struct.

```cpp
VkVertexInputBindingDescription binding{};
binding.binding   = 0;                          // slot 0
binding.stride    = sizeof(Vertex);             // bytes per vertex
binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

VkVertexInputAttributeDescription posAttr{};
posAttr.location = 0;                           // matches layout(location=0) in the shader
posAttr.binding  = 0;
posAttr.format   = VK_FORMAT_R32G32B32_SFLOAT; // vec3
posAttr.offset   = offsetof(Vertex, pos);

VkVertexInputAttributeDescription colorAttr{};
colorAttr.location = 1;                         // matches layout(location=1)
colorAttr.binding  = 0;
colorAttr.format   = VK_FORMAT_R32G32B32_SFLOAT;
colorAttr.offset   = offsetof(Vertex, color);
```

the vertex shader receives these as `layout(location=N) in` variables. the pipeline glues C++ side to GLSL side by matching `location` numbers:

```glsl
// vertex shader
layout(location = 0) in vec3 inPosition;  // location 0 → posAttr
layout(location = 1) in vec3 inColor;     // location 1 → colorAttr

layout(location = 0) out vec3 fragColor;

void main() {
    gl_Position = vec4(inPosition, 1.0);
    fragColor   = inColor;
}
```

this is where beginners frequently stall: if a `location` in C++ doesn't match one in GLSL, data lands in the wrong field — often silently. keep the numbers in sync.

### input assembly — how to interpret the vertices

`VkPipelineInputAssemblyStateCreateInfo` sets the primitive topology: how the GPU groups your indexed vertices into geometry.

```cpp
VkPipelineInputAssemblyStateCreateInfo inputAssembly{};
inputAssembly.sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST; // every 3 verts = 1 triangle
inputAssembly.primitiveRestartEnable = VK_FALSE;
```

common choices:
- `VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST` — standard, every 3 verts forms one triangle
- `VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP` — vertices are shared between adjacent triangles
- `VK_PRIMITIVE_TOPOLOGY_LINE_LIST` — for debug overlays or wireframes
- `VK_PRIMITIVE_TOPOLOGY_POINT_LIST` — for particle systems

### viewport and scissor

viewport maps NDC space to the framebuffer rectangle. scissor clips rendering to a pixel rectangle.

```cpp
VkViewport viewport{};
viewport.x        = 0.0f; viewport.y      = 0.0f;
viewport.width    = (float)swapchainExtent.width;
viewport.height   = (float)swapchainExtent.height;
viewport.minDepth = 0.0f; viewport.maxDepth = 1.0f;

VkRect2D scissor{};
scissor.offset = {0, 0};
scissor.extent = swapchainExtent;
```

if you declare viewport and scissor as dynamic state, you skip this here and set them per-command-buffer instead.

### rasterization

controls how triangles are filled and which faces are visible.

```cpp
VkPipelineRasterizationStateCreateInfo rasterizer{};
rasterizer.sType            = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
rasterizer.depthClampEnable = VK_FALSE;
rasterizer.polygonMode      = VK_POLYGON_MODE_FILL;   // FILL, LINE, or POINT
rasterizer.cullMode         = VK_CULL_MODE_BACK_BIT;  // discard back faces
rasterizer.frontFace        = VK_FRONT_FACE_COUNTER_CLOCKWISE;
rasterizer.lineWidth        = 1.0f;
```

- `polygonMode` — `FILL` for solid geometry; `LINE` or `POINT` for debug views (requires a GPU feature)
- `cullMode` — culling back faces is the default performance win for closed meshes
- `frontFace` — determines which winding order (CW or CCW) is the "front" face

### multisample

controls MSAA. to disable it and run 1 sample per pixel:

```cpp
VkPipelineMultisampleStateCreateInfo multisampling{};
multisampling.sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
multisampling.sampleShadingEnable  = VK_FALSE;
```

### depth and stencil

controls depth testing (closer fragments win) and the stencil buffer.

```cpp
VkPipelineDepthStencilStateCreateInfo depthStencil{};
depthStencil.sType            = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
depthStencil.depthTestEnable  = VK_TRUE;
depthStencil.depthWriteEnable = VK_TRUE;
depthStencil.depthCompareOp   = VK_COMPARE_OP_LESS;  // closer = smaller depth value
```

### color blend

controls how the fragment shader output blends with what's already in the attachment. one `VkPipelineColorBlendAttachmentState` per color attachment.

```cpp
VkPipelineColorBlendAttachmentState colorBlendAttachment{};
colorBlendAttachment.colorWriteMask =
    VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
    VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
colorBlendAttachment.blendEnable = VK_FALSE;  // no blending — fragment overwrites
```

for standard alpha blending, set `blendEnable = VK_TRUE` and configure the `src`/`dst` blend factors.

### pipeline layout — the descriptor interface

`VkPipelineLayout` is NOT part of `VkGraphicsPipelineCreateInfo` directly — you create it separately and reference it here. it declares:

- which <em>descriptor set layouts</em> the pipeline expects — this is how it knows what resources (UBOs, textures, samplers) are available in each slot. see [descriptors](../foundation/descriptors.md) for the full picture.
- push constant ranges — small fast values injected directly into the command stream without a descriptor set.

```cpp
VkPipelineLayoutCreateInfo layoutInfo{};
layoutInfo.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
layoutInfo.setLayoutCount         = 1;
layoutInfo.pSetLayouts            = &descriptorSetLayout;
layoutInfo.pushConstantRangeCount = 0;

vkCreatePipelineLayout(device, &layoutInfo, nullptr, &pipelineLayout);
```

### render pass compatibility

the pipeline must declare which [render pass (and subpass)](./render-passes-and-framebuffers.md) it will be used with. Vulkan uses this to verify that the pipeline's output attachments match the render pass's attachment descriptions. if you use dynamic rendering (VK_KHR_dynamic_rendering) instead, you fill in `VkPipelineRenderingCreateInfo` and omit `renderPass`.

---

## dynamic state — the escape hatch

not everything needs to be baked. `VkPipelineDynamicStateCreateInfo` names the states you want to set at command-recording time instead.

```cpp
std::vector<VkDynamicState> dynamicStates = {
    VK_DYNAMIC_STATE_VIEWPORT,
    VK_DYNAMIC_STATE_SCISSOR
};

VkPipelineDynamicStateCreateInfo dynamicState{};
dynamicState.sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
dynamicState.dynamicStateCount = (uint32_t)dynamicStates.size();
dynamicState.pDynamicStates    = dynamicStates.data();
```

then at draw time:

```cpp
vkCmdSetViewport(cmd, 0, 1, &viewport);
vkCmdSetScissor(cmd,  0, 1, &scissor);
```

#### when to use dynamic state

- viewport and scissor are almost always dynamic — window resize is common, creating a whole new pipeline for it is wasteful
- line width, blend constants, depth bias — sometimes dynamic for debug or effect passes
- stencil reference — dynamic when different objects need different stencil values

everything NOT listed in `pDynamicStates` remains baked and immutable. dynamic state is the narrow escape hatch, not the default.

#### pipeline cache — one sentence

`VkPipelineCache` lets the driver serialize compiled pipeline data to disk and reuse it across runs, so pipeline creation on subsequent launches is dramatically faster.

---

## contrast: graphics pipeline vs. compute pipeline

the <em>compute pipeline</em> described in [compute pipelines and shaders](../compute/compute-pipelines-and-shaders.md) is the lightweight sibling. it has one stage, no vertex input, no rasterization, no render pass, no color blend — just a compute shader and a pipeline layout. if you don't need to rasterize triangles, the compute pipeline is the right tool.

| | graphics pipeline | compute pipeline |
|---|---|---|
| stages | vertex + fragment (+ optional geometry/tessellation) | compute only |
| vertex input | yes | no |
| rasterization | yes | no |
| render pass required | yes (or dynamic rendering) | no |
| typical use | drawing geometry to framebuffer | parallel data transforms on GPU |

---

## summary

- the <em>immutable pipeline object</em> bakes shaders + every fixed-function setting into one handle — pay validation cost once, draw cheaply many times
- `VkGraphicsPipelineCreateInfo` is a struct of sub-structs, one per assembly-line station — understanding the whole [vertex-to-pixel journey](./from-vertices-to-pixels.md) is the map
- vertex bindings describe buffer slots; vertex attributes describe fields — they connect to the vertex shader's `layout(location=N) in` variables by number
- dynamic state exempts specific states from baking; viewport and scissor are the most common candidates
- the pipeline's layout declares which [descriptors](../foundation/descriptors.md) it consumes; the render pass field declares which [render pass](./render-passes-and-framebuffers.md) it is compatible with
- for non-rasterization work, reach for the simpler [compute pipeline](../compute/compute-pipelines-and-shaders.md) instead
