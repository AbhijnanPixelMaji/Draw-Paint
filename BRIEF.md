# Drawsy — Product Brief (condensed)

**Codename:** Drawsy · **Xcode target name:** `Sketch&Draw` · **Bundle id:** `com.pixel.header.Sketch-Draw`

A production-quality, realistic drawing app for iPhone + iPad. Functional benchmark: **Tayasui Sketches**
(minimal zen UI, ultra-realistic media, Apple Pencil, layers, skeuomorphic tool rack). **Our UI/assets are
original** — we match functionality and feel, never their artwork, icons, or branding.

## Tech constraints (non-negotiable)
- Swift 6, strict concurrency. SwiftUI app shell. Deployment target **iOS 17+**.
- **Custom Metal** rendering engine for the canvas. **No PencilKit** for the paint engine (gesture ideas only).
- Canvas = `MTLTexture` layers composited in a single Metal pass. 60/120 Hz ProMotion.
- Apple Pencil: pressure (force), altitude (tilt), azimuth, coalesced + predicted touches, double-tap → eraser,
  hover preview on M2 iPads (graceful fallback).
- Persistence: SwiftData for gallery metadata; artwork stored as an on-disk document bundle
  (`artwork.drawsy/` → `manifest.json`, `layers/*.png`, `journal.bin`, `thumb.png`). No backend.
- Universal layout (iPhone compact/collapsible, iPad persistent rack). **No third-party dependencies.**

## Core features
1. Skeuomorphic **tool rack** (pencil, soft pencil, fineliner, felt-tip, brush pen, oil pastel, acrylic flat,
   round watercolor, airbrush, fill, eraser, cutter/lasso, ruler). Tap selects; tap-selected opens variants.
2. **Brush variants panel** with live engine-rendered stroke previews + custom brush editor
   (stamp shape, spacing, scatter, pressure→size/opacity curves, wetness, grain). Persist custom brushes.
3. **Paint engine** (the heart): pencil/graphite (grain + tilt), ink (velocity thinning + stabilizer),
   marker (multiply buildup), acrylic (bristle streaks + smear), watercolor (wet-on-wet diffusion, edge
   darkening, blooms, dry toggle), airbrush (soft buildup), eraser (per-layer, pressure), smudge, paper grain.
4. **Top toolbar** (icon-only): undo/redo (tile-based, memory-bounded), zoom-to-fit, gallery, stylus/stabilizer,
   wet/blend toggle, overflow (import image, export, canvas settings), layers.
5. **Layers**: reorder, add/delete/duplicate, visibility, opacity, blend modes (normal/multiply/screen/overlay),
   merge down, live thumbnails, selectable paper background.
6. **Color system**: edge color dot → wheel/sliders/eyedropper/palette/recent. Brush-size dot on opposite edge.
7. **Fill/pattern tool**: flood fill w/ tolerance + gap-closing; pattern fill; bottom-edge confirm UI
   (swatch, shuffle hue, checkmark).
8. **Replay (timelapse)**: compact stroke journal → play/pause/scrub/speed; export MP4 (AVAssetWriter) +
   PNG / transparent PNG / layered document.
9. **Gallery**: grid, folders, rename/duplicate/delete, local storage, share export.
10. **Gestures/feel**: two-finger pan/zoom/rotate, two-finger tap = undo, three-finger tap = redo, haptics,
    60fps+ with no visible latency (predicted touches dropped on the real sample).

## Phases (each must compile + run before the next)
1. Scaffold; Metal canvas w/ single hard-round pressure brush; pan/zoom; undo.
2. Brush engine generalization (stamps, spacing, curves); pencil + ink + marker; stabilizer.
3. Layers + blend modes + tile undo + document save/load + gallery.
4. Watercolor & acrylic wet engine; smudge; airbrush.
5. Tool rack UI; variants panel; custom brush editor; color system; fill; ruler; cutter.
6. Stroke journal; replay; MP4 export; polish; haptics; iPhone layout; performance pass.

## Definition of done (Phase 6)
Cold launch → drawing < 1.5s · Pencil latency ≈ Apple Notes · Watercolor overlap shows blooms + edge darkening ·
Artwork survives kill/relaunch (layers + journal + replay) · Swift 6 strict concurrency, zero warnings.
