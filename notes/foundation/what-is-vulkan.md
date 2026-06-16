<link rel="stylesheet" href="./css/globals.css">

# what is vulkan

You want pixels on a screen, or a massively parallel computation on the GPU — fast, predictable, and without mystery. Vulkan is the tool for that. Everything else on this page explains what that actually means.

---

## the goal: GPU work with no hidden cost

A GPU can do two large things:

- **render** — take geometry and material descriptions and produce a 2D image
- **compute** — run thousands of threads in parallel over arbitrary data

Both paths share the same fundamental contract: you describe exactly what you want done, the GPU executes it, and the result comes back. What separates Vulkan from older APIs is *who makes the decisions in the middle.*

---

## the restaurant analogy

Think about ordering at a restaurant versus cooking in a professional kitchen yourself.

**Ordering at a restaurant (OpenGL, older APIs)**

You say "I'd like the pasta." The kitchen decides the pan, the heat, the timing, and the plating. You get food back. Most of the time it's fine. But if you want to cook eight dishes to land simultaneously, optimize around a specific stove, or control every ingredient exactly — you can't. The kitchen (the driver) is making those calls behind the closed door.

**Cooking in a pro kitchen yourself (Vulkan)**

You manage every burner, every timer, every expediting decision. Nothing happens that you didn't schedule. More work up front — but you know exactly what the cost is, and you can parallelize across every cook in the kitchen.

Vulkan is the pro kitchen. The analogy's limit: once you're into the actual Vulkan objects it stops mapping neatly, so set it aside then.

---

## what the driver used to do — and now you do

This is the core tradeoff. The OpenGL driver was quietly doing a lot of work to make the API feel simple. Vulkan hands that work to you.

| what changed hands | why it matters |
|---|---|
| <em>memory allocation</em> | you decide which GPU heap each resource lives in, when it's created, when it's freed |
| <em>synchronization</em> | you declare which GPU operations must finish before others can start — the driver no longer guesses |
| <em>state validation</em> | no implicit checks at draw time; you describe all state up front, compiled into objects that are cheap to swap |
| <em>threading</em> | because there's no hidden global state, multiple CPU threads can record GPU work simultaneously |

This is not pain for its own sake. Each item the driver no longer hides is something you now control — which means you can reason about its cost, share it across threads, and guarantee it doesn't surprise you mid-frame.

The tradeoff in plain terms: Vulkan takes more code to set up than OpenGL. In exchange, you get predictable performance, explicit control over every bottleneck, and a threading model that scales with your CPU core count.

---

## when to reach for vulkan — and when not to

Vulkan is not always the right tool.

**reach for Vulkan when:**
- you need maximum GPU throughput with minimal driver overhead
- you need to push work from multiple CPU threads simultaneously
- you're building an engine, a game, a simulation, or a compute framework that will run on many different hardware configurations
- you need the same low-level control on Linux, Windows, Android, and (via MoltenVK) macOS

**reach for something else when:**
- you're writing a prototype or learning tool and don't need peak performance
- you're targeting only Apple hardware — Metal is a better fit there
- you're targeting the browser — WebGPU is the right abstraction
- your team is small and the project doesn't need multi-threaded rendering or explicit memory control

**the landscape in one line:**
- **OpenGL** — simpler, older, still works, driver does the heavy lifting, harder to multi-thread
- **Metal** — Apple-only, modern explicit API, less boilerplate than Vulkan
- **DirectX 12** — Windows/Xbox-only, similar philosophy to Vulkan
- **WebGPU** — browser-first, higher-level than Vulkan, portable across backends
- **Vulkan** — cross-platform, fully explicit, most control, most responsibility

---

## the cast you'll meet

These are the main objects in every Vulkan program. Think of this as a reading list, not a definition list — each one gets its own page.

- **instance** — your connection to the Vulkan runtime; the first thing you create
- **physical device** — a GPU on the machine (you pick which one)
- **logical device** — your handle to the GPU, configured for the capabilities you need
- **queue** — a channel for submitting GPU work; GPUs expose several, with different capabilities
- **command buffer** — a recording of GPU instructions, batched and submitted together
- **pipeline** — a compiled, fully-specified description of a GPU operation (render or compute)

You'll see these in the first lines of any Vulkan program. [Instances and devices](./instances-and-devices.md) is where the boot sequence begins — walking through exactly how these objects get created in order.

---

## two paths through these notes

The notes split into two tracks after the shared foundation:

- **compute first** — if you want the gentler on-ramp, start with [why compute](../compute/why-compute.md). Compute pipelines carry less setup than rendering and the parallel model is a cleaner first encounter with Vulkan's explicit style.
- **rendering** — if pixels on screen are the goal, [from vertices to pixels](../rendering/from-vertices-to-pixels.md) builds the full rasterization model from scratch.

Both tracks depend on the shared foundation pages — this page, instances and devices, commands and queues, buffers and memory, and descriptors. Work through those first, then pick a track.
