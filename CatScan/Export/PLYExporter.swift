import Foundation

/// Binary little-endian PLY with optional per-vertex normals and colors —
/// the lingua franca of scan-processing tools.
enum PLYExporter {

    static func write(mesh: MeshData, includeColors: Bool, to url: URL) throws {
        let n = mesh.vertexCount
        let useColors = includeColors && mesh.colors.count == n
        let hasNormals = mesh.normals.count == n

        var header = "ply\nformat binary_little_endian 1.0\ncomment Exported by CatScan\n"
        header += "element vertex \(n)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if hasNormals {
            header += "property float nx\nproperty float ny\nproperty float nz\n"
        }
        if useColors {
            header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        }
        header += "element face \(mesh.faceCount)\n"
        header += "property list uchar int vertex_indices\nend_header\n"

        let vertexBytes = 12 + (hasNormals ? 12 : 0) + (useColors ? 3 : 0)
        var writer = BinaryWriter(capacity: header.utf8.count + n * vertexBytes + mesh.faceCount * 13)
        writer.append(ascii: header)

        for i in 0..<n {
            let p = mesh.positions[i]
            writer.append(p.x)
            writer.append(p.y)
            writer.append(p.z)
            if hasNormals {
                let nm = mesh.normals[i]
                writer.append(nm.x)
                writer.append(nm.y)
                writer.append(nm.z)
            }
            if useColors {
                let c = mesh.colors[i]
                writer.append(c.x)
                writer.append(c.y)
                writer.append(c.z)
            }
        }

        var i = 0
        while i + 2 < mesh.indices.count {
            writer.append(UInt8(3))
            writer.append(Int32(mesh.indices[i]))
            writer.append(Int32(mesh.indices[i + 1]))
            writer.append(Int32(mesh.indices[i + 2]))
            i += 3
        }

        try writer.data.write(to: url, options: .atomic)
    }
}
