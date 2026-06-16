<link rel="stylesheet" href="./css/globals.css">

# the explicit bargain

A shipping engine renders complex scenes at high frame rates across every CPU core
available, with predictable memory and no GPU stalls between frames. The advanced
track exists to get there. This page is not about a new API — it's about why all the
hard work you already did is about to pay off.

---

## you've already paid the tax

When you first learned Vulkan — in [what-is-vulkan.md](../foundation/what-is-vulkan.md)
and the tracks that followed — it asked you to own things most APIs hide: who allocates
GPU memory, what barrier signals when, how commands get recorded, what happens between
frames.

That felt like a tax. Every triangle earned with a hundred lines of setup.

Here's the bargain: <em>explicit control is worthless until you use it deliberately.</em>
The foundation/compute/rendering tracks made you take ownership. The advanced track is
where you spend it.

---

## the coarse model — what you're actually doing

Most of the performance you can unlock from Vulkan comes down to one principle:

<em>do less, in parallel.</em>

- **do less** — fewer barriers than you think you need, fewer allocations, fewer
  descriptor set updates, fewer pipeline state changes.
- **in parallel** — fill command buffers on every CPU core, let the GPU overlap
  independent work, stop the CPU from waiting on the GPU when it doesn't have to.

If you take nothing else from this track, take that. Measure what's actually slow
before adding complexity. The rest of these notes are how to execute on it.

---

## the four levers

Each lever is the payoff of something explicit you already took ownership of.

### precise synchronization — overlap instead of over-sync

You met barriers and semaphores in the foundation. The easy mistake is to add one
everywhere you feel uncertain, which serializes work that could have overlapped.

The real job is to use the *minimum* barrier needed to keep correctness, so independent
work can run at the same time. Done right, the GPU pipelines geometry, shading, and
post-processing without stalling.

[synchronization-deep-dive.md](./synchronization-deep-dive.md) goes deep on how to
reason about this and find where you're over-syncing.

### deliberate memory management — pool and sub-allocate

You own GPU memory allocation. But calling `vkAllocateMemory` for every buffer is
slow — the driver has a hard limit on simultaneous allocations, and each call is
expensive.

The payoff: allocate a few large blocks upfront, then hand out sub-ranges yourself (or
via a library like VMA). Frame-level data lives in one pool, mesh data in another,
staging in a third. Allocation becomes a pointer bump instead of a driver round-trip.

[memory-management.md](./memory-management.md) covers heaps, the staging pattern,
sub-allocation, and where VMA fits.

### bindless — escape descriptor set churn

Descriptor sets are how you hand resources to shaders. In a naïve renderer you update
them every draw call. At scale that becomes the bottleneck.

Bindless flips the model: load every texture into a big array once, index into it from
the shader. Descriptor updates drop toward zero. Draws become cheap.

[bindless-and-descriptor-indexing.md](./bindless-and-descriptor-indexing.md) builds the
model, the binding flags it needs, and when it's worth the cost.

### multithreaded recording — fill every core

Command buffer recording is CPU work. In a single-threaded renderer the main thread
records every draw while the other cores idle.

Vulkan command buffers are designed to be filled on any thread independently and then
submitted together. This is the explicit ownership of command recording paying out —
a properly structured renderer can scale recording linearly with CPU cores.

[multithreading-and-performance.md](./multithreading-and-performance.md) walks through
how to partition work so threads don't fight over state.

---

## the discipline that makes it safe

Four levers that move fast are also four levers that can corrupt in subtle ways.
Racing barriers produce visual corruption that disappears under capture tools.
Sub-allocators that misalign data cause device loss on some vendors but not others.

Two tools belong in every advanced workflow:

- **validation layers** — the debug runtime catches barrier misuse, layout
  transitions, and undefined behavior before they become production crashes.
- **profiling / GPU timestamps** — find the stall before fixing it. Most
  "performance problems" are not where they look like they are. Optimize what the
  profiler points at, not what feels slow.

---

## the guiding principle

Repeat this before touching a hot path:

> In Vulkan, performance is mostly about doing LESS and doing it IN PARALLEL.

The checklist before adding an optimization:

- What am I doing that I don't need to do?
- What am I serializing that could run concurrently?
- Have I measured this, or am I guessing?

Vulkan rewards the developer who reasons carefully about the pipeline, not the one who
adds the most synchronization.

---

## you're ready for this track when…

- You've drawn a triangle or rendered a full frame — you know the swapchain loop.
- You've dispatched a compute job — you know the pipeline model.
- You've hit the loop: the code works, but you can feel it isn't fast yet, or you
  know you can't get to the feature you want without understanding what's underneath.

If that's you, start with [synchronization-deep-dive.md](./synchronization-deep-dive.md)
— it's the lever everything else depends on — then follow the sidebar order through
memory, bindless, multithreading, and debugging. Each page builds on the one before.

The explicit bargain is real. Time to collect.
