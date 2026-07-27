import Foundation
import simd

/// One frame of a volumetric clip: a colored world-space point cloud.
struct MomentFrame {
    /// Seconds since the first frame.
    var time: Float
    var positions: [SIMD3<Float>]
    var colors: [SIMD4<UInt8>]
}

/// A short volumetric video — depth+color point clouds at ~15 fps that can be
/// replayed from any angle. CatScan's answer to "what if the shutter button
/// captured *space*, not pixels".
struct MomentClip {
    var frames: [MomentFrame]

    var duration: Float {
        frames.last?.time ?? 0
    }

    var totalPoints: Int {
        frames.reduce(0) { $0 + $1.positions.count }
    }

    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = -lo
        for frame in frames {
            for p in frame.positions {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        if frames.isEmpty || lo.x > hi.x { return (.zero, .zero) }
        return (lo, hi)
    }

    /// A single frame as a renderable point mesh (no faces).
    func pointMesh(at index: Int) -> MeshData {
        guard frames.indices.contains(index) else { return MeshData() }
        var mesh = MeshData()
        mesh.positions = frames[index].positions
        mesh.colors = frames[index].colors
        mesh.normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: mesh.positions.count)
        return mesh
    }

    /// Index of the frame nearest to `time` (clamped).
    func frameIndex(at time: Float) -> Int {
        guard !frames.isEmpty else { return 0 }
        var best = 0
        var bestDelta = Float.greatestFiniteMagnitude
        for (i, frame) in frames.enumerated() {
            let delta = abs(frame.time - time)
            if delta < bestDelta {
                bestDelta = delta
                best = i
            }
        }
        return best
    }

    // MARK: - Serialization ("CATMOM01")

    private static let magic: [UInt8] = Array("CATMOM01".utf8)

    func serialized() -> Data {
        var data = Data()
        data.reserveCapacity(totalPoints * 16 + frames.count * 16 + 16)
        data.append(contentsOf: Self.magic)
        data.appendValue(UInt32(frames.count))
        for frame in frames {
            data.appendValue(frame.time)
            data.appendValue(UInt32(frame.positions.count))
            data.appendArray(MeshData.flatten(frame.positions))
            data.appendArray(frame.colors)
        }
        return data
    }

    static func load(from url: URL) throws -> MomentClip {
        try load(from: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func load(from data: Data) throws -> MomentClip {
        guard data.count >= 12, Array(data.prefix(8)) == magic else {
            throw MeshSerializationError.badHeader
        }
        var offset = 8
        let frameCount = Int(try data.readValue(at: &offset) as UInt32)
        guard frameCount < 10_000 else { throw MeshSerializationError.truncated }
        var frames: [MomentFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let time: Float = try data.readValue(at: &offset)
            let pointCount = Int(try data.readValue(at: &offset) as UInt32)
            guard pointCount < 4_000_000 else { throw MeshSerializationError.truncated }
            let flat: [Float] = try data.readArray(at: &offset, count: pointCount * 3)
            let colors: [SIMD4<UInt8>] = try data.readArray(at: &offset, count: pointCount)
            frames.append(MomentFrame(time: time,
                                      positions: MeshData.unflatten(flat),
                                      colors: colors))
        }
        return MomentClip(frames: frames)
    }
}
