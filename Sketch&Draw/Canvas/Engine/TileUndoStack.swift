import Metal
import CoreGraphics

/// Tile-based pixel undo across the layer stack. The canvas is a grid of `tileSize`×`tileSize` tiles.
/// During a stroke we snapshot the *before* pixels of each touched tile of the target layer; at stroke
/// end we snapshot the *after* pixels and push one entry. Undo restores "before", redo restores "after".
///
/// Entries hold a strong reference to their `PaintLayer`; **structural layer operations
/// (add/delete/reorder/merge) must call `clear()`** — pixel history across structure changes is
/// intentionally dropped (documented decision, keeps memory + correctness simple).
///
/// Memory is bounded by capping entries and dropping the oldest (disk spill deferred).
final class TileUndoStack {
    struct TileKey: Hashable { let col: Int; let row: Int }

    private struct TileSnapshot { let before: Data; var after: Data }
    private struct Entry {
        let layer: PaintLayer
        var tiles: [TileKey: TileSnapshot]
    }

    let tileSize: Int
    private let canvasWidth: Int
    private let canvasHeight: Int
    private let cols: Int
    private let rows: Int

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let maxEntries: Int

    // In-progress stroke accumulation.
    private var recording = false
    private var currentLayer: PaintLayer?
    private var current: [TileKey: TileSnapshot] = [:]

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(canvasWidth: Int, canvasHeight: Int, tileSize: Int = 256, maxEntries: Int = 30) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.tileSize = tileSize
        self.maxEntries = maxEntries
        self.cols = (canvasWidth + tileSize - 1) / tileSize
        self.rows = (canvasHeight + tileSize - 1) / tileSize
    }

    private func region(for key: TileKey) -> MTLRegion {
        let x = key.col * tileSize
        let y = key.row * tileSize
        let w = min(tileSize, canvasWidth - x)
        let h = min(tileSize, canvasHeight - y)
        return MTLRegionMake2D(x, y, w, h)
    }

    // MARK: Stroke lifecycle

    func beginStroke(layer: PaintLayer) {
        recording = true
        currentLayer = layer
        current.removeAll(keepingCapacity: true)
    }

    /// Called before painting into a canvas-space rect; snapshots any not-yet-captured tiles it overlaps.
    func willModify(rect: CGRect) {
        guard recording, let layer = currentLayer else { return }
        let minCol = max(0, Int(rect.minX) / tileSize)
        let maxCol = min(cols - 1, Int(rect.maxX) / tileSize)
        let minRow = max(0, Int(rect.minY) / tileSize)
        let maxRow = min(rows - 1, Int(rect.maxY) / tileSize)
        guard maxCol >= minCol, maxRow >= minRow else { return }
        for r in minRow...maxRow {
            for c in minCol...maxCol {
                let key = TileKey(col: c, row: r)
                if current[key] == nil {
                    let before = layer.readRegion(region(for: key))
                    current[key] = TileSnapshot(before: before, after: Data())
                }
            }
        }
    }

    func endStroke() {
        guard recording, let layer = currentLayer else { return }
        recording = false
        defer { currentLayer = nil }
        guard !current.isEmpty else { return }
        var tiles = current
        for (key, snap) in tiles {
            let after = layer.readRegion(region(for: key))
            tiles[key] = TileSnapshot(before: snap.before, after: after)
        }
        undoStack.append(Entry(layer: layer, tiles: tiles))
        if undoStack.count > maxEntries { undoStack.removeFirst() }
        redoStack.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
    }

    // MARK: Undo / redo / structural reset

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        for (key, snap) in entry.tiles {
            entry.layer.writeRegion(region(for: key), bytes: snap.before)
        }
        redoStack.append(entry)
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        for (key, snap) in entry.tiles {
            entry.layer.writeRegion(region(for: key), bytes: snap.after)
        }
        undoStack.append(entry)
    }

    /// Drops all history. Called on structural layer changes and on document close.
    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        current.removeAll()
        recording = false
        currentLayer = nil
    }
}
