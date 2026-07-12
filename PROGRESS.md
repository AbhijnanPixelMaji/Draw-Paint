# PROGRESS.md — Drawsy

_Update at the end of every session: what's done, what's next, open bugs, and decisions taken._

## Phase status
- [x] **Phase 1** — Scaffold; Metal canvas, single hard-round pressure brush; pan/zoom; undo. _(builds + runs; verified)_
- [x] Phase 2 — Brush engine generalization; pencil + ink + marker; stabilizer. _(builds + runs; verified)_
- [x] Phase 3 — Layers + blend modes + tile undo + document save/load + gallery. _(builds + runs + tests pass)_
- [x] Phase 4 — Watercolor & acrylic wet engine; smudge; airbrush. _(builds + runs + tests pass)_
- [ ] Phase 5 — Tool rack UI; variants panel; custom brush editor; color; fill; ruler; cutter.
- [ ] Phase 6 — Journal; replay; MP4 export; polish; haptics; iPhone layout; performance.

## Session log

### Session 1 — Phase 1 kickoff (2026-07-11)
**Environment findings**
- Existing project was the default Xcode SwiftData template (`Item.swift`, `ContentView.swift`).
- Xcode 26.5 present at `/Applications/Xcode.app` but not `xcode-select`ed → use `DEVELOPER_DIR` (see CLAUDE.md).
- Project uses file-system-synchronized groups → dropping files under `Sketch&Draw/` auto-adds them.

**Done — Phase 1 complete**
- Wrote BRIEF.md, CLAUDE.md, PROGRESS.md.
- Removed the SwiftData template (`Item.swift`, `ContentView.swift`); set `SWIFT_VERSION=6.0`, deployment 17.0.
- Metal engine: `MetalContext` (device/queue/pipelines/sampler, premultiplied source-over), `Shaders.metal`
  (instanced stamp pass + layer composite pass), `PaintLayer` (rgba8Unorm `.shared`), `StampFactory`
  (smoothstep round mask), `CanvasEngine` (MTKViewDelegate composite + stamp pass + stroke interpolation),
  `TileUndoStack` (256² tile snapshots, 30-entry cap), `CanvasMTKView` (coalesced-touch input, pressure),
  `CanvasView` (two-finger pan + pinch-zoom), `RootView` (icon toolbar: undo/redo/zoom-to-fit).
- **Build:** `BUILD SUCCEEDED`, zero Swift warnings, clean under Swift 6 strict concurrency.
- **Runtime verification (iPhone 16 Pro sim):** cold-launches to warm paper canvas + toolbar (undo/redo
  correctly disabled when empty). With `DRAWSY_DEBUG_STROKE=1`, the env-gated `debugStroke()` paints a
  tapering diagonal (pressure→radius), smooth edges, and undo flips to enabled / redo stays disabled →
  confirms stamp pass, composite pass, interpolation, and tile-undo recording all work.
- Screenshots: `/tmp/drawsy-phase1b.png` (empty), `/tmp/drawsy-paint.png` (test stroke).

**Decisions**
- Predicted touches are read but **not painted** in Phase 1 (prediction rollback deferred to the Phase 6
  latency pass) to keep Phase 1 correct and simple. Coalesced touches ARE used for full-fidelity sampling.
- Added a `#if DEBUG`, env-gated `CanvasEngine.debugStroke()` so the paint pipeline is verifiable in the
  Simulator (no Pencil, no drag injection). Harmless in normal runs.
- Deployment target lowered 26.5 → 17.0 to honor "iOS 17+" spec.
- `SWIFT_VERSION` 5.0 → 6.0 for strict concurrency.
- Phase 1 renders on `@MainActor` via `MTKView.draw` (dedicated render thread deferred to Phase 6) to keep
  strict concurrency trivially clean.
- Fixed 2048×2048 canvas for Phase 1; document-driven sizing arrives in Phase 3.

**Next — Phase 2**
- Generalize the brush engine: arbitrary stamp textures, spacing, scatter, rotation-to-direction,
  pressure→size and pressure→opacity curves; separate per-stroke buffer so intra-stroke alpha builds up
  correctly (marker) vs. clamps (pencil).
- Presets: pencil/graphite (grain + tilt widening), fineliner ink (velocity thinning + Catmull-Rom
  smoothing + exposed stabilizer amount), marker/felt (multiply buildup).
- Wire a temporary brush/color picker so presets are switchable for manual testing.

**Open bugs / watch-items**
- Pan/zoom + drawing gesture arbitration only lightly tested (Simulator). Verify on device that a 2-finger
  gesture cleanly aborts an in-progress stroke (`cancelDrawing()` path).
- `encodeStampPass` allocates a new MTLBuffer per input batch — fine for now; move to a ring buffer in the
  Phase 6 performance pass (no-allocation stroke hot path).

### Session 1 (cont.) — Phase 2 (2026-07-11)
**Done — Phase 2 complete**
- Generalized `BrushDescriptor` (Codable): spacing, hardness, scatter, random rotation, flow,
  stroke opacity, compositing mode, size/opacity response curves, velocity thinning, stabilization,
  tilt widening/fading, grain params. Presets: `.pencil`, `.ink`, `.marker`.
- **Stroke scratch buffer**: stamps render into a per-stroke texture, merged into the layer at stroke
  end. Buildup mode (pencil/ink) = source-over scratch merged at 100%; flat mode (marker) = **max-blend**
  scratch merged at `strokeOpacity` → no self-darkening within a stroke, darkening across strokes.
  Undo now snapshots only at merge time (one `willModify` with the stroke bounds).
- `StrokeBuilder`: exponential stabilizer → Catmull-Rom tessellation → arc-length stamp spacing with
  carry-over. `StampFactory.makePaperGrain`: deterministic (splitmix64) tileable 3-octave value noise,
  sampled canvas-anchored (repeat sampler) in the stamp shader.
- Velocity tracking (smoothed px/s) → ink thinning; altitude → tilt widening/fading (device-only test).
- Temp `BrushControlsView` (preset picker, 4 colors, size + stabilizer sliders) — replaced in Phase 5.
- **Verified in sim** (`/tmp/drawsy-phase2b.png`): pencil tapers, ink sine is smooth, marker loop is
  flat within one stroke and darker where a second stroke crosses it. Build clean, zero warnings.

**Phase 2 decisions**
- Flat-marker "multiply buildup on overlap **within** a stroke" interpreted per Tayasui behavior: flat
  *within* a stroke, darkening *across* strokes (that is what the max-blend scratch gives us).
- Stamp mask rebuilt only when `hardness` changes (cached otherwise).

### Session 1 (cont.) — Phase 3 (2026-07-11)
**Done — Phase 3 complete**
- **Compositing rework**: layers blend bottom→top into an opaque ping-pong accumulator seeded with the
  paper color (`blend_fragment`: normal/multiply/screen/overlay over an opaque base); the final accumulator
  blits to the drawable with the view transform. Composite cached via `compositeDirty`.
- Layer ops: add/delete/duplicate/move/mergeDown (+visibility/opacity/blendMode), 16-layer cap, live
  CPU-downscaled thumbnails. `TileUndoStack` reworked: entries carry their `PaintLayer`.
- Documents: `ArtworkDocument` bundle (manifest.json + layers/*.png premultiplied RGBA + thumb.png),
  `DocumentStore` under Documents/Artworks. SwiftData `ArtworkRecord` + `GalleryView` grid
  (create/rename/duplicate/delete/context menu), `CanvasScreen` with autosave (dismiss + scenePhase).
- **Test target added** (hand-edited pbxproj, synchronized group `Sketch&DrawTests`): 5 Swift Testing
  tests — tile undo restore + capacity, document save/load round-trip, stroke spacing, response curve.
  **All pass** on the iPhone 16 Pro simulator.
- **Verified visually**: layers panel with live thumbs + multiply badge; kill/relaunch → gallery thumb OK;
  auto-open → document loads with layers/modes intact. Debug env hooks: `DRAWSY_DEBUG_AUTO=create|open`,
  `DRAWSY_DEBUG_SHOWLAYERS=1`.

**Phase 3 decisions**
- Structural layer ops **clear pixel undo history** (entries reference layers); merge-down composites
  source-over at layer opacity, ignoring blend mode (simplification, noted for revisit).
- Composite accumulator is opaque → blend formulas simplify to `mix(base, blend(base,s), sa)`.
- Layer thumbnails are CPU readback + downscale on structural change/stroke end (GPU path if it shows
  up in the Phase 6 Instruments pass).

### Session 1 (cont.) — Phase 4 (2026-07-11)
**Done — Phase 4 complete**
- `BrushMedium` routing (`standard` / `watercolor` / `smudge`) + `StampShape` (`round` / `bristle`);
  presets: `.watercolor`, `.acrylic`, `.airbrush`, `.smudge`. Stamp masks cached per shape+hardness.
- **Watercolor**: persistent `WetBuffer` — stamps accumulate (overlap darkens → blooms); 12Hz timer runs
  a separable-gaussian diffusion ping-pong whose radius decays with wetness; live composite through
  `wet_fragment` (alpha-gradient **edge darkening**); `dryWetPaint()` bakes into the layer as ONE undo
  entry. Auto-dry on: save, undo/redo, layer select + all structural layer ops. Dry button in controls.
- **Acrylic**: bristle stamp (column of jittered dots) + `directionalRotation` → streaks along stroke.
- **Airbrush**: hardness 0.03, flow 0.06, 50ms dwell timer keeps depositing while held.
- **Smudge**: blit-copies pixels under the previous stamp into a 256² pickup texture, restamps at the
  current position through the soft mask (strength 0.85), direct-to-layer with per-rect tile undo +
  per-stamp waitUntilCompleted (undo snapshot ordering; revisit in perf pass).
- **Bug found & fixed in verification**: smudge sampled the whole pickup texture (uninitialized
  memory → magenta streaks); uv now rescaled by the valid side/256 fraction via instance color.r.
- MSL gotcha: `constant` arrays can't be function-local → blur weights moved to file scope.
- **Verified** (`/tmp/drawsy-phase4b.png`): watercolor overlap/diffusion, acrylic streaks, airbrush
  falloff, smudge pull. All 5 unit tests still pass.

**Phase 4 decisions**
- Wet paint is not undoable while wet; drying creates the undo entry (undo right after wet strokes
  first bakes then reverts the bake). Documented in code.
- Watercolor "blow" toggle deferred to Phase 5 UI (engine hook `wet.diffuse()` exists).

### Session 2 — UI beautification pass (2026-07-12)
**Done**
- New `Shared/Theme.swift`: `DrawsyTheme` — warm "studio desk" palette (light desk gray, single coral
  accent) + a shared floating-card modifier (regular material, hairline stroke, soft shadow).
- Killed the dark workspace: MTKView clear color 0.16-gray → warm desk (0.90/0.885/0.86), kept in sync
  with `DrawsyTheme.desk`, which now backs `CanvasScreen` (chrome forced `.light` for cohesion).
- Toolbar → three floating capsule clusters (gallery · undo/redo · zoom-to-fit/layers); layers button
  shows an accent-tinted active state.
- `BrushControlsView` redesigned as a floating brush dock: icon tool cards (SF Symbol per family,
  coral gradient on selection), 10-swatch curated palette with animated selection ring, size slider
  with live color/size preview dot, stabilizer slider.
- `LayersPanel`: card treatment, accent-tinted selection/paper rings, height capped at 520pt so it
  floats instead of filling the screen.
- **Verified in sim (iPhone 17 Pro — the 16 Pro runtime is gone from this machine)**: debug-stroke
  canvas + layers panel screenshots; build clean.

**Done (cont.) — canvas fill + fullscreen**
- New documents are sized to the device screen aspect (long side 2048px, `CanvasModel.defaultCanvasSize`)
  instead of fixed 2048², so the paper fills the workspace vertically — no more desk gap above/below.
  Existing documents keep their manifest size. `TileUndoStack` already handles partial edge tiles.
- Fullscreen drawing mode: expand button in the trailing toolbar cluster hides all chrome + status bar +
  home indicator; a single translucent corner button restores the UI. Layers panel auto-hides too.
  Zoom-to-fit icon changed to `viewfinder` to free the expand arrows for fullscreen.
- Debug hook: `DRAWSY_DEBUG_FULLSCREEN=1` launches in fullscreen (Simulator verification).
- **Verified in sim**: new canvas fills screen height; fullscreen shows only paper + exit button.

**Done (cont.) — compact expandable toolbar**
- Toolbar collapsed into ONE small floating capsule holding just the drawing essentials —
  undo · redo · layers — plus an ellipsis toggle that springs it open in place to reveal
  gallery, zoom-to-fit, and fullscreen (accent-tinted chevron collapses it back).
- Entering fullscreen auto-collapses the toolbar. Debug hook: `DRAWSY_DEBUG_TOOLBAR=1`
  launches expanded (Simulator verification). Verified both states via screenshots.

**Done (cont.) — compact expandable brush dock**
- Bottom dock now mirrors the toolbar: collapsed by default into a small pill showing the three
  essentials — current tool (accent tile) · current color · live size dot — plus a chevron; tapping
  anywhere on it springs open the full dock (tool cards, palette, sliders) with a grabber-style
  chevron to collapse. Dry button surfaces in the pill when wet paint exists.
- Debug hook: `DRAWSY_DEBUG_DOCK=1` launches expanded. Verified both states via screenshots.

**Done (cont.) — compact layers popover (phone-first)**
- LayersPanel shrunk from a 300×520 sheet to a 248pt-wide popover that hugs its content: the list
  is sized to the actual layer count (46pt rows, scrolls past 5), rows tightened (32pt thumbs,
  smaller type), footer controls compressed, paper swatches 19pt.
- Anchored top-trailing under the toolbar's layers button with a scale+fade transition, so it reads
  as a popover from that button rather than a floating sheet. Verified via screenshot.

**Done (cont.) — tap-outside dismissal**
- Invisible scrim over the canvas whenever any popup is open (layers popover, expanded toolbar,
  expanded brush dock): the first outside touch dismisses them all instead of painting. Dock
  expansion state hoisted from BrushControlsView to CanvasScreen (`@Binding`) so one place owns it.
- Note: while a popup is open the scrim also blocks pan/zoom until that first dismissing tap —
  intentional (popover semantics), revisit if it feels wrong on device.

**Notes**
- The desk color lives in TWO places by design (Metal clear color + `DrawsyTheme.desk`); change both.
- SF Symbols per family: pencil / pencil.tip / highlighter / drop.fill / paintbrush.fill / aqi.medium /
  hand.draw.fill / scribble.variable / eraser.fill.

## Manual verification checklists
### Phase 1 (fill in on device)
- [ ] App cold-launches to a blank paper canvas.
- [ ] One-finger / Pencil drag paints a hard-round stroke.
- [ ] Harder press → thicker stroke (device only).
- [ ] Two-finger drag pans; pinch zooms; content stays crisp.
- [ ] Undo removes the last stroke; redo restores it.
