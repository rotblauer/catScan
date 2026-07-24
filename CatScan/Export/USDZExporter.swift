import Foundation
import simd

/// Writes USDZ packages by hand: a USDA layer carrying per-vertex
/// `displayColor` primvars (which AR Quick Look renders), packed into the
/// stored-zip container the USDZ spec requires, with 64-byte-aligned payloads.
///
/// SceneKit's own `SCNScene.write` was tried first, but it silently drops
/// vertex colors on the way to USD — a dealbreaker for colored scans.
enum USDZExporter {

    static func export(mesh: MeshData, includeColors: Bool, to url: URL) throws {
        let usda = buildUSDA(mesh: mesh, includeColors: includeColors)
        try USDZArchive.write(entries: [("model.usda", usda)], to: url)
    }

    /// USDZ generation is not instant for big meshes, so AR Quick Look reuses a
    /// per-scan cached file. Scans are immutable after processing, which makes
    /// this safe; the file is named after the scan for a nice Quick Look title.
    static func cachedUSDZ(for document: ScanDocument, mesh: MeshData) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches
            .appendingPathComponent("USDZ", isDirectory: true)
            .appendingPathComponent(document.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(document.name.sanitizedForFilename + ".usdz")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Clear stale files from before a rename.
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in existing { try? FileManager.default.removeItem(at: file) }
        }
        try export(mesh: mesh, includeColors: true, to: url)
        return url
    }

    // MARK: - USDA layer

    private static func buildUSDA(mesh: MeshData, includeColors: Bool) -> Data {
        let useColors = includeColors && mesh.colors.count == mesh.vertexCount
        let hasNormals = mesh.normals.count == mesh.vertexCount
        let (lo, hi) = mesh.bounds()

        var output = Data()
        output.reserveCapacity(mesh.vertexCount * 90 + mesh.indices.count * 8)
        var chunk = String()
        chunk.reserveCapacity(1 << 20)

        func flush(force: Bool = false) {
            if force || chunk.utf8.count > 900_000 {
                output.append(contentsOf: chunk.utf8)
                chunk.removeAll(keepingCapacity: true)
            }
        }

        chunk += """
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Model"
        {
            def Mesh "Geometry"
            {
                uniform token subdivisionScheme = "none"
                uniform bool doubleSided = 1
                float3[] extent = [(\(lo.x), \(lo.y), \(lo.z)), (\(hi.x), \(hi.y), \(hi.z))]

        """

        chunk += "        int[] faceVertexCounts = ["
        for face in 0..<mesh.faceCount {
            chunk += face == 0 ? "3" : ", 3"
            flush()
        }
        chunk += "]\n"

        chunk += "        int[] faceVertexIndices = ["
        for (i, index) in mesh.indices.enumerated() {
            chunk += i == 0 ? "\(index)" : ", \(index)"
            flush()
        }
        chunk += "]\n"

        chunk += "        point3f[] points = ["
        for (i, p) in mesh.positions.enumerated() {
            chunk += i == 0 ? "(\(p.x), \(p.y), \(p.z))" : ", (\(p.x), \(p.y), \(p.z))"
            flush()
        }
        chunk += "]\n"

        if hasNormals {
            chunk += "        normal3f[] normals = ["
            for (i, n) in mesh.normals.enumerated() {
                chunk += i == 0 ? "(\(n.x), \(n.y), \(n.z))" : ", (\(n.x), \(n.y), \(n.z))"
                flush()
            }
            chunk += "] (\n            interpolation = \"vertex\"\n        )\n"
        }

        if useColors {
            chunk += "        color3f[] primvars:displayColor = ["
            for (i, c) in mesh.colors.enumerated() {
                let r = Float(c.x) / 255
                let g = Float(c.y) / 255
                let b = Float(c.z) / 255
                chunk += i == 0 ? "(\(r), \(g), \(b))" : ", (\(r), \(g), \(b))"
                flush()
            }
            chunk += "] (\n            interpolation = \"vertex\"\n        )\n"
        }

        chunk += "    }\n}\n"
        flush(force: true)
        return output
    }
}

// MARK: - USDZ zip container

/// Minimal zip writer meeting the USDZ constraints: stored (uncompressed)
/// entries whose file data begins on a 64-byte boundary, padded via a
/// zero-filled extra field.
enum USDZArchive {

    static func write(entries: [(name: String, data: Data)], to url: URL) throws {
        var out = Data()
        var central = Data()

        for (name, data) in entries {
            let nameBytes = Array(name.utf8)
            let headerOffset = out.count
            let baseDataStart = headerOffset + 30 + nameBytes.count
            var padding = (64 - (baseDataStart % 64)) % 64
            if padding > 0 && padding < 4 { padding += 64 }
            let crc = crc32(data)

            // Local file header.
            out.appendValue(UInt32(0x04034b50))
            out.appendValue(UInt16(20))                 // version needed
            out.appendValue(UInt16(0))                  // flags
            out.appendValue(UInt16(0))                  // method: stored
            out.appendValue(UInt16(0))                  // DOS time
            out.appendValue(UInt16(0x21))               // DOS date (1980-01-01)
            out.appendValue(crc)
            out.appendValue(UInt32(data.count))         // compressed size
            out.appendValue(UInt32(data.count))         // uncompressed size
            out.appendValue(UInt16(nameBytes.count))
            out.appendValue(UInt16(padding))
            out.append(contentsOf: nameBytes)
            if padding > 0 {
                out.appendValue(UInt16(0x1986))         // usdz padding extra id
                out.appendValue(UInt16(padding - 4))
                out.append(Data(count: padding - 4))
            }
            out.append(data)

            // Central directory entry.
            central.appendValue(UInt32(0x02014b50))
            central.appendValue(UInt16(20))             // version made by
            central.appendValue(UInt16(20))             // version needed
            central.appendValue(UInt16(0))              // flags
            central.appendValue(UInt16(0))              // method
            central.appendValue(UInt16(0))              // DOS time
            central.appendValue(UInt16(0x21))           // DOS date
            central.appendValue(crc)
            central.appendValue(UInt32(data.count))
            central.appendValue(UInt32(data.count))
            central.appendValue(UInt16(nameBytes.count))
            central.appendValue(UInt16(0))              // extra length
            central.appendValue(UInt16(0))              // comment length
            central.appendValue(UInt16(0))              // disk number
            central.appendValue(UInt16(0))              // internal attributes
            central.appendValue(UInt32(0))              // external attributes
            central.appendValue(UInt32(headerOffset))
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = out.count
        out.append(central)

        // End of central directory.
        out.appendValue(UInt32(0x06054b50))
        out.appendValue(UInt16(0))                      // disk number
        out.appendValue(UInt16(0))                      // central directory disk
        out.appendValue(UInt16(entries.count))
        out.appendValue(UInt16(entries.count))
        out.appendValue(UInt32(central.count))
        out.appendValue(UInt32(centralOffset))
        out.appendValue(UInt16(0))                      // comment length

        try out.write(to: url, options: .atomic)
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
