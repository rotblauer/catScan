import Foundation

/// Wavefront OBJ. Vertex colors ride along as `v x y z r g b`, the extension
/// understood by MeshLab, Blender, and CloudCompare.
enum OBJExporter {

    static func write(mesh: MeshData, includeColors: Bool, to url: URL) throws {
        let useColors = includeColors && mesh.colors.count == mesh.vertexCount
        let hasNormals = mesh.normals.count == mesh.vertexCount

        var output = Data()
        output.reserveCapacity(mesh.vertexCount * (useColors ? 88 : 45) + mesh.faceCount * 26)
        var chunk = String()
        chunk.reserveCapacity(1 << 20)

        func flushIfNeeded(force: Bool = false) {
            if force || chunk.utf8.count > 900_000 {
                output.append(contentsOf: chunk.utf8)
                chunk.removeAll(keepingCapacity: true)
            }
        }

        chunk += "# Exported by CatScan\n"
        chunk += "o CatScanModel\n"

        for i in 0..<mesh.vertexCount {
            let p = mesh.positions[i]
            if useColors {
                let c = mesh.colors[i]
                chunk += "v \(p.x) \(p.y) \(p.z) \(Float(c.x) / 255) \(Float(c.y) / 255) \(Float(c.z) / 255)\n"
            } else {
                chunk += "v \(p.x) \(p.y) \(p.z)\n"
            }
            flushIfNeeded()
        }

        if hasNormals {
            for n in mesh.normals {
                chunk += "vn \(n.x) \(n.y) \(n.z)\n"
                flushIfNeeded()
            }
        }

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i] + 1
            let b = mesh.indices[i + 1] + 1
            let c = mesh.indices[i + 2] + 1
            if hasNormals {
                chunk += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            } else {
                chunk += "f \(a) \(b) \(c)\n"
            }
            flushIfNeeded()
            i += 3
        }

        flushIfNeeded(force: true)
        try output.write(to: url, options: .atomic)
    }
}
