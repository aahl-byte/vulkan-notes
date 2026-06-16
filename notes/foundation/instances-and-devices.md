<link rel="stylesheet" href="./css/globals.css">

# instances & devices

Before you can draw a triangle, dispatch a compute shader, or allocate a byte of GPU memory, you need one thing: a <em>logical device</em> — your personal, configured handle to one GPU. Every other Vulkan object you will ever create hangs off that handle. This page walks the boot sequence from zero to that handle, and explains why each step in the chain exists.

For the broader question of why Vulkan works this way at all, start with [./what-is-vulkan.md](./what-is-vulkan.md). Once you have a device and want to put work on it, the follow-on is [./commands-and-queues.md](./commands-and-queues.md).

---

## the mental model — getting set up on a shared machine

Imagine you're an IT user who needs access to a workstation in a shared lab.

1. You **sign in to the building** — you announce to the system that you exist and what software environment you expect (instance).
2. You **look at the inventory board** — the lab has three machines posted: a gaming rig, a workstation, and a server node. You read their specs to pick the right one (physical device enumeration).
3. You **log in to your chosen machine** — you open a session configured exactly for your needs: which ports you'll use, which features you'll enable (logical device).
4. You **get assigned a desk** — once logged in, you're given the actual communication channels to send work through (queues).

That four-step story maps exactly onto Vulkan. Retire the analogy here — the rest of the page uses precise terms.

---

## the chain

### step 1 — VkInstance: announce yourself to Vulkan

`VkInstance` is the root object. It represents your application's connection to the Vulkan runtime.

What it is FOR:
- Loading the **validation layers** and **instance-level extensions** you opt into
- Giving the driver enough context about your application (name, version) to apply vendor workarounds if needed
- Serving as the parent from which everything else descends

There is one instance per application, created once at startup, destroyed last at shutdown.

```cpp
VkApplicationInfo appInfo{};
appInfo.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
appInfo.pApplicationName   = "my-app";
appInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
appInfo.apiVersion         = VK_API_VERSION_1_3;

VkInstanceCreateInfo createInfo{};
createInfo.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
createInfo.pApplicationInfo        = &appInfo;
createInfo.enabledLayerCount       = static_cast<uint32_t>(layers.size());
createInfo.ppEnabledLayerNames     = layers.data();
createInfo.enabledExtensionCount   = static_cast<uint32_t>(extensions.size());
createInfo.ppEnabledExtensionNames = extensions.data();

VkInstance instance;
vkCreateInstance(&createInfo, nullptr, &instance);
```

The `sType` field on every Vulkan struct is how the driver knows what you handed it — it is mandatory, never optional.

---

### step 2 — VkPhysicalDevice: read the inventory

`VkPhysicalDevice` is not something you create — it is a handle to a GPU that already exists in the system. You ask Vulkan to enumerate them.

What this step is FOR:
- Discovering every available GPU (including integrated graphics and software rasterizers)
- Querying each one's **properties** (name, type, driver version, API version)
- Querying each one's **features** (does it support geometry shaders? 64-bit floats? anisotropic filtering?)
- Querying each one's **limits** (max texture size, max descriptor sets, etc.)
- Querying its **queue families** — covered in the next section

```cpp
uint32_t deviceCount = 0;
vkEnumeratePhysicalDevices(instance, &deviceCount, nullptr);

std::vector<VkPhysicalDevice> physicalDevices(deviceCount);
vkEnumeratePhysicalDevices(instance, &deviceCount, physicalDevices.data());

// inspect each candidate
for (auto& pd : physicalDevices) {
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    // props.deviceType, props.deviceName, props.limits, ...
}
```

You pick one — the choice is yours. Common strategy: prefer `VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU`, fall back to integrated if none is found, and reject any device that lacks the queue families or features your application requires.

---

### step 3 — queue families: what work can this GPU accept?

Before you create the logical device, you need to know which **queue families** your chosen physical device exposes.

A <em>queue family</em> is a group of queues that all support the same category of work.

The four capability flags:
- `VK_QUEUE_GRAPHICS_BIT` — draw calls
- `VK_QUEUE_COMPUTE_BIT` — compute dispatches
- `VK_QUEUE_TRANSFER_BIT` — memory copy operations
- presentation support — queried separately via `vkGetPhysicalDeviceSurfaceSupportKHR`

A single family can carry multiple flags. A GPU typically exposes a primary "universal" family that does all three, plus one or two specialized families (a dedicated transfer family, a dedicated async-compute family). Choosing which families to use — and how many queues to take from each — is a design decision that trades throughput against simplicity.

You query families like this:

```cpp
uint32_t familyCount = 0;
vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &familyCount, nullptr);

std::vector<VkQueueFamilyProperties> families(familyCount);
vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &familyCount, families.data());

for (uint32_t i = 0; i < familyCount; i++) {
    if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
        graphicsFamilyIndex = i;
    }
}
```

Record the family index for each capability you need — you hand these indices to the logical device at creation time.

The actual work of submitting commands to those queues is the subject of [./commands-and-queues.md](./commands-and-queues.md).

---

### step 4 — VkDevice: open your session

`VkDevice` is the <em>logical device</em> — the configured, application-owned connection to one physical device.

What it is FOR:
- Requesting the exact **queues** you need (by family index and count)
- Enabling the **device-level features** and **extensions** you opt into
- Being the parent object from which you allocate memory, create pipelines, record commands, and so on

```cpp
float queuePriority = 1.0f;

VkDeviceQueueCreateInfo queueInfo{};
queueInfo.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
queueInfo.queueFamilyIndex = graphicsFamilyIndex;
queueInfo.queueCount       = 1;
queueInfo.pQueuePriorities = &queuePriority;

VkPhysicalDeviceFeatures features{};
features.samplerAnisotropy = VK_TRUE;   // only enable what you need

VkDeviceCreateInfo deviceInfo{};
deviceInfo.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
deviceInfo.queueCreateInfoCount    = 1;
deviceInfo.pQueueCreateInfos       = &queueInfo;
deviceInfo.pEnabledFeatures        = &features;
deviceInfo.enabledExtensionCount   = static_cast<uint32_t>(deviceExts.size());
deviceInfo.ppEnabledExtensionNames = deviceExts.data();

VkDevice device;
vkCreateDevice(physicalDevice, &deviceInfo, nullptr, &device);
```

You request queues at device creation — you cannot add or remove them later. Ask for only the families and counts you actually intend to use.

---

### step 5 — retrieve VkQueue handles

After device creation, retrieve the actual queue handles:

```cpp
VkQueue graphicsQueue;
vkGetDeviceQueue(device, graphicsFamilyIndex, 0, &graphicsQueue);
```

The `0` is the queue index within the family — if you requested `queueCount = 1`, there is only index 0. Hold these handles for the lifetime of the device; you do not create or destroy queues independently.

---

## extensions and validation layers

Vulkan ships with a minimal core. Everything else is opt-in.

**Validation layers** are the debugging safety net — enabled only in debug builds, they intercept every Vulkan call and report incorrect usage, bad parameters, and synchronization errors to a callback you register. The standard one is `VK_LAYER_KHRONOS_validation`. Never ship with it enabled; the overhead is significant. Extensions and layers deserve their own treatment — what matters here is that they must be declared at instance (or device) creation time.

**Extensions** fall into two scopes:
- *Instance-level* — declared in `VkInstanceCreateInfo`, e.g. `VK_KHR_surface` (required before you can present anything to a window)
- *Device-level* — declared in `VkDeviceCreateInfo`, e.g. `VK_KHR_swapchain` (required to create a swapchain for rendering)

Enable only the extensions you actually call. An extension you enable but never use is not free — some carry validation overhead, and it signals false intent to reviewers.

---

## what can go wrong

A few failure points beginners hit during this boot sequence:

#### no suitable GPU found
`vkEnumeratePhysicalDevices` returns a count of 0, or none of the returned devices meet your requirements. Check:
- Is the Vulkan runtime installed? (driver + ICD loader)
- Are you running in a VM or container without GPU passthrough?
- Did you fail a feature check (`samplerAnisotropy`, 64-bit floats, etc.) that the hardware doesn't support?

#### the queue family you need doesn't exist
Not every GPU exposes a dedicated transfer or compute family. The universal family always supports graphics + compute + transfer, but presentation support is surface-dependent — a family that works on one platform may not expose present support on another. Always verify family capabilities before recording the index.

#### a requested extension is unavailable
Call `vkEnumerateInstanceExtensionProperties` / `vkEnumerateDeviceExtensionProperties` first to get the list of what is actually available, then intersect with your requirements. A mismatch here causes `VK_ERROR_EXTENSION_NOT_PRESENT` at creation time.

---

## summary

The boot sequence in order:

1. `vkCreateInstance` — register your application, load layers and instance extensions
2. `vkEnumeratePhysicalDevices` — find all GPUs, read their properties, features, and limits
3. `vkGetPhysicalDeviceQueueFamilyProperties` — check what families the chosen GPU exposes and record the indices you need
4. `vkCreateDevice` — open your configured session, requesting the queues and device extensions you need
5. `vkGetDeviceQueue` — retrieve handles for those queues

The logical device is the root of nearly everything that follows. Hold it for the life of your application and destroy it last (before the instance).
