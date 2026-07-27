import Foundation
import simd

/// A sparse voxel grid accumulating the best color sample seen for each small
/// cell of world space. Keyed by position rather than by mesh anchor, so it
/// survives ARKit's continuous mesh re-tessellation: at the end of a scan we
/// simply look up each final vertex position.
///
/// Threading: written from the ARSession delegate queue during a scan, then
/// read from the processing task after the session is paused. Never both at once.
final class SpatialColorStore {

    struct Sample {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var quality: Float
    }

    let cellSize: Float
    private let inverseCellSize: Float
    private let maxCells: Int
    private var cells: [Int64: Sample]

    init(cellSize: Float = 0.008, maxCells: Int = 3_500_000) {
        self.cellSize = cellSize
        self.inverseCellSize = 1 / cellSize
        self.maxCells = maxCells
        self.cells = Dictionary(minimumCapacity: 1 << 16)
    }

    var count: Int { cells.count }

    func removeAll() {
        cells.removeAll(keepingCapacity: true)
    }

    private static let axisOffset: Int32 = 1 << 20
    private static let axisLimit: Int32 = 1 << 21

    @inline(__always)
    private func cellCoordinate(_ p: SIMD3<Float>) -> SIMD3<Int32>? {
        let x = Int32((p.x * inverseCellSize).rounded(.down)) &+ Self.axisOffset
        let y = Int32((p.y * inverseCellSize).rounded(.down)) &+ Self.axisOffset
        let z = Int32((p.z * inverseCellSize).rounded(.down)) &+ Self.axisOffset
        guard x >= 0, x < Self.axisLimit, y >= 0, y < Self.axisLimit, z >= 0, z < Self.axisLimit else {
            return nil
        }
        return SIMD3(x, y, z)
    }

    @inline(__always)
    private static func key(_ c: SIMD3<Int32>) -> Int64 {
        (Int64(c.x) << 42) | (Int64(c.y) << 21) | Int64(c.z)
    }

    func integrate(point: SIMD3<Float>, r: UInt8, g: UInt8, b: UInt8, quality: Float) {
        guard let coord = cellCoordinate(point) else { return }
        let key = Self.key(coord)
        if let existing = cells[key] {
            if quality > existing.quality {
                cells[key] = Sample(r: r, g: g, b: b, quality: quality)
            }
        } else if cells.count < maxCells {
            cells[key] = Sample(r: r, g: g, b: b, quality: quality)
        }
    }

    /// Best sample quality at `point`'s cell or its six face neighbors.
    /// Returns 0 when nothing was ever seen nearby. Cheap enough to call
    /// per-vertex from the live coverage overlay.
    func maxQuality(near point: SIMD3<Float>) -> Float {
        guard let coord = cellCoordinate(point) else { return 0 }
        var best: Float = 0
        for offset in Self.axisNeighborhood {
            let c = coord &+ offset
            guard c.x >= 0, c.x < Self.axisLimit,
                  c.y >= 0, c.y < Self.axisLimit,
                  c.z >= 0, c.z < Self.axisLimit else { continue }
            if let sample = cells[Self.key(c)], sample.quality > best {
                best = sample.quality
            }
        }
        return best
    }

    private static let axisNeighborhood: [SIMD3<Int32>] = [
        SIMD3(0, 0, 0),
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
        SIMD3(0, 1, 0), SIMD3(0, -1, 0),
        SIMD3(0, 0, 1), SIMD3(0, 0, -1),
    ]

    /// Quality-weighted blend of samples in the 3×3×3 neighborhood around `point`.
    /// Returns RGB in 0...255, or nil when nothing was ever seen nearby.
    func lookup(point: SIMD3<Float>) -> SIMD3<Float>? {
        guard let coord = cellCoordinate(point) else { return nil }
        var sum = SIMD3<Float>.zero
        var weight: Float = 0
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dz: Int32 in -1...1 {
                    let c = coord &+ SIMD3(dx, dy, dz)
                    guard c.x >= 0, c.x < Self.axisLimit,
                          c.y >= 0, c.y < Self.axisLimit,
                          c.z >= 0, c.z < Self.axisLimit else { continue }
                    if let sample = cells[Self.key(c)] {
                        let w = sample.quality * (dx == 0 && dy == 0 && dz == 0 ? 2 : 1)
                        sum += SIMD3(Float(sample.r), Float(sample.g), Float(sample.b)) * w
                        weight += w
                    }
                }
            }
        }
        guard weight > 0 else { return nil }
        return sum / weight
    }
}
