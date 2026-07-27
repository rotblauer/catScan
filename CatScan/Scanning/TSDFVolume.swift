import ARKit
import Foundation
import simd

/// Sparse truncated signed distance field fused from raw LiDAR depth frames —
/// CatScan's high-detail capture backend.
///
/// ARKit's scene-reconstruction mesh tops out around 2–5 cm features. Fusing
/// the depth maps ourselves into a 4–8 mm voxel grid and extracting the zero
/// surface (Surface Nets) recovers considerably finer geometry, at the cost of
/// scanning a bounded volume instead of a whole room.
///
/// Storage is brick-sparse: 8×8×8-voxel bricks are allocated only where the
/// surface band has been observed. Colors are NOT stored here — the existing
/// SpatialColorStore already accumulates position-keyed colors that apply to
/// any geometry source.
///
/// Threading: integrate on the session queue; extract after the session stops.
final class TSDFVolume {

    /// World position of grid corner (0,0,0).
    let origin: SIMD3<Float>
    let voxelSize: Float
    /// Half-width of the fused band around the surface, in meters.
    let truncation: Float
    /// Grid corners per axis.
    let dims: SIMD3<Int32>

    private let maxBricks: Int
    private(set) var saturated = false

    private static let brickVolume = 512   // 8 × 8 × 8

    private final class Brick {
        let sdf: UnsafeMutablePointer<Float>
        let weight: UnsafeMutablePointer<Float>

        init() {
            sdf = .allocate(capacity: TSDFVolume.brickVolume)
            weight = .allocate(capacity: TSDFVolume.brickVolume)
            sdf.initialize(repeating: 1, count: TSDFVolume.brickVolume)
            weight.initialize(repeating: 0, count: TSDFVolume.brickVolume)
        }

        deinit {
            sdf.deallocate()
            weight.deallocate()
        }
    }

    private var bricks: [Int64: Brick] = [:]

    // Single-thread memo: consecutive accesses cluster in the same brick.
    private var memoKey: Int64 = .min
    private var memoBrick: Brick?

    init(center: SIMD3<Float>, size: Float, voxelSize: Float, maxBricks: Int = 12_000) {
        self.voxelSize = voxelSize
        self.truncation = voxelSize * 3
        self.origin = center - SIMD3(repeating: size / 2)
        let cornersPerAxis = Int32((size / voxelSize).rounded(.up)) + 1
        self.dims = SIMD3(repeating: cornersPerAxis)
        self.maxBricks = maxBricks
    }

    var brickCount: Int { bricks.count }

    // MARK: - Voxel access

    @inline(__always)
    private static func key(_ bx: Int32, _ by: Int32, _ bz: Int32) -> Int64 {
        (Int64(bx) << 42) | (Int64(by) << 21) | Int64(bz)
    }

    @inline(__always)
    private func brickSlot(for g: SIMD3<Int32>, create: Bool) -> (Brick, Int)? {
        let key = Self.key(g.x >> 3, g.y >> 3, g.z >> 3)
        var brick: Brick?
        if key == memoKey {
            brick = memoBrick
        } else {
            brick = bricks[key]
            if brick == nil, create {
                guard bricks.count < maxBricks else {
                    saturated = true
                    return nil
                }
                brick = Brick()
                bricks[key] = brick
            }
            memoKey = key
            memoBrick = brick
        }
        guard let brick else { return nil }
        let index = (Int(g.z & 7) << 6) | (Int(g.y & 7) << 3) | Int(g.x & 7)
        return (brick, index)
    }

    /// (sdf, weight) at a grid corner; unobserved corners read as (+1, 0).
    @inline(__always)
    func sample(_ g: SIMD3<Int32>) -> (sdf: Float, weight: Float) {
        guard g.x >= 0, g.y >= 0, g.z >= 0,
              g.x < dims.x, g.y < dims.y, g.z < dims.z,
              let (brick, index) = brickSlot(for: g, create: false) else {
            return (1, 0)
        }
        return (brick.sdf[index], brick.weight[index])
    }

    // MARK: - Integration

    /// Fuse one depth image. Pointers are row-major with the given element
    /// strides; intrinsics must already be scaled to the depth resolution.
    /// Camera convention matches ARKit: +x right, +y up, -z forward, with
    /// pixel +v pointing down.
    func integrate(depth: UnsafePointer<Float32>, depthRowStride: Int,
                   confidence: UnsafePointer<UInt8>?, confidenceRowStride: Int,
                   width: Int, height: Int,
                   fx: Float, fy: Float, cx: Float, cy: Float,
                   cameraTransform: simd_float4x4) {
        guard fx > 0, fy > 0 else { return }
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x,
                                          cameraTransform.columns.3.y,
                                          cameraTransform.columns.3.z)
        let gridMax = SIMD3<Float>(Float(dims.x - 1), Float(dims.y - 1), Float(dims.z - 1)) * voxelSize
        let boxLo = origin - SIMD3(repeating: truncation)
        let boxHi = origin + gridMax + SIMD3(repeating: truncation)
        let invVoxel = 1 / voxelSize

        for v in 0..<height {
            let depthRow = depth + v * depthRowStride
            let confRow = confidence.map { $0 + v * confidenceRowStride }
            for u in 0..<width {
                let d = depthRow[u]
                guard d.isFinite, d > 0.15, d < 3.5 else { continue }
                var confWeight: Float = 1
                if let confRow {
                    let c = confRow[u]
                    guard c >= 1 else { continue }
                    confWeight = c >= 2 ? 1 : 0.5
                }

                let xc = (Float(u) + 0.5 - cx) * d / fx
                let yc = (Float(v) + 0.5 - cy) * d / fy
                let world4 = cameraTransform * SIMD4<Float>(xc, -yc, -d, 1)
                let p = SIMD3(world4.x, world4.y, world4.z)
                guard p.x > boxLo.x, p.y > boxLo.y, p.z > boxLo.z,
                      p.x < boxHi.x, p.y < boxHi.y, p.z < boxHi.z else { continue }

                var ray = p - cameraPosition
                let surfaceT = simd_length(ray)
                guard surfaceT > 1e-4 else { continue }
                ray /= surfaceT

                // March the truncation band around the surface point and splat
                // each sample into its full 2×2×2 corner neighborhood. Depth
                // rays can be sparser than the voxel grid (≈12 mm apart at 1 m
                // versus 4–8 mm voxels), so nearest-corner updates would leave
                // unobserved corners and Surface Nets would reject those cells.
                // Each corner gets its exact signed distance along the ray and
                // a trilinear share of the sample weight.
                let baseWeight = confWeight * min(1, 1 / (d * d))
                for step in -3...3 {
                    let q = p + ray * (Float(step) * voxelSize)
                    let gf = (q - origin) * invVoxel
                    let bx = Int32(gf.x.rounded(.down))
                    let by = Int32(gf.y.rounded(.down))
                    let bz = Int32(gf.z.rounded(.down))
                    for dz: Int32 in 0...1 {
                        for dy: Int32 in 0...1 {
                            for dx: Int32 in 0...1 {
                                let g = SIMD3(bx + dx, by + dy, bz + dz)
                                guard g.x >= 0, g.y >= 0, g.z >= 0,
                                      g.x < dims.x, g.y < dims.y, g.z < dims.z else { continue }

                                let cornerWorld = origin + SIMD3<Float>(g) * voxelSize
                                let cornerT = simd_dot(cornerWorld - cameraPosition, ray)
                                let sdfRaw = surfaceT - cornerT
                                guard abs(sdfRaw) <= truncation else { continue }

                                let tri = (1 - abs(gf.x - Float(g.x)))
                                        * (1 - abs(gf.y - Float(g.y)))
                                        * (1 - abs(gf.z - Float(g.z)))
                                guard tri > 0.001 else { continue }

                                // Behind-surface samples are less trustworthy.
                                let behindPenalty: Float = sdfRaw < 0 ? 0.6 : 1
                                let w = baseWeight * tri * behindPenalty
                                guard let (brick, index) = brickSlot(for: g, create: true) else { continue }
                                let sdfSample = max(-1, min(1, sdfRaw / truncation))
                                let oldWeight = brick.weight[index]
                                let sum = oldWeight + w
                                brick.sdf[index] = (brick.sdf[index] * oldWeight + sdfSample * w) / max(1e-5, sum)
                                brick.weight[index] = min(60, sum)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Test/debug entry: fill every grid corner from an analytic signed
    /// distance function (in meters).
    func fill(sdf: (SIMD3<Float>) -> Float) {
        for z in 0..<dims.z {
            for y in 0..<dims.y {
                for x in 0..<dims.x {
                    let g = SIMD3(x, y, z)
                    guard let (brick, index) = brickSlot(for: g, create: true) else { continue }
                    let p = origin + SIMD3(Float(x), Float(y), Float(z)) * voxelSize
                    brick.sdf[index] = max(-1, min(1, sdf(p) / truncation))
                    brick.weight[index] = 10
                }
            }
        }
    }

    // MARK: - Surface extraction (Surface Nets)

    private static let cornerOffsets: [SIMD3<Int32>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1),
    ]

    private static let cellEdges: [(Int, Int)] = [
        (0, 1), (2, 3), (4, 5), (6, 7),
        (0, 2), (1, 3), (4, 6), (5, 7),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    /// The four cells adjacent to a +axis lattice edge, per axis.
    private static let edgeCellOffsets: [[SIMD3<Int32>]] = [
        [SIMD3(0, -1, -1), SIMD3(0, 0, -1), SIMD3(0, 0, 0), SIMD3(0, -1, 0)],
        [SIMD3(-1, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, -1)],
        [SIMD3(-1, -1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 0), SIMD3(-1, 0, 0)],
    ]

    private static let axisUnits: [SIMD3<Int32>] = [
        SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
    ]

    @inline(__always)
    private static func cellKey(_ g: SIMD3<Int32>) -> Int64 {
        (Int64(g.x) << 42) | (Int64(g.y) << 21) | Int64(g.z)
    }

    /// Extracts the zero-level surface. Vertices are naturally shared (one per
    /// sign-changing cell), so the result needs no welding. Triangle winding is
    /// corrected against the SDF gradient so normals point out of the surface.
    func extractSurface(minWeight: Float = 0.8) -> MeshData {
        var mesh = MeshData()
        var cellVertex = [Int64: UInt32](minimumCapacity: bricks.count * 32)
        let brickKeys = Array(bricks.keys)
        let mask21: Int64 = (1 << 21) - 1

        // Pass 1: one vertex per sign-changing cell (min corner is always in
        // an allocated brick, because a valid cell needs all 8 corners valid).
        var cornerSDF = [Float](repeating: 0, count: 8)
        for key in brickKeys {
            let base = SIMD3<Int32>(Int32((key >> 42) & mask21) << 3,
                                    Int32((key >> 21) & mask21) << 3,
                                    Int32(key & mask21) << 3)
            for lz: Int32 in 0..<8 {
                for ly: Int32 in 0..<8 {
                    for lx: Int32 in 0..<8 {
                        let g = base &+ SIMD3(lx, ly, lz)
                        guard g.x + 1 < dims.x, g.y + 1 < dims.y, g.z + 1 < dims.z else { continue }

                        var signMask = 0
                        var valid = true
                        for ci in 0..<8 {
                            let (d, w) = sample(g &+ Self.cornerOffsets[ci])
                            if w < minWeight { valid = false; break }
                            cornerSDF[ci] = d
                            if d < 0 { signMask |= 1 << ci }
                        }
                        guard valid, signMask != 0, signMask != 255 else { continue }

                        var accumulated = SIMD3<Float>.zero
                        var crossings = 0
                        for (a, b) in Self.cellEdges {
                            let da = cornerSDF[a]
                            let db = cornerSDF[b]
                            guard (da < 0) != (db < 0) else { continue }
                            let t = da / (da - db)
                            let pa = SIMD3<Float>(Self.cornerOffsets[a])
                            let pb = SIMD3<Float>(Self.cornerOffsets[b])
                            accumulated += pa + (pb - pa) * t
                            crossings += 1
                        }
                        guard crossings > 0 else { continue }

                        let local = accumulated / Float(crossings)
                        let world = origin + (SIMD3<Float>(g) + local) * voxelSize
                        cellVertex[Self.cellKey(g)] = UInt32(mesh.positions.count)
                        mesh.positions.append(world)
                    }
                }
            }
        }

        // Pass 2: a quad around every sign-changing lattice edge whose four
        // adjacent cells all produced vertices.
        for key in brickKeys {
            let base = SIMD3<Int32>(Int32((key >> 42) & mask21) << 3,
                                    Int32((key >> 21) & mask21) << 3,
                                    Int32(key & mask21) << 3)
            for lz: Int32 in 0..<8 {
                for ly: Int32 in 0..<8 {
                    for lx: Int32 in 0..<8 {
                        let g = base &+ SIMD3(lx, ly, lz)
                        let (d0, w0) = sample(g)
                        guard w0 >= minWeight else { continue }

                        for axis in 0..<3 {
                            let g2 = g &+ Self.axisUnits[axis]
                            guard g2.x < dims.x, g2.y < dims.y, g2.z < dims.z else { continue }
                            let (d1, w1) = sample(g2)
                            guard w1 >= minWeight, (d0 < 0) != (d1 < 0) else { continue }

                            let offsets = Self.edgeCellOffsets[axis]
                            guard let v0 = cellVertex[Self.cellKey(g &+ offsets[0])],
                                  let v1 = cellVertex[Self.cellKey(g &+ offsets[1])],
                                  let v2 = cellVertex[Self.cellKey(g &+ offsets[2])],
                                  let v3 = cellVertex[Self.cellKey(g &+ offsets[3])] else { continue }

                            if d0 < 0 {
                                mesh.indices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
                            } else {
                                mesh.indices.append(contentsOf: [v0, v2, v1, v0, v3, v2])
                            }
                        }
                    }
                }
            }
        }

        fixWinding(&mesh)
        return mesh
    }

    /// Grid-space SDF gradient by central differences.
    private func gradient(atWorld p: SIMD3<Float>) -> SIMD3<Float> {
        let g = SIMD3<Int32>(Int32(((p.x - origin.x) / voxelSize).rounded()),
                             Int32(((p.y - origin.y) / voxelSize).rounded()),
                             Int32(((p.z - origin.z) / voxelSize).rounded()))
        let dx = sample(g &+ SIMD3(1, 0, 0)).sdf - sample(g &- SIMD3(1, 0, 0)).sdf
        let dy = sample(g &+ SIMD3(0, 1, 0)).sdf - sample(g &- SIMD3(0, 1, 0)).sdf
        let dz = sample(g &+ SIMD3(0, 0, 1)).sdf - sample(g &- SIMD3(0, 0, 1)).sdf
        return SIMD3(dx, dy, dz)
    }

    /// Ensures triangles wind so geometric normals align with the SDF gradient
    /// (which points from inside to outside). Sidesteps per-axis winding-table
    /// bugs entirely.
    private func fixWinding(_ mesh: inout MeshData) {
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])]
            let b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            let normal = simd_cross(b - a, c - a)
            let grad = gradient(atWorld: (a + b + c) / 3)
            if simd_dot(normal, grad) < 0 {
                mesh.indices.swapAt(i + 1, i + 2)
            }
            i += 3
        }
    }
}

// MARK: - ARKit convenience

extension TSDFVolume {

    /// Fuses one ARFrame's scene depth (locks/unlocks the pixel buffers).
    func integrate(frame: ARFrame) {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        let confidenceMap = sceneDepth.confidenceMap
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride

        var confPointer: UnsafePointer<UInt8>?
        var confRowStride = 0
        if let confidenceMap, let base = CVPixelBufferGetBaseAddress(confidenceMap) {
            confPointer = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            confRowStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }

        let intrinsics = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution
        let sx = Float(width) / Float(imageSize.width)
        let sy = Float(height) / Float(imageSize.height)

        integrate(depth: depthBase.assumingMemoryBound(to: Float32.self),
                  depthRowStride: depthRowStride,
                  confidence: confPointer,
                  confidenceRowStride: confRowStride,
                  width: width,
                  height: height,
                  fx: intrinsics[0][0] * sx,
                  fy: intrinsics[1][1] * sy,
                  cx: intrinsics[2][0] * sx,
                  cy: intrinsics[2][1] * sy,
                  cameraTransform: frame.camera.transform)
    }
}
