<link rel="stylesheet" href="./css/globals.css">

# swapchain & presentation

Every piece of work in a Vulkan renderer — the pipelines, the render passes, the draw calls — exists for one purpose: putting a finished image on screen. The <em>swapchain</em> is the mechanism that does that last mile: it owns the images you render into and it controls how and when those images appear on the display, without tearing.

If you can hold one idea before reading further, hold this: the swapchain is not just a framebuffer. It is a managed handshake between your renderer and the OS window system, with presentation timing baked in.

---

## the mental model — a carousel of canvases

Think of a small carousel shared between two people: you (the painter) and the display (the gallery).

- You borrow a blank canvas from the carousel.
- You paint on it.
- You hand it back to the gallery to be shown.
- While the gallery is displaying that canvas, you borrow the next blank one and start painting again.

You never paint on a canvas that is currently on display. You never have to wait for the gallery to finish before you start your next painting — because there are spare canvases in rotation.

That is double buffering (two canvases) or triple buffering (three canvases). The carousel is the swapchain.

Once you have that picture, retire it — the real mechanism has specific rules about when exactly you can touch each canvas, which is where semaphores come in. But the carousel is a true model of the structure.

---

## the moving parts

### VkSurfaceKHR — the window, from Vulkan's perspective

Before a swapchain can exist, Vulkan needs to know *where* to present. A <em>surface</em> (`VkSurfaceKHR`) is that bridge: it is a platform-abstracted handle to an OS window, created through a WSI (Window System Integration) extension.

- On Windows: `vkCreateWin32SurfaceKHR`
- On Linux/X11: `vkCreateXlibSurfaceKHR` or `vkCreateXcbSurfaceKHR`
- On macOS: `vkCreateMetalSurfaceEXT`
- In practice, libraries like GLFW call `glfwCreateWindowSurface` and handle the platform switch for you.

The surface is what you query to find out which formats, present modes, and image counts the platform supports — everything downstream depends on it.

The physical device and queue families that can present to this surface come from [../foundation/instances-and-devices.md](../foundation/instances-and-devices.md), where the device is created.

### VkSwapchainKHR — the managed set of presentable images

The <em>swapchain</em> owns a fixed set of images (your canvases). You do not allocate these images yourself — the swapchain allocates them internally based on your configuration. You only ever get `VkImage` handles to them via `vkGetSwapchainImagesKHR`.

Key things the swapchain configuration controls:

- **image count** — how many canvases on the carousel (at least 2; the driver may give you more than you ask for)
- **surface format** — which color encoding to use
- **present mode** — how and when images flip to the display
- **extent** — the resolution of each image in pixels

### surface format — color space and channel layout

A <em>surface format</em> (`VkSurfaceFormatKHR`) bundles two choices:

- `format` — the pixel layout, e.g. `VK_FORMAT_B8G8R8A8_SRGB` (8 bits per channel, sRGB color space)
- `colorSpace` — how those values map to display output, e.g. `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`

Query the available formats with `vkGetPhysicalDeviceSurfaceFormatsKHR` and pick from the list. A safe default: prefer `VK_FORMAT_B8G8R8A8_SRGB` + `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR` — it is widely supported and gives correct sRGB gamma handling.

The images the swapchain owns must be transitioned to the right layout before presentation — specifically `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR`. The rules for that are covered in [./image-layouts-and-transitions.md](./image-layouts-and-transitions.md).

### present mode — the most important tradeoff

<em>Present mode</em> controls *when* a finished image actually flips to the screen. This is the biggest quality-vs-latency knob on the swapchain.

| Mode | `VkPresentModeKHR` value | behavior |
|------|--------------------------|----------|
| FIFO | `VK_PRESENT_MODE_FIFO_KHR` | Frames queue up; swap only happens on a display vertical blank. Guaranteed available on every device. No tearing, but latency is at least one frame. |
| Mailbox | `VK_PRESENT_MODE_MAILBOX_KHR` | A single "waiting" slot — a newer frame replaces the queued one before it is shown. No tearing, lower latency than FIFO, costs more GPU power (driver keeps rendering). |
| Immediate | `VK_PRESENT_MODE_IMMEDIATE_KHR` | Frame goes to the display the moment it is done — no queue, no vsync wait. Lowest latency, but tearing is likely. |

**When to use which:**

- Use `FIFO` by default, and whenever you must avoid tearing or excess power use (laptops, battery-constrained devices, capped-framerate games).
- Use `MAILBOX` when you want low latency triple buffering on desktop — recent GPU frames instead of queued ones — and the device supports it.
- Use `IMMEDIATE` only for tools, benchmarks, or contexts where tearing is acceptable and you need the absolute lowest latency. Not guaranteed to be available.

Check availability with `vkGetPhysicalDeviceSurfacePresentModesKHR` before requesting a mode — fall back to `FIFO` if your preferred mode is absent.

### extent — the resolution

The <em>extent</em> (`VkExtent2D`) is the pixel dimensions of each swapchain image. Query the surface capabilities with `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` and clamp your window size to `minImageExtent` / `maxImageExtent`. On high-DPI displays, the extent in pixels differs from the window size in screen coordinates — use the framebuffer size, not the logical window size.

---

## creating the swapchain

The concept first: you query what the surface supports, choose your configuration, then hand it to `vkCreateSwapchainKHR`. All the moving parts above become fields in `VkSwapchainCreateInfoKHR`.

```cpp
VkSwapchainCreateInfoKHR createInfo{};
createInfo.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
createInfo.surface          = surface;
createInfo.minImageCount    = 2;                              // request double buffering
createInfo.imageFormat      = VK_FORMAT_B8G8R8A8_SRGB;
createInfo.imageColorSpace  = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
createInfo.imageExtent      = chosenExtent;                   // clamped to surface caps
createInfo.imageArrayLayers = 1;                              // 1 unless stereoscopic
createInfo.imageUsage       = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
createInfo.preTransform     = capabilities.currentTransform;  // usually IDENTITY
createInfo.compositeAlpha   = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
createInfo.presentMode      = VK_PRESENT_MODE_FIFO_KHR;
createInfo.clipped          = VK_TRUE;

vkCreateSwapchainKHR(device, &createInfo, nullptr, &swapchain);
```

After creation, retrieve the image handles the swapchain allocated:

```cpp
uint32_t imageCount;
vkGetSwapchainImagesKHR(device, swapchain, &imageCount, nullptr);
std::vector<VkImage> swapchainImages(imageCount);
vkGetSwapchainImagesKHR(device, swapchain, &imageCount, swapchainImages.data());
```

These `VkImage` handles are what you attach to framebuffers and render into each frame.

---

## the per-frame handshake — acquire, render, present

The carousel analogy holds here: you borrow a canvas, paint it, and hand it back. In Vulkan the exact sequence is:

1. **Acquire** — ask the swapchain for the index of the next image to render into.
2. **Render** — record and submit commands that write into that image.
3. **Present** — tell the swapchain to display the image once rendering is done.

### vkAcquireNextImageKHR — borrow an image

```cpp
uint32_t imageIndex;
vkAcquireNextImageKHR(
    device,
    swapchain,
    UINT64_MAX,           // timeout — UINT64_MAX means wait forever
    imageAvailableSemaphore,
    VK_NULL_HANDLE,       // or a fence, but semaphore is typical
    &imageIndex
);
```

This gives you an `imageIndex` — which canvas to paint. But here is the critical point: <em>acquiring returns the index immediately; the image is not necessarily ready yet</em>. The GPU may still be reading from it (displaying it). The `imageAvailableSemaphore` is what signals *when* the image is actually safe to write into. Your render commands must wait on that semaphore before they touch the image — not on `vkAcquireNextImageKHR` returning.

### vkQueuePresentKHR — hand it back

```cpp
VkPresentInfoKHR presentInfo{};
presentInfo.sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
presentInfo.waitSemaphoreCount = 1;
presentInfo.pWaitSemaphores    = &renderFinishedSemaphore; // wait until rendering is done
presentInfo.swapchainCount     = 1;
presentInfo.pSwapchains        = &swapchain;
presentInfo.pImageIndices      = &imageIndex;

vkQueuePresentKHR(presentQueue, &presentInfo);
```

The `renderFinishedSemaphore` is what your render submission signals when it is done writing to the image. `vkQueuePresentKHR` waits on that before scheduling the image for display.

The two semaphores — one going in, one coming out — are the core of the per-frame handshake. The full dance across multiple frames in flight (fences, in-flight tracking, semaphore pools) is covered in [./the-render-loop.md](./the-render-loop.md).

---

## swapchain recreation

The swapchain is tied to the window at a specific size. Two things break it:

- The window is **resized** — the extent is now wrong.
- `vkAcquireNextImageKHR` or `vkQueuePresentKHR` returns `VK_ERROR_OUT_OF_DATE_KHR` — the surface changed and the existing swapchain is no longer compatible.

When either happens, you must:

1. Wait for the device to be idle (`vkDeviceWaitIdle`).
2. Destroy the old swapchain and its dependent objects (image views, framebuffers).
3. Re-query surface capabilities and re-create everything with the new extent.

`VK_SUBOPTIMAL_KHR` is a softer signal — presentation still works, but the swapchain no longer matches the surface perfectly (e.g., a subtle resize). You can present this frame and recreate before the next, or recreate immediately.

Keep recreation logic in a dedicated function — it will be called more than once, and the creation and teardown paths must be symmetric.

---

## quick reference

| object | role |
|--------|------|
| `VkSurfaceKHR` | bridge to the OS window; created via a platform WSI extension |
| `VkSwapchainKHR` | manages the set of presentable images and their presentation timing |
| surface format | pixel layout + color space of the swapchain images |
| present mode | when finished frames flip to the display (FIFO / MAILBOX / IMMEDIATE) |
| `vkAcquireNextImageKHR` | returns an image index + signals a semaphore when that image is ready to write |
| `vkQueuePresentKHR` | schedules the image for display after a semaphore confirms rendering is done |
