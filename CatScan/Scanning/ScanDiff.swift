import Foundation
import simd

/// Result of comparing a rescan against its reference scan. Both meshes must
/// share a coordinate frame (the rescan session was started from the
/// reference's ARWorldMap).
struct ScanDiffResult {
    /// Per-vertex flag on the NEW mesh: true where geometry appeared.
    var addedMask: [Bool]
    /// Faces of the REFERENCE mesh judged to have disappeared.
    var removedSubmesh: MeshData
    var addedArea: Float
    var removedArea: Float
}

/// Voxel-occupancy diff between two scans of the same space.
///
/// A vertex counts as "present in the other scan" when any occupied cell of
/// the other mesh lies within its 3×3×3 neighborhood, so the effective match
/// tolerance is 1–2 cells — sized to absorb ARKit relocalization drift and
/// re-tessellation jitter rather than real object changes.
enum ScanDiff {

    static let defaultTolerance: Float = 0.025

    static func compute(new newMesh: MeshData,
                        reference: MeshData,
                        tolerance: Float = ScanDiff.defaultTolerance) -> ScanDiffResult {
        let referenceCells = occupancy(of: reference, cellSize: tolerance)
        let newCells = occupancy(of: newMesh, cellSize: tolerance)

        let addedFaces = changedFaces(in: newMesh, absentFrom: referenceCells, cellSize: tolerance)
        let removedFaces = changedFaces(in: reference, absentFrom: newCells, cellSize: tolerance)

        // Kill speckle: keep only connected patches of meaningful size.
        let keptAdded = filterSpeckle(faceIndices: addedFaces, mesh: newMesh, minTriangles: 25)
        let keptRemoved = filterSpeckle(faceIndices: removedFaces, mesh: reference, minTriangles: 25)

        var addedMask = [Bool](repeating: false, count: newMesh.vertexCount)
        var addedArea: Float = 0
        for face in keptAdded {
            let (a, b, c) = faceVertices(newMesh, face)
            addedMask[Int(newMesh.indices[face * 3])] = true
            addedMask[Int(newMesh.indices[face * 3 + 1])] = true
            addedMask[Int(newMesh.indices[face * 3 + 2])] = true
            addedArea += triangleArea(a, b, c)
        }

        var removedArea: Float = 0
        var removedSubmesh = MeshData()
        removedSubmesh.indices.reserveCapacity(keptRemoved.count * 3)
        for face in keptRemoved {
            let (a, b, c) = faceVertices(reference, face)
            removedArea += triangleArea(a, b, c)
            removedSubmesh.indices.append(reference.indices[face * 3])
            removedSubmesh.indices.append(reference.indices[face * 3 + 1])
            removedSubmesh.indices.append(reference.indices[face * 3 + 2])
        }
        removedSubmesh.positions = reference.positions
        MeshBuilder.compactVertices(&removedSubmesh)
        MeshBuilder.recomputeNormals(&removedSubmesh)

        return ScanDiffResult(addedMask: addedMask,
                              removedSubmesh: removedSubmesh,
                              addedArea: addedArea,
                              removedArea: removedArea)
    }

    // MARK: - Internals

    /// Occupied cells of a mesh: face-referenced vertices plus face centroids
    /// (centroids densify large triangles so tolerance checks don't fall
    /// through gaps; unreferenced vertices are ignored so orphaned points
    /// can't mask real changes).
    private static func occupancy(of mesh: MeshData, cellSize: Float) -> Set<Int64> {
        var cells = Set<Int64>(minimumCapacity: mesh.vertexCount * 2)
        let inv = 1 / cellSize
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])]
            let b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            cells.insert(cellKey(a, inv))
            cells.insert(cellKey(b, inv))
            cells.insert(cellKey(c, inv))
            cells.insert(cellKey((a + b + c) / 3, inv))
            i += 3
        }
        return cells
    }

    private static let axisOffset: Int64 = 1 << 20

    @inline(__always)
    private static func cellKey(_ p: SIMD3<Float>, _ inverseCell: Float) -> Int64 {
        let x = Int64((p.x * inverseCell).rounded(.down)) + axisOffset
        let y = Int64((p.y * inverseCell).rounded(.down)) + axisOffset
        let z = Int64((p.z * inverseCell).rounded(.down)) + axisOffset
        return (x << 42) | (y << 21) | z
    }

    @inline(__always)
    private static func isNear(_ p: SIMD3<Float>, cells: Set<Int64>, inverseCell: Float) -> Bool {
        let bx = Int64((p.x * inverseCell).rounded(.down)) + axisOffset
        let by = Int64((p.y * inverseCell).rounded(.down)) + axisOffset
        let bz = Int64((p.z * inverseCell).rounded(.down)) + axisOffset
        for dx: Int64 in -1...1 {
            for dy: Int64 in -1...1 {
                for dz: Int64 in -1...1 {
                    if cells.contains((((bx + dx) << 42) | ((by + dy) << 21) | (bz + dz))) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Faces of `mesh` where at least two vertices have no counterpart in
    /// `other`'s occupancy.
    private static func changedFaces(in mesh: MeshData, absentFrom other: Set<Int64>, cellSize: Float) -> [Int] {
        let inv = 1 / cellSize
        var vertexAbsent = [Bool](repeating: false, count: mesh.vertexCount)
        for i in 0..<mesh.vertexCount {
            vertexAbsent[i] = !isNear(mesh.positions[i], cells: other, inverseCell: inv)
        }
        var faces: [Int] = []
        let faceCount = mesh.faceCount
        faces.reserveCapacity(faceCount / 8)
        for face in 0..<faceCount {
            var absent = 0
            for corner in 0..<3 where vertexAbsent[Int(mesh.indices[face * 3 + corner])] {
                absent += 1
            }
            if absent >= 2 {
                faces.append(face)
            }
        }
        return faces
    }

    /// Keeps only faces belonging to connected groups of at least
    /// `minTriangles` (connectivity via shared vertices within the group).
    private static func filterSpeckle(faceIndices: [Int], mesh: MeshData, minTriangles: Int) -> [Int] {
        guard faceIndices.count >= minTriangles else { return [] }

        var vertexToLocal = [UInt32: Int](minimumCapacity: faceIndices.count * 3)
        var parent: [Int] = []

        func localIndex(_ vertex: UInt32) -> Int {
            if let existing = vertexToLocal[vertex] { return existing }
            let index = parent.count
            vertexToLocal[vertex] = index
            parent.append(index)
            return index
        }

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var current = x
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        for face in faceIndices {
            let a = localIndex(mesh.indices[face * 3])
            let b = localIndex(mesh.indices[face * 3 + 1])
            let c = localIndex(mesh.indices[face * 3 + 2])
            let ra = find(a), rb = find(b), rc = find(c)
            if ra != rb { parent[ra] = rb }
            let rb2 = find(b)
            if rc != rb2 { parent[rc] = rb2 }
        }

        var countByRoot = [Int: Int](minimumCapacity: 32)
        for face in faceIndices {
            countByRoot[find(localIndex(mesh.indices[face * 3])), default: 0] += 1
        }
        return faceIndices.filter { face in
            countByRoot[find(localIndex(mesh.indices[face * 3]))] ?? 0 >= minTriangles
        }
    }

    @inline(__always)
    private static func faceVertices(_ mesh: MeshData, _ face: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        (mesh.positions[Int(mesh.indices[face * 3])],
         mesh.positions[Int(mesh.indices[face * 3 + 1])],
         mesh.positions[Int(mesh.indices[face * 3 + 2])])
    }

    @inline(__always)
    private static func triangleArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        simd_length(simd_cross(b - a, c - a)) * 0.5
    }
}
