<link rel="stylesheet" href="./css/globals.css">

# commands & queues

Getting work to actually run on the GPU is not a function call — it is a handoff. You write down a list of GPU instructions ahead of time, then hand that list to a submission point where the GPU picks it up and executes it asynchronously. Everything in Vulkan — compute dispatches, draw calls, memory transfers — reaches the GPU through this same mechanism. Understand this handoff and the rest of Vulkan's design starts to make sense.

---

## the mental model — record, submit, execute

The whole mechanism is three phases, and the key point is that they are separated in time:

- **Record** — on the CPU, you build a <em>command buffer</em>: a list of GPU instructions written down ahead of time. Nothing runs yet; you're just filling the list.
- **Submit** — you hand the finished list to a <em>queue</em> with `vkQueueSubmit`. The call returns immediately. Your CPU thread is now free to do other work.
- **Execute** — the GPU pulls the submitted commands and runs them asynchronously, on its own timeline.

Because recording and execution are separate, your CPU thread never blocks waiting for the GPU. You record, submit, and move on; the GPU runs the work later. Knowing *when* it finished is the job of synchronization (fences, semaphores) — its own topic, covered separately.

---

## the moving parts

### command pool

A <em>command pool</em> is the allocator that owns command buffers. You create the pool, then allocate buffers from it.

Two constraints shape how you use pools:

- A pool is **tied to a queue family** at creation time. Buffers allocated from it can only be submitted to a queue from that same family.
- A pool is **not thread-safe**. Each thread that records commands needs its own pool.

One pool per thread per queue family is the standard pattern.

```cpp
VkCommandPoolCreateInfo poolInfo{};
poolInfo.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
poolInfo.queueFamilyIndex = graphicsFamily;  // tied to this family
poolInfo.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

VkCommandPool commandPool;
vkCreateCommandPool(device, &poolInfo, nullptr, &commandPool);
```

### command buffer

A <em>command buffer</em> is the recorded list — a sequence of GPU instructions that will execute in order when the buffer is submitted. It doesn't run anything on allocation; it is just a container waiting to be filled.

Command buffers are allocated from a pool, not created independently:

```cpp
VkCommandBufferAllocateInfo allocInfo{};
allocInfo.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
allocInfo.commandPool        = commandPool;
allocInfo.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
allocInfo.commandBufferCount = 1;

VkCommandBuffer commandBuffer;
vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);
```

### the record lifecycle — begin → record → end

A command buffer passes through three states before it can be submitted.

**1. Begin** — open the buffer for recording.

```cpp
VkCommandBufferBeginInfo beginInfo{};
beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;  // hint: record once, submit once

vkBeginCommandBuffer(commandBuffer, &beginInfo);
```

**2. Record** — call `vkCmd*` functions to append GPU instructions. These calls return immediately; no GPU work happens yet. This is pure CPU work.

```cpp
// example: copy a buffer (a transfer command)
VkBufferCopy region{};
region.size = dataSize;
vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &region);
```

Every piece of GPU work you want — draw calls, compute dispatches, memory copies, pipeline barriers — goes in here as a `vkCmd*` call. The commands are held in the buffer; the GPU sees none of them yet.

**3. End** — close the buffer. It is now in the executable state.

```cpp
vkEndCommandBuffer(commandBuffer);
```

### queue

A <em>queue</em> is the GPU-side execution lane where submitted command buffers run. Queues come from the device you created — specifically from the queue families you selected during device setup. If you need a refresher on how families and devices relate, see [instances and devices](./instances-and-devices.md).

Different queue families support different operation types: graphics, compute, transfer, or some combination. You submit a command buffer to whichever queue matches the work inside it.

### vkQueueSubmit — handing the work over

`vkQueueSubmit` is the handoff. After this call returns, the GPU will execute the commands — but you don't know exactly when, and you don't block waiting for it.

```cpp
VkSubmitInfo submitInfo{};
submitInfo.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
submitInfo.commandBufferCount   = 1;
submitInfo.pCommandBuffers      = &commandBuffer;

vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);
// returns immediately — GPU runs the commands asynchronously
```

The last argument is an optional fence you can signal when this submission completes. Pass `VK_NULL_HANDLE` here and you have no way to know when the GPU finished — fine for fire-and-forget cases, not fine when you need the result.

---

## recording is CPU-side; submission is the async boundary

This distinction matters:

- **Recording** (`vkBeginCommandBuffer` → `vkCmd*` → `vkEndCommandBuffer`) is entirely CPU work. It is cheap, thread-safe per pool, and can be parallelized across cores.
- **Submission** (`vkQueueSubmit`) is the moment the GPU becomes involved. After submission your CPU thread is free; the GPU works in the background.

Because recording is CPU-side and pool-local, you can record multiple command buffers in parallel on separate threads — one pool per thread — then submit them together. The topic of parallel recording is covered in [multithreading and performance](../advanced/multithreading-and-performance.md).

### primary vs secondary command buffers

`VK_COMMAND_BUFFER_LEVEL_PRIMARY` — submitted directly to a queue. That is what all examples on this page use.

`VK_COMMAND_BUFFER_LEVEL_SECONDARY` — recorded into a primary buffer via `vkCmdExecuteCommands`. Useful for building reusable chunks in parallel threads and assembling them into a primary buffer at submission time. Secondary buffers are the main tool for multithreaded recording.

---

## the async gap

Once `vkQueueSubmit` returns, the GPU is working — but your CPU thread has no idea when it will finish. If you read the result buffer on the CPU a microsecond later, the GPU may not have written anything yet.

This is intentional. The async gap is what lets CPU and GPU overlap. It is also why Vulkan makes synchronization explicit: fences (CPU waits for GPU), semaphores (queue-to-queue ordering), and pipeline barriers (within a queue). None of that is covered here — it deserves its own treatment. Start with [synchronization deep dive](../advanced/synchronization-deep-dive.md) when you are ready.

---

## how many pools and buffers?

A common practical question. The short answer:

- **One pool per thread** that records commands. Pools are not thread-safe; sharing one causes data races.
- **One primary buffer per frame per thread** is a typical starting point for a render loop. You can reset and re-record it each frame.
- **More buffers** when you want to record frame N+1 while frame N is still on the GPU (double/triple buffering the command buffers matches the swapchain image count).
- **Secondary buffers** when you want multiple threads to each record a chunk, then assemble them. This is the multithreading pattern.

The buffers themselves are thin — allocating several hundred is fine. Pool memory is shared across all buffers in the pool, so you're not paying per-buffer overhead.

---

## what those commands actually operate on

A command buffer records *instructions*, but most instructions need something to act on: a buffer holding vertex data, an image to write into, a descriptor set naming a uniform buffer. Those resources live in GPU memory, allocated separately. See [buffers and memory](./buffers-and-memory.md) for how memory works and how buffers and images are backed by it.

---

## summary

- The GPU doesn't run your C++ — you record a command buffer (a list of GPU instructions) and submit it to a queue.
- Recording is CPU-side, cheap, and parallelizable — one pool per thread.
- Submission is the async boundary: `vkQueueSubmit` hands the work off and returns immediately.
- The GPU runs the commands later; synchronization (a separate topic) is how you know when it's done and how you order work safely.
