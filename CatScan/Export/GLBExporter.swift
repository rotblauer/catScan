import Foundation
import simd

/// Hand-rolled glTF 2.0 binary (.glb) writer: JSON chunk + binary chunk with
/// POSITION / NORMAL / COLOR_0 attributes and 32-bit indices.
enum GLBExporter {

    static func write(mesh: MeshData, includeColors: Bool, name: String, to url: URL) throws {
        let n = mesh.vertexCount
        let useColors = includeColors && mesh.colors.count == n
        let hasNormals = mesh.normals.count == n

        // --- Binary chunk ---
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func addView(byteLength: Int, target: Int?) -> Int {
            var view: [String: Any] = [
                "buffer": 0,
                "byteOffset": bin.count - byteLength,
                "byteLength": byteLength,
            ]
            if let target { view["target"] = target }
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        // Positions (accessor 0). glTF requires min/max for POSITION.
        let positionsFlat = MeshData.flatten(mesh.positions)
        bin.appendArray(positionsFlat)
        let posView = addView(byteLength: positionsFlat.count * 4, target: 34962)
        let (lo, hi) = mesh.bounds()
        accessors.append([
            "bufferView": posView,
            "componentType": 5126,
            "count": n,
            "type": "VEC3",
            "min": [lo.x, lo.y, lo.z],
            "max": [hi.x, hi.y, hi.z],
        ])
        let positionAccessor = accessors.count - 1

        var normalAccessor: Int?
        if hasNormals {
            let normalsFlat = MeshData.flatten(mesh.normals)
            bin.appendArray(normalsFlat)
            let view = addView(byteLength: normalsFlat.count * 4, target: 34962)
            accessors.append([
                "bufferView": view,
                "componentType": 5126,
                "count": n,
                "type": "VEC3",
            ])
            normalAccessor = accessors.count - 1
        }

        var colorAccessor: Int?
        if useColors {
            var colorsFlat = [Float]()
            colorsFlat.reserveCapacity(n * 3)
            for c in mesh.colors {
                colorsFlat.append(Float(c.x) / 255)
                colorsFlat.append(Float(c.y) / 255)
                colorsFlat.append(Float(c.z) / 255)
            }
            bin.appendArray(colorsFlat)
            let view = addView(byteLength: colorsFlat.count * 4, target: 34962)
            accessors.append([
                "bufferView": view,
                "componentType": 5126,
                "count": n,
                "type": "VEC3",
            ])
            colorAccessor = accessors.count - 1
        }

        bin.appendArray(mesh.indices)
        let indexView = addView(byteLength: mesh.indices.count * 4, target: 34963)
        accessors.append([
            "bufferView": indexView,
            "componentType": 5125,
            "count": mesh.indices.count,
            "type": "SCALAR",
        ])
        let indexAccessor = accessors.count - 1

        while bin.count % 4 != 0 { bin.append(0) }

        // --- JSON chunk ---
        var attributes: [String: Any] = ["POSITION": positionAccessor]
        if let normalAccessor { attributes["NORMAL"] = normalAccessor }
        if let colorAccessor { attributes["COLOR_0"] = colorAccessor }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "CatScan"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": name]],
            "meshes": [[
                "primitives": [[
                    "attributes": attributes,
                    "indices": indexAccessor,
                    "mode": 4,
                    "material": 0,
                ]],
            ]],
            "materials": [[
                "name": "ScanMaterial",
                "doubleSided": true,
                "pbrMetallicRoughness": [
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.9,
                ],
            ]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        // --- Container ---
        var out = BinaryWriter(capacity: 12 + 8 + jsonData.count + 8 + bin.count)
        out.append(UInt32(0x46546C67))               // magic "glTF"
        out.append(UInt32(2))                        // container version
        out.append(UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        out.append(UInt32(jsonData.count))
        out.append(UInt32(0x4E4F534A))               // chunk type "JSON"
        var payload = out.data
        payload.append(jsonData)
        var binHeader = BinaryWriter(capacity: 8)
        binHeader.append(UInt32(bin.count))
        binHeader.append(UInt32(0x004E4942))         // chunk type "BIN\0"
        payload.append(binHeader.data)
        payload.append(bin)

        try payload.write(to: url, options: .atomic)
    }
}
