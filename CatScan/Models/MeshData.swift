import Foundation
import simd

/// A triangle mesh with per-vertex colors and optional per-face semantic
/// classification. Positions are in meters, world-aligned (gravity = -Y).
struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// RGBA, one per vertex. Empty means "not colored yet".
    var colors: [SIMD4<UInt8>] = []
    /// Triangle list, three indices per face.
    var indices: [UInt32] = []
    /// One `ARMeshClassification` raw value per face, when captured.
    var faceClasses: [UInt8]?

    var vertexCount: Int { positions.count }
    var faceCount: Int { indices.count / 3 }

    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    func surfaceArea() -> Float {
        var area: Float = 0
        var i = 0
        while i + 2 < indices.count {
            let a = positions[Int(indices[i])]
            let b = positions[Int(indices[i + 1])]
            let c = positions[Int(indices[i + 2])]
            area += simd_length(simd_cross(b - a, c - a)) * 0.5
            i += 3
        }
        return area
    }
}

// MARK: - Binary serialization

enum MeshSerializationError: LocalizedError {
    case badHeader
    case unsupportedVersion
    case truncated

    var errorDescription: String? {
        switch self {
        case .badHeader: return "The scan file is not in a recognized format."
        case .unsupportedVersion: return "The scan file was written by a newer version of CatScan."
        case .truncated: return "The scan file is damaged or incomplete."
        }
    }
}

extension MeshData {
    private static let magic: [UInt8] = Array("CATMESH1".utf8)
    private static let formatVersion: UInt32 = 1
    private struct Flags {
        static let colors: UInt32 = 1 << 0
        static let classes: UInt32 = 1 << 1
    }

    func serialized() -> Data {
        var flags: UInt32 = 0
        if colors.count == vertexCount, vertexCount > 0 { flags |= Flags.colors }
        if let fc = faceClasses, fc.count == faceCount { flags |= Flags.classes }

        var data = Data()
        data.reserveCapacity(32 + vertexCount * 28 + indices.count * 4)
        data.append(contentsOf: Self.magic)
        data.appendValue(Self.formatVersion)
        data.appendValue(flags)
        data.appendValue(UInt32(vertexCount))
        data.appendValue(UInt32(indices.count))

        data.appendArray(Self.flatten(positions))
        data.appendArray(Self.flatten(normals.count == vertexCount ? normals : [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: vertexCount)))
        if flags & Flags.colors != 0 {
            data.appendArray(colors)
        }
        data.appendArray(indices)
        if flags & Flags.classes != 0, let fc = faceClasses {
            data.appendArray(fc)
        }
        return data
    }

    func write(to url: URL) throws {
        try serialized().write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> MeshData {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 24 else { throw MeshSerializationError.truncated }
        guard Array(data.prefix(8)) == magic else { throw MeshSerializationError.badHeader }

        var offset = 8
        let version: UInt32 = try data.readValue(at: &offset)
        guard version == formatVersion else { throw MeshSerializationError.unsupportedVersion }
        let flags: UInt32 = try data.readValue(at: &offset)
        let vertexCount = Int(try data.readValue(at: &offset) as UInt32)
        let indexCount = Int(try data.readValue(at: &offset) as UInt32)
        guard vertexCount >= 0, indexCount >= 0, vertexCount < 80_000_000, indexCount < 240_000_000 else {
            throw MeshSerializationError.truncated
        }

        var mesh = MeshData()
        mesh.positions = unflatten(try data.readArray(at: &offset, count: vertexCount * 3))
        mesh.normals = unflatten(try data.readArray(at: &offset, count: vertexCount * 3))
        if flags & Flags.colors != 0 {
            mesh.colors = try data.readArray(at: &offset, count: vertexCount)
        }
        mesh.indices = try data.readArray(at: &offset, count: indexCount)
        if flags & Flags.classes != 0 {
            mesh.faceClasses = try data.readArray(at: &offset, count: indexCount / 3)
        }
        return mesh
    }

    static func flatten(_ vectors: [SIMD3<Float>]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(vectors.count * 3)
        for v in vectors {
            out.append(v.x)
            out.append(v.y)
            out.append(v.z)
        }
        return out
    }

    static func unflatten(_ floats: [Float]) -> [SIMD3<Float>] {
        let count = floats.count / 3
        var out = [SIMD3<Float>]()
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(SIMD3(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2]))
        }
        return out
    }
}

// MARK: - Raw data helpers

extension Data {
    mutating func appendValue<T>(_ value: T) {
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }

    mutating func appendArray<T>(_ array: [T]) {
        guard !array.isEmpty else { return }
        array.withUnsafeBufferPointer { buffer in
            guard let base = UnsafeRawBufferPointer(buffer).bindMemory(to: UInt8.self).baseAddress else { return }
            append(base, count: buffer.count * MemoryLayout<T>.stride)
        }
    }

    func readValue<T>(at offset: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= count else { throw MeshSerializationError.truncated }
        let value = withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return value
    }

    func readArray<T>(at offset: inout Int, count elementCount: Int) throws -> [T] {
        let byteCount = MemoryLayout<T>.stride * elementCount
        guard byteCount >= 0, offset + byteCount <= count else { throw MeshSerializationError.truncated }
        let localOffset = offset
        let array = [T](unsafeUninitializedCapacity: elementCount) { buffer, initialized in
            if elementCount > 0 {
                let raw = UnsafeMutableRawBufferPointer(buffer)
                copyBytes(to: raw, from: (startIndex + localOffset)..<(startIndex + localOffset + byteCount))
            }
            initialized = elementCount
        }
        offset += byteCount
        return array
    }
}
