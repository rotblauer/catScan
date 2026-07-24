import Foundation
import simd

/// Binary STL for 3D printing. Face normals are computed per triangle;
/// STL carries no color or vertex-sharing information.
enum STLExporter {

    static func write(mesh: MeshData, to url: URL) throws {
        let faceCount = mesh.faceCount
        var writer = BinaryWriter(capacity: 84 + faceCount * 50)

        var header = [UInt8](repeating: 0, count: 80)
        let tag = Array("CatScan binary STL".utf8)
        header.replaceSubrange(0..<tag.count, with: tag)
        for byte in header { writer.append(byte) }
        writer.append(UInt32(faceCount))

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])]
            let b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            normal = length > 1e-12 ? normal / length : SIMD3(0, 0, 0)

            writer.append(normal.x)
            writer.append(normal.y)
            writer.append(normal.z)
            for vertex in [a, b, c] {
                writer.append(vertex.x)
                writer.append(vertex.y)
                writer.append(vertex.z)
            }
            writer.append(UInt16(0))
            i += 3
        }

        try writer.data.write(to: url, options: .atomic)
    }
}
