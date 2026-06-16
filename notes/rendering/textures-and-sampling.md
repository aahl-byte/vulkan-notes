<link rel="stylesheet" href="./css/globals.css">

# textures & sampling

you want a fragment shader to paint a surface with an image — wood grain, brick, a UI sprite. to do that, the shader needs to sample the image at arbitrary UV coordinates and get back a smoothly filtered color. this page is about how that happens: uploading an image, describing it to the GPU, and wiring it to a shader that can read from it.

---

## the mental model

Vulkan splits "a texture" into three separate objects, and the shader reads through all three:

- the **pixel data** — `VkImage`. the raw grid of colors you uploaded.
- how to **interpret** that data — `VkImageView`. it states the format, which mip levels and array layers are visible, and whether it's a 2D texture, cube map, or array.
- how to **read** between the pixels — `VkSampler`. it sets how to blend between texels when the image is magnified (filtering) and what to do for coordinates outside the image (address mode).

The image holds the data; the view describes it; the sampler controls the read. The rest of this page fills in what each piece does and how to connect them.

---

## the moving parts

### VkImage — the pixel data

<em>VkImage</em> is the GPU-side storage for your pixel data. it is not a buffer; it is a typed, tiled, multi-level resource that the GPU can read efficiently. you allocate it, bind memory to it, and write pixels into it via a staging copy.

it lives alongside buffers in Vulkan's memory model — see [buffers & memory](../foundation/buffers-and-memory.md) for how allocation and binding works. the image itself has no opinion about format or mip levels from the shader's perspective; that is the view's job.

### VkImageView — how the shader sees the image

<em>VkImageView</em> is a window onto a `VkImage`. it answers the questions the shader will ask:
- what format are the texels? (`VK_FORMAT_R8G8B8A8_SRGB`, etc.)
- which mip levels are visible?
- which array layers?
- is this a 2D texture, cube map, or array?

you almost never pass a `VkImage` directly to a shader. you always pass the view. one image can have multiple views — for example, exposing each face of a cube map separately, or exposing only mip level 0.

### VkSampler — filtering and wrapping

<em>VkSampler</em> has no pixel data of its own; it is a set of rules for how the image is read. its key knobs:

**filtering — what happens between texels**
- `VK_FILTER_NEAREST` — snap to the nearest texel. blocky; correct for pixel art.
- `VK_FILTER_LINEAR` — interpolate between neighbors. smooth; correct for photo-real surfaces.

**mip filter — how to transition between mip levels**
- `VK_SAMPLER_MIPMAP_MODE_NEAREST` — snap to the closest level.
- `VK_SAMPLER_MIPMAP_MODE_LINEAR` — blend between two adjacent levels (trilinear filtering).

**address mode — what happens outside [0, 1] UV range**
- `VK_SAMPLER_ADDRESS_MODE_REPEAT` — tile the image. good for tiling textures (brick, fabric).
- `VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE` — stretch the edge pixel. good for UI sprites and decals.
- `VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT` — tile but flip each copy.

**anisotropy — quality at oblique angles**
- disabled by default; enable with `anisotropyEnable = VK_TRUE` and a `maxAnisotropy` level (2x–16x).
- costs a little bandwidth; almost always worth it for 3D surfaces.

### the combined image sampler — the shader binding

the shader does not reach into a `VkImage` directly. it reads through a descriptor that pairs an image view with a sampler. that binding is a `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` — wiring them up is covered in [descriptors](../foundation/descriptors.md).

in GLSL the shader declares:

```glsl
layout(set = 0, binding = 1) uniform sampler2D albedo;

void main() {
    vec4 color = texture(albedo, fragUV);
}
```

`sampler2D` is the combined type: it carries both the view and the sampler. `texture()` does the lookup, applying whatever filtering and address modes the sampler specifies.

---

## the upload path

before a shader can sample an image, the pixels have to reach GPU memory and the image has to be in the right layout for sampling. the steps:

1. **load pixels on the CPU** — decode your PNG/DDS/etc. into a flat byte array.
2. **create a staging buffer** — a host-visible buffer (see [buffers & memory](../foundation/buffers-and-memory.md)) large enough for all texels.
3. **copy pixels into the staging buffer** — plain `memcpy`.
4. **create the `VkImage`** — `VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT`.
5. **transition layout to `VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL`** — the image must be in a layout that accepts writes before you copy into it.
6. **`vkCmdCopyBufferToImage`** — record the copy command, specifying which mip/layer to target.
7. **transition layout to `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL`** — once copied, the image needs the layout a sampler reads from.
8. **create the `VkImageView` and `VkSampler`** — now the shader can be handed the descriptor.

steps 5 and 7 are image layout transitions. they are a pipeline barrier that tells Vulkan which stages finish writing before which stages start reading. the mechanics of that barrier — the access masks, stage flags, and why the layout must change — are explained in [image layouts & transitions](./image-layouts-and-transitions.md).

---

## mipmaps

<em>mipmaps</em> are pre-scaled copies of your image at half-resolution, quarter-resolution, and so on, stored together in the same `VkImage`. the GPU picks the right level based on how many texels of the image map to a screen pixel.

**why they exist**

without mipmaps, a distant surface samples many texels per screen pixel at once and produces aliasing (shimmering). with mipmaps, the GPU samples a level where approximately one texel maps to one pixel — much cleaner, and faster (fewer cache misses).

**when you need them**
- any texture that appears at varying distances or angles in 3D — yes, always.
- UI sprites rendered at a fixed pixel size on screen — usually not worth it.
- render targets — generally no (each frame is fresh).

**generating them**
- record a chain of `vkCmdBlitImage` calls, each blitting mip N → mip N+1. the image must support `VK_IMAGE_USAGE_TRANSFER_SRC_BIT` for this.
- or load them pre-baked from a DDS/KTX file — useful for non-color data (normal maps, PBR channels) where GPU-generated bilinear downscales are inaccurate.

---

## choosing filtering and address mode

the choice is the lesson. pick by use-case:

| use-case | filter | mip mode | address mode | anisotropy |
|---|---|---|---|---|
| pixel art / retro sprites | nearest | nearest | clamp to edge | off |
| UI sprites / icons | linear | nearest | clamp to edge | off |
| 3D world surface (brick, wood) | linear | linear (trilinear) | repeat | on (4x–16x) |
| skybox / cube map | linear | linear | clamp to edge | off |
| normal map / data texture | linear | linear | repeat | on |
| render-to-texture (no distant view) | linear | nearest | clamp to edge | off |

**nearest instead of linear** when you want hard pixel boundaries — filtering blurs them away.

**repeat instead of clamp** when the texture tiles — clamping would stretch the edge color across the surface.

**anisotropy on** whenever the surface is viewed at an angle and you have the GPU headroom. without it, linear+trilinear still blurs oblique surfaces.

---

## summary

- `VkImage` holds the pixels. `VkImageView` describes how to interpret them. `VkSampler` describes how to read between them.
- images need a layout transition before copying into them (`TRANSFER_DST`) and again before sampling (`SHADER_READ_ONLY`). see [image layouts & transitions](./image-layouts-and-transitions.md).
- the shader sees a `combined image sampler` descriptor — see [descriptors](../foundation/descriptors.md) for how to wire it up.
- mipmaps eliminate aliasing at distance; use them for any texture in 3D.
- filtering and address mode are a use-case choice, not a default to set and forget.
