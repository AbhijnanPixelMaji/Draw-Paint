# CLAUDE.md — working guide for the Drawsy (`Sketch&Draw`) codebase

## Build & run (IMPORTANT: full Xcode is not `xcode-select`ed)
`xcode-select -p` points at CommandLineTools, so `xcodebuild` is not on PATH. Always prefix with
`DEVELOPER_DIR` (no sudo needed):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Build for simulator (no code signing needed):
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "Sketch&Draw.xcodeproj" -scheme "Sketch&Draw" \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build | tail -40

# Boot + install + launch in simulator:
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcrun simctl install booted "<path to .app>"
xcrun simctl launch booted com.pixel.header.Sketch-Draw
xcrun simctl io booted screenshot /tmp/drawsy.png   # verify visually
```

Prefer `iPad Pro 11-inch (M4)` for canvas/rack work. Metal renders in the Simulator on Apple Silicon,
but **Apple Pencil pressure/tilt cannot be tested in the Simulator** — verify those manually on device
(note it in the PROGRESS.md manual checklist).

## Project layout
- Uses **Xcode 26 file-system-synchronized groups** → any file placed under `Sketch&Draw/` is auto-added to
  the target. No pbxproj edits needed to add `.swift`/`.metal` files. (Edits to build *settings* still need pbxproj.)
- Source tree mirrors the architecture in BRIEF.md:
  `App/ Gallery/ Canvas/{Engine,Brushes,Watercolor,Input,Journal} Tools/ Layers/ Color/ Shared/`
- Docs (`BRIEF.md`, `CLAUDE.md`, `PROGRESS.md`) live at the **repo/workdir root**, *outside* `Sketch&Draw/`,
  so they are never bundled into the app.

## Conventions
- Swift 6 (`SWIFT_VERSION = 6.0`), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` → types are `@MainActor`
  by default. Opt engine/GPU worker types out explicitly (`nonisolated`, actors) with a justification.
- **No `@unchecked Sendable`** without a written comment justifying the invariant that makes it safe.
- Metal: textures are `.rgba8Unorm`, **premultiplied alpha**, `.shared` storage. Blending is premultiplied
  source-over. Canvas space is y-down, pixel origin top-left. Keep the stamp-pass and composite-pass matrices
  sign-consistent (see `Shared/Math.swift`).
- Colors passed to shaders are **straight (non-premultiplied)** rgba; the fragment premultiplies.
- No allocations in the stroke hot path once Phase 6 lands; until then keep per-sample work cheap.

## Never do
- Never use PencilKit for the paint engine.
- Never copy Tayasui assets, icons, names, or branding. All visuals are original (SF Symbols / SwiftUI shapes / vector).
- Never add a third-party dependency.
- Never touch sibling projects in the parent git repo (Amazon safari, Book Reading Tracker, MicroHabbitTracker, …).
  Only stage/commit files under this project when asked.

## Testing
Unit tests (added Phase 3): journal encode/decode round-trip, tile-undo correctness, flood fill, document
save/load. UI verified by build + a manual checklist appended to PROGRESS.md each session.
