import Foundation
import simd

/// Metadata for one saved scan. The mesh itself lives in a sibling binary file.
struct ScanDocument: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var duration: TimeInterval
    var vertexCount: Int
    var faceCount: Int
    var surfaceArea: Float
    var boundsMin: [Float]
    var boundsMax: [Float]
    var hasClassification: Bool
    var colorFraction: Float
    var deviceModel: String
    var fileSizeBytes: Int

    var isColored: Bool { colorFraction > 0.01 }

    var extent: SIMD3<Float> {
        guard boundsMin.count == 3, boundsMax.count == 3 else { return .zero }
        return SIMD3(boundsMax[0] - boundsMin[0],
                     boundsMax[1] - boundsMin[1],
                     boundsMax[2] - boundsMin[2])
    }

    var dimensionsString: String {
        let e = extent
        func fmt(_ v: Float) -> String {
            v >= 1 ? String(format: "%.2f m", v) : String(format: "%.0f cm", v * 100)
        }
        return "\(fmt(e.x)) × \(fmt(e.y)) × \(fmt(e.z))"
    }

    var areaString: String {
        String(format: "%.2f m²", surfaceArea)
    }
}
