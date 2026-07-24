import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case usdz, glb, obj, ply, stl

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .usdz: return "USDZ"
        case .glb: return "glTF Binary"
        case .obj: return "OBJ"
        case .ply: return "PLY"
        case .stl: return "STL"
        }
    }

    var note: String {
        switch self {
        case .usdz: return "Apple's AR format with per-vertex colors. Opens in AR Quick Look, Messages, and Reality Composer."
        case .glb: return "The web-standard 3D format. Opens in Blender, three.js, and Windows 3D Viewer with vertex colors."
        case .obj: return "Universally supported text format. Vertex colors use the MeshLab convention."
        case .ply: return "Compact binary format loved by MeshLab and CloudCompare. Best for colored scan data."
        case .stl: return "For 3D printing and CAD. Geometry only — no colors."
        }
    }

    var supportsColor: Bool {
        self != .stl
    }

    var systemImage: String {
        switch self {
        case .usdz: return "arkit"
        case .glb: return "globe"
        case .obj: return "doc.plaintext"
        case .ply: return "point.3.filled.connected.trianglepath.dotted"
        case .stl: return "printer.fill"
        }
    }
}

enum MeshExportError: LocalizedError {
    case emptyMesh
    case usdzWriteFailed

    var errorDescription: String? {
        switch self {
        case .emptyMesh: return "There is no geometry to export."
        case .usdzWriteFailed: return "SceneKit couldn't write the USDZ archive."
        }
    }
}

enum MeshExporter {

    /// Writes `mesh` to a shareable temp file and returns its URL.
    static func export(mesh: MeshData, name: String, format: ExportFormat, includeColors: Bool) async throws -> URL {
        guard mesh.vertexCount > 0, !mesh.indices.isEmpty else { throw MeshExportError.emptyMesh }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name.sanitizedForFilename + "." + format.fileExtension)
        try? FileManager.default.removeItem(at: url)

        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .obj: try OBJExporter.write(mesh: mesh, includeColors: includeColors, to: url)
            case .ply: try PLYExporter.write(mesh: mesh, includeColors: includeColors, to: url)
            case .stl: try STLExporter.write(mesh: mesh, to: url)
            case .glb: try GLBExporter.write(mesh: mesh, includeColors: includeColors, name: name, to: url)
            case .usdz: try USDZExporter.export(mesh: mesh, includeColors: includeColors, to: url)
            }
        }.value
        return url
    }

    static func estimatedSize(mesh: MeshData, format: ExportFormat, includeColors: Bool) -> Int {
        let v = mesh.vertexCount
        let f = mesh.faceCount
        switch format {
        case .obj: return v * (includeColors ? 88 : 45) + f * 26
        case .ply: return v * (includeColors ? 27 : 24) + f * 13 + 400
        case .stl: return 84 + f * 50
        case .glb: return v * (includeColors ? 36 : 24) + f * 12 + 1600
        case .usdz: return v * 30 + f * 12 + 4000
        }
    }
}

/// Accumulates little-endian binary output. All appends are byte-oriented, so
/// packed (unaligned) layouts like PLY's 27-byte vertices are safe.
struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(max(0, capacity))
    }

    mutating func append<T>(_ value: T) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    mutating func append(ascii: String) {
        bytes.append(contentsOf: ascii.utf8)
    }

    mutating func pad(toMultipleOf alignment: Int, with filler: UInt8 = 0) {
        while bytes.count % alignment != 0 { bytes.append(filler) }
    }

    var count: Int { bytes.count }
    var data: Data { Data(bytes) }
}
