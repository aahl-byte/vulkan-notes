<link rel="stylesheet" href="./css/globals.css">

# vulkan-notes — house rules for this site

This is a `notes-architect` site: living study notes on **Vulkan** (the explicit GPU
API), built outcome-first. Read this before editing so changes stay consistent. It is
seeded from the notes-architect PHILOSOPHY — that document is the ultimate source of
truth.

The product is **UNDERSTANDING, not coverage.** A page can be perfectly accurate and
still fail if a beginner finishes it with no mental model. Accuracy is necessary, not
sufficient.

## the core principle — think RIGHT → LEFT

Reason from the OUTCOME (the right edge — "how big things get done") leftward into the
detail needed to get there. Never open a page with a primitive or with code. Outcome
first, analogy second, specifics last. If a section opens with a primitive, it's
backwards — fix it.

## structure like an onion

Each layer must be true on its own terms so a reader can stop at any depth:

1. **mental model** — the shape in plain language, with a beginner-owned analogy. No
   undefined jargon survives this layer.
2. **moving parts** — the components, what each is *for*, when to reach for it.
3. **specifics** — the detail that only lands once the outer layers exist.

## this site's shape

One shared **GLOBAL FOUNDATION** plus three C++ tracks, each internally onion-ordered
(foundation → building blocks → cross-cutting → synthesis):

- `foundation/` — shared core: what-is-vulkan, instances & devices, commands &
  queues, buffers & memory, descriptors. Both compute and rendering depend on this.
- `compute/` — the simplest path: the parallel model, compute pipelines, dispatch,
  barriers/async, a walkthrough.
- `rendering/` — pixels on screen: rasterization model, graphics pipeline, swapchain,
  render passes, textures, image layouts, hello-triangle, the render loop.
- `advanced/` — cross-cutting depth: sync deep-dive, memory management, bindless,
  multithreading/perf, debugging, a real-world frame.

Each track's first page is its own **mental-model** page — it frames the section
before its machinery makes sense, and links back to the shared foundation.

## house style

- Markdown, one topic per file. **First line of every content page is exactly:**
  `<link rel="stylesheet" href="./css/globals.css">`
- `<em>...</em>` is a **COLORED HIGHLIGHT** for the key phrase in a definition — not
  italics, not ordinary emphasis.
- Lowercase, casual headers. `#` page, `##` sections, `###` sub-topics, `####` finer.
- Bullets over prose: a one-line plain-language summary, then bullets.
- Default code language is **C++** (native Vulkan API); shaders in GLSL compiled to
  SPIR-V. Introduce the concept FIRST, code as the concrete example — never lead with
  code. Keep examples short and illustrative.
- Prefer contrast ("use X instead of Y because Z") and include "when to use" lists
  wherever options compete — the CHOICE is the lesson.

## linking

- **Note-to-note links are RELATIVE:** `./other.md`, `../foundation/descriptors.md`.
- **Nav files use ABSOLUTE paths:** `/section/page.md`. Nav files are `_sidebar.md`,
  `_navbar.md`, `_coverpage.md`.
- Cross-link liberally across tracks so ideas get re-encountered.

## before committing

Run `node $CLAUDE_PLUGIN_ROOT/scripts/verify.js notes` (or the path to verify.js). It
enforces: every page's first line is the stylesheet link; every relative cross-link
resolves; every page is in `_sidebar.md` with no orphans. Fix all findings first.
