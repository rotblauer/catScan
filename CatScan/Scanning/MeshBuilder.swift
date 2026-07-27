import ARKit
import Foundation
import simd

// MARK: - Capturing ARKit mesh anchors

/// A CPU-side copy of one ARMeshAnchor's geometry, taken on the session queue
/// so it can be processed safely after the session is torn down.
struct CapturedAnchorMesh {
    var transform: simd_float4x4
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var faceClasses: [UInt8]?

    init(anchor: ARMeshAnchor) {
        let geometry = anchor.geometry
        transform = anchor.transform
        vertices = geometry.vertices.asSIMD3Array()
        normals = geometry.normals.asSIMD3Array()
        indices = geometry.faces.asUInt32Array()
        faceClasses = geometry.classification?.asUInt8Array()
    }
}

extension ARGeometrySource {
    func asSIMD3Array() -> [SIMD3<Float>] {
        guard componentsPerVector == 3 else { return [] }
        let contents = buffer.contents()
        var result = [SIMD3<Float>]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let pointer = contents.advanced(by: offset + stride * i).assumingMemoryBound(to: Float.self)
            result.append(SIMD3(pointer[0], pointer[1], pointer[2]))
        }
        return result
    }

    func asUInt8Array() -> [UInt8] {
        guard componentsPerVector == 1 else { return [] }
        let contents = buffer.contents()
        var result = [UInt8]()
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(contents.load(fromByteOffset: offset + stride * i, as: UInt8.self))
        }
        return result
    }
}

extension ARGeometryElement {
    func asUInt32Array() -> [UInt32] {
        let total = count * indexCountPerPrimitive
        let contents = buffer.contents()
        switch bytesPerIndex {
        case 4:
            return [UInt32](unsafeUninitializedCapacity: total) { buffer, initialized in
                if total > 0 { memcpy(buffer.baseAddress!, contents, total * 4) }
                initialized = total
            }
        case 2:
            let pointer = contents.assumingMemoryBound(to: UInt16.self)
            return (0..<total).map { UInt32(pointer[$0]) }
        default:
            return []
        }
    }
}

// MARK: - Processing pipeline

enum ProcessingStage: CaseIterable {
    case merging, welding, extracting, coloring, cleaning, normals, simplifying

    var label: String {
        switch self {
        case .merging: return "Merging mesh chunks"
        case .welding: return "Welding vertices"
        case .extracting: return "Extracting detail surface"
        case .coloring: return "Painting colors"
        case .cleaning: return "Sweeping up floaters"
        case .normals: return "Smoothing normals"
        case .simplifying: return "Simplifying mesh"
        }
    }
}

enum MeshBuilder {

    /// Full post-scan pipeline for Room mode (ARKit mesh anchors). Returns the
    /// finished mesh and the fraction of vertices that received a real
    /// (non-inferred) color sample.
    static func process(anchors: [CapturedAnchorMesh],
                        colorStore: SpatialColorStore?,
                        simplifyCellSize: Float?,
                        progress: (ProcessingStage, Double) -> Void) -> (mesh: MeshData, colorFraction: Float) {
        var mesh = merge(anchors: anchors, progress: progress)

        progress(.welding, 0)
        weld(&mesh, epsilon: 0.0025)
        progress(.welding, 1)

        let colorFraction = finish(&mesh,
                                   colorStore: colorStore,
                                   simplifyCellSize: simplifyCellSize,
                                   progress: progress)
        return (mesh, colorFraction)
    }

    /// Finishing pipeline for Detail mode. The Surface Nets mesh already shares
    /// vertices, so no welding is needed.
    static func processDetail(surface: MeshData,
                              colorStore: SpatialColorStore?,
                              simplifyCellSize: Float?,
                              progress: (ProcessingStage, Double) -> Void) -> (mesh: MeshData, colorFraction: Float) {
        var mesh = surface
        let colorFraction = finish(&mesh,
                                   colorStore: colorStore,
                                   simplifyCellSize: simplifyCellSize,
                                   progress: progress)
        return (mesh, colorFraction)
    }

    /// Shared tail of both pipelines: colors → floater removal → normals →
    /// optional decimation.
    private static func finish(_ mesh: inout MeshData,
                               colorStore: SpatialColorStore?,
                               simplifyCellSize: Float?,
                               progress: (ProcessingStage, Double) -> Void) -> Float {
        var colorFraction: Float = 0
        progress(.coloring, 0)
        if let colorStore, colorStore.count > 0 {
            colorFraction = applyColors(&mesh, store: colorStore, progress: progress)
        } else {
            mesh.colors = [SIMD4<UInt8>](repeating: Self.fallbackColor, count: mesh.vertexCount)
        }
        progress(.coloring, 1)

        progress(.cleaning, 0)
        removeSmallComponents(&mesh)
        progress(.cleaning, 1)

        progress(.normals, 0)
        recomputeNormals(&mesh)
        progress(.normals, 1)

        if let cell = simplifyCellSize, cell > 0.004 {
            progress(.simplifying, 0)
            simplify(&mesh, cellSize: cell)
            recomputeNormals(&mesh)
            progress(.simplifying, 1)
        }

        return colorFraction
    }

    static let fallbackColor = SIMD4<UInt8>(196, 194, 201, 255)

    // MARK: Merge

    static func merge(anchors: [CapturedAnchorMesh], progress: (ProcessingStage, Double) -> Void) -> MeshData {
        var mesh = MeshData()
        let totalVertices = anchors.reduce(0) { $0 + $1.vertices.count }
        let totalIndices = anchors.reduce(0) { $0 + $1.indices.count }
        mesh.positions.reserveCapacity(totalVertices)
        mesh.normals.reserveCapacity(totalVertices)
        mesh.indices.reserveCapacity(totalIndices)

        let allHaveClasses = !anchors.isEmpty && anchors.allSatisfy { anchor in
            (anchor.faceClasses?.count ?? 0) == anchor.indices.count / 3
        }
        var classes: [UInt8] = []
        if allHaveClasses { classes.reserveCapacity(totalIndices / 3) }

        for (anchorIndex, anchor) in anchors.enumerated() {
            let base = UInt32(mesh.positions.count)
            let m = anchor.transform
            let rotation = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                         SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                         SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            for v in anchor.vertices {
                let w = m * SIMD4<Float>(v.x, v.y, v.z, 1)
                mesh.positions.append(SIMD3(w.x, w.y, w.z))
            }
            for n in anchor.normals {
                let r = rotation * n
                let len = simd_length(r)
                mesh.normals.append(len > 1e-6 ? r / len : SIMD3(0, 1, 0))
            }
            for index in anchor.indices {
                mesh.indices.append(base + index)
            }
            if allHaveClasses, let fc = anchor.faceClasses {
                classes.append(contentsOf: fc)
            }
            progress(.merging, Double(anchorIndex + 1) / Double(max(1, anchors.count)))
        }
        if allHaveClasses { mesh.faceClasses = classes }
        return mesh
    }

    // MARK: Weld

    /// Merges vertices that fall in the same `epsilon` grid cell — primarily the
    /// duplicated vertices along ARKit anchor tile borders. Drops normals
    /// (recomputed later) and degenerate faces.
    static func weld(_ mesh: inout MeshData, epsilon: Float) {
        guard mesh.vertexCount > 0 else { return }
        let inv = 1 / epsilon
        var cellToNew = [SIMD3<Int32>: UInt32](minimumCapacity: mesh.vertexCount)
        var remap = [UInt32](repeating: 0, count: mesh.vertexCount)
        var newPositions: [SIMD3<Float>] = []
        newPositions.reserveCapacity(mesh.vertexCount)

        for (i, p) in mesh.positions.enumerated() {
            let cell = SIMD3<Int32>(Int32((p.x * inv).rounded()),
                                    Int32((p.y * inv).rounded()),
                                    Int32((p.z * inv).rounded()))
            if let existing = cellToNew[cell] {
                remap[i] = existing
            } else {
                let newIndex = UInt32(newPositions.count)
                cellToNew[cell] = newIndex
                newPositions.append(p)
                remap[i] = newIndex
            }
        }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(mesh.indices.count)
        var newClasses: [UInt8]? = mesh.faceClasses != nil ? [] : nil
        var i = 0
        var face = 0
        while i + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[i])]
            let b = remap[Int(mesh.indices[i + 1])]
            let c = remap[Int(mesh.indices[i + 2])]
            if a != b, b != c, a != c {
                newIndices.append(a)
                newIndices.append(b)
                newIndices.append(c)
                if let fc = mesh.faceClasses, face < fc.count {
                    newClasses?.append(fc[face])
                }
            }
            i += 3
            face += 1
        }

        mesh.positions = newPositions
        mesh.normals = []
        mesh.colors = []
        mesh.indices = newIndices
        mesh.faceClasses = newClasses
    }

    // MARK: Color

    static func applyColors(_ mesh: inout MeshData, store: SpatialColorStore, progress: (ProcessingStage, Double) -> Void) -> Float {
        let n = mesh.vertexCount
        var colors = [SIMD4<UInt8>](repeating: fallbackColor, count: n)
        var isColored = [Bool](repeating: false, count: n)
        var coloredCount = 0

        let progressStep = max(1, n / 20)
        for i in 0..<n {
            if let rgb = store.lookup(point: mesh.positions[i]) {
                colors[i] = SIMD4(UInt8(min(255, max(0, rgb.x))),
                                  UInt8(min(255, max(0, rgb.y))),
                                  UInt8(min(255, max(0, rgb.z))),
                                  255)
                isColored[i] = true
                coloredCount += 1
            }
            if i % progressStep == 0 {
                progress(.coloring, Double(i) / Double(n) * 0.85)
            }
        }

        // Spread color into never-seen vertices from their colored neighbors.
        if coloredCount > 0 && coloredCount < n {
            for _ in 0..<3 {
                var sums = [SIMD3<Int32>](repeating: .zero, count: n)
                var counts = [Int32](repeating: 0, count: n)
                var i = 0
                while i + 2 < mesh.indices.count {
                    let tri = (Int(mesh.indices[i]), Int(mesh.indices[i + 1]), Int(mesh.indices[i + 2]))
                    accumulate(tri.0, tri.1, colors: colors, isColored: isColored, sums: &sums, counts: &counts)
                    accumulate(tri.1, tri.2, colors: colors, isColored: isColored, sums: &sums, counts: &counts)
                    accumulate(tri.2, tri.0, colors: colors, isColored: isColored, sums: &sums, counts: &counts)
                    i += 3
                }
                var changed = false
                for v in 0..<n where !isColored[v] && counts[v] > 0 {
                    let c = sums[v] / counts[v]
                    colors[v] = SIMD4(UInt8(clamping: c.x), UInt8(clamping: c.y), UInt8(clamping: c.z), 255)
                    isColored[v] = true
                    changed = true
                }
                if !changed { break }
            }
        }

        mesh.colors = colors
        return Float(coloredCount) / Float(max(1, n))
    }

    @inline(__always)
    private static func accumulate(_ a: Int, _ b: Int,
                                   colors: [SIMD4<UInt8>], isColored: [Bool],
                                   sums: inout [SIMD3<Int32>], counts: inout [Int32]) {
        if isColored[a], !isColored[b] {
            sums[b] &+= SIMD3(Int32(colors[a].x), Int32(colors[a].y), Int32(colors[a].z))
            counts[b] += 1
        } else if isColored[b], !isColored[a] {
            sums[a] &+= SIMD3(Int32(colors[b].x), Int32(colors[b].y), Int32(colors[b].z))
            counts[a] += 1
        }
    }

    // MARK: Cleanup

    /// Removes small disconnected islands ("floaters") that LiDAR scans pick up
    /// from noise and passing objects.
    static func removeSmallComponents(_ mesh: inout MeshData) {
        let n = mesh.vertexCount
        let faceCount = mesh.faceCount
        guard n > 0, faceCount > 0 else { return }

        var parent = [Int32](repeating: 0, count: n)
        for i in 0..<n { parent[i] = Int32(i) }

        func find(_ x: Int32) -> Int32 {
            var root = x
            while parent[Int(root)] != root { root = parent[Int(root)] }
            var current = x
            while parent[Int(current)] != root {
                let next = parent[Int(current)]
                parent[Int(current)] = root
                current = next
            }
            return root
        }

        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(ra)] = rb }
        }

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int32(mesh.indices[i])
            let b = Int32(mesh.indices[i + 1])
            let c = Int32(mesh.indices[i + 2])
            union(a, b)
            union(a, c)
            i += 3
        }

        var triCountByRoot = [Int32: Int](minimumCapacity: 64)
        i = 0
        while i + 2 < mesh.indices.count {
            triCountByRoot[find(Int32(mesh.indices[i])), default: 0] += 1
            i += 3
        }

        let threshold = max(30, faceCount / 1000)
        var keptRoots = Set(triCountByRoot.filter { $0.value >= threshold }.keys)
        if keptRoots.isEmpty, let biggest = triCountByRoot.max(by: { $0.value < $1.value }) {
            keptRoots = [biggest.key]
        }
        guard keptRoots.count < triCountByRoot.count else { return }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(mesh.indices.count)
        var newClasses: [UInt8]? = mesh.faceClasses != nil ? [] : nil
        i = 0
        var face = 0
        while i + 2 < mesh.indices.count {
            if keptRoots.contains(find(Int32(mesh.indices[i]))) {
                newIndices.append(mesh.indices[i])
                newIndices.append(mesh.indices[i + 1])
                newIndices.append(mesh.indices[i + 2])
                if let fc = mesh.faceClasses, face < fc.count {
                    newClasses?.append(fc[face])
                }
            }
            i += 3
            face += 1
        }
        mesh.indices = newIndices
        mesh.faceClasses = newClasses
        compactVertices(&mesh)
    }

    /// Drops vertices no face references and remaps indices.
    static func compactVertices(_ mesh: inout MeshData) {
        let n = mesh.vertexCount
        guard n > 0 else { return }
        var used = [Bool](repeating: false, count: n)
        for index in mesh.indices { used[Int(index)] = true }

        var remap = [UInt32](repeating: UInt32.max, count: n)
        var newPositions: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newColors: [SIMD4<UInt8>] = []
        let hasNormals = mesh.normals.count == n
        let hasColors = mesh.colors.count == n

        for i in 0..<n where used[i] {
            remap[i] = UInt32(newPositions.count)
            newPositions.append(mesh.positions[i])
            if hasNormals { newNormals.append(mesh.normals[i]) }
            if hasColors { newColors.append(mesh.colors[i]) }
        }
        guard newPositions.count < n else { return }

        mesh.positions = newPositions
        if hasNormals { mesh.normals = newNormals }
        if hasColors { mesh.colors = newColors }
        for i in 0..<mesh.indices.count {
            mesh.indices[i] = remap[Int(mesh.indices[i])]
        }
    }

    // MARK: Normals

    static func recomputeNormals(_ mesh: inout MeshData) {
        let n = mesh.vertexCount
        guard n > 0 else { return }
        var accumulated = [SIMD3<Float>](repeating: .zero, count: n)
        var i = 0
        while i + 2 < mesh.indices.count {
            let ia = Int(mesh.indices[i]), ib = Int(mesh.indices[i + 1]), ic = Int(mesh.indices[i + 2])
            let a = mesh.positions[ia]
            let faceNormal = simd_cross(mesh.positions[ib] - a, mesh.positions[ic] - a)  // area-weighted
            accumulated[ia] += faceNormal
            accumulated[ib] += faceNormal
            accumulated[ic] += faceNormal
            i += 3
        }
        for i in 0..<n {
            let len = simd_length(accumulated[i])
            accumulated[i] = len > 1e-9 ? accumulated[i] / len : SIMD3(0, 1, 0)
        }
        mesh.normals = accumulated
    }

    // MARK: Simplify

    /// Vertex-clustering decimation: snap vertices to a coarse grid, merge each
    /// cluster into its average, and drop collapsed faces. Fast and predictable;
    /// detail below `cellSize` is intentionally lost.
    static func simplify(_ mesh: inout MeshData, cellSize: Float) {
        let n = mesh.vertexCount
        guard n > 0 else { return }
        let inv = 1 / cellSize
        var cellToNew = [SIMD3<Int32>: UInt32](minimumCapacity: n / 4)
        var vertexToNew = [UInt32](repeating: 0, count: n)
        var positionSums: [SIMD3<Float>] = []
        var colorSums: [SIMD4<Float>] = []
        var counts: [Float] = []
        let hasColors = mesh.colors.count == n

        for i in 0..<n {
            let p = mesh.positions[i]
            let cell = SIMD3<Int32>(Int32((p.x * inv).rounded(.down)),
                                    Int32((p.y * inv).rounded(.down)),
                                    Int32((p.z * inv).rounded(.down)))
            let newIndex: UInt32
            if let existing = cellToNew[cell] {
                newIndex = existing
            } else {
                newIndex = UInt32(positionSums.count)
                cellToNew[cell] = newIndex
                positionSums.append(.zero)
                colorSums.append(.zero)
                counts.append(0)
            }
            vertexToNew[i] = newIndex
            positionSums[Int(newIndex)] += p
            if hasColors {
                let c = mesh.colors[i]
                colorSums[Int(newIndex)] += SIMD4(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
            }
            counts[Int(newIndex)] += 1
        }

        var newPositions = [SIMD3<Float>](repeating: .zero, count: positionSums.count)
        var newColors = hasColors ? [SIMD4<UInt8>](repeating: fallbackColor, count: positionSums.count) : []
        for i in 0..<positionSums.count {
            let count = max(1, counts[i])
            newPositions[i] = positionSums[i] / count
            if hasColors {
                let c = colorSums[i] / count
                newColors[i] = SIMD4(UInt8(min(255, max(0, c.x))),
                                     UInt8(min(255, max(0, c.y))),
                                     UInt8(min(255, max(0, c.z))),
                                     255)
            }
        }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(mesh.indices.count)
        var newClasses: [UInt8]? = mesh.faceClasses != nil ? [] : nil
        var i = 0
        var face = 0
        while i + 2 < mesh.indices.count {
            let a = vertexToNew[Int(mesh.indices[i])]
            let b = vertexToNew[Int(mesh.indices[i + 1])]
            let c = vertexToNew[Int(mesh.indices[i + 2])]
            if a != b, b != c, a != c {
                newIndices.append(a)
                newIndices.append(b)
                newIndices.append(c)
                if let fc = mesh.faceClasses, face < fc.count {
                    newClasses?.append(fc[face])
                }
            }
            i += 3
            face += 1
        }

        mesh.positions = newPositions
        mesh.colors = newColors
        mesh.normals = []
        mesh.indices = newIndices
        mesh.faceClasses = newClasses
        compactVertices(&mesh)
    }
}
