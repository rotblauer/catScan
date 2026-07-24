import Foundation
import simd

/// Builds a colorful procedural "yarn ball" (a trefoil-knot tube) so the
/// viewer, exporters, and Photos features can be exercised on devices
/// without LiDAR — and in the simulator.
enum SampleMeshFactory {

    static func yarnBall() -> MeshData {
        let pathSteps = 720
        let ringSteps = 36
        let scale: Float = 0.055
        let tubeRadius: Float = 0.062

        // Trefoil knot centerline.
        func curve(_ t: Float) -> SIMD3<Float> {
            SIMD3(sin(t) + 2 * sin(2 * t),
                  cos(t) - 2 * cos(2 * t),
                  -sin(3 * t)) * scale
        }

        let twoPi = Float.pi * 2
        var centers = [SIMD3<Float>](repeating: .zero, count: pathSteps)
        var tangents = [SIMD3<Float>](repeating: .zero, count: pathSteps)
        for i in 0..<pathSteps {
            let t = twoPi * Float(i) / Float(pathSteps)
            centers[i] = curve(t)
            let dt: Float = 0.002
            tangents[i] = simd_normalize(curve(t + dt) - curve(t - dt))
        }

        // Parallel-transport frames along the closed curve.
        var normalsFrame = [SIMD3<Float>](repeating: .zero, count: pathSteps)
        var binormals = [SIMD3<Float>](repeating: .zero, count: pathSteps)
        var n = simd_normalize(anyPerpendicular(to: tangents[0]))
        for i in 0..<pathSteps {
            let t = tangents[i]
            n = n - t * simd_dot(t, n)
            if simd_length(n) < 1e-5 { n = anyPerpendicular(to: t) }
            n = simd_normalize(n)
            normalsFrame[i] = n
            binormals[i] = simd_normalize(simd_cross(t, n))
        }

        // Correct the closing twist so the seam is invisible: transport the last
        // frame one more step onto tangent 0 and measure the mismatch angle.
        var closing = normalsFrame[pathSteps - 1]
        let t0 = tangents[0]
        closing = simd_normalize(closing - t0 * simd_dot(t0, closing))
        let mismatch = atan2(simd_dot(simd_cross(closing, normalsFrame[0]), t0),
                             simd_dot(closing, normalsFrame[0]))
        for i in 0..<pathSteps {
            let correction = -mismatch * Float(i) / Float(pathSteps)
            let (c, s) = (cos(correction), sin(correction))
            let nn = normalsFrame[i] * c + binormals[i] * s
            let bb = binormals[i] * c - normalsFrame[i] * s
            normalsFrame[i] = nn
            binormals[i] = bb
        }

        var mesh = MeshData()
        mesh.positions.reserveCapacity(pathSteps * ringSteps)
        mesh.normals.reserveCapacity(pathSteps * ringSteps)
        mesh.colors.reserveCapacity(pathSteps * ringSteps)

        for i in 0..<pathSteps {
            let t = twoPi * Float(i) / Float(pathSteps)
            for j in 0..<ringSteps {
                let a = twoPi * Float(j) / Float(ringSteps)
                let radial = normalsFrame[i] * cos(a) + binormals[i] * sin(a)
                // Slight ridging so it reads as wound yarn strands.
                let r = tubeRadius * (1 + 0.05 * sin(a * 7 + t * 5))
                mesh.positions.append(centers[i] + radial * r)
                mesh.normals.append(radial)

                let hue = fract(2.5 * t / twoPi + 0.03 * sin(a * 3))
                let brightness = 0.88 + 0.08 * sin(a * 9 + t * 6)
                let rgb = hsbToRGB(h: hue, s: 0.44, b: brightness)
                mesh.colors.append(SIMD4(UInt8(rgb.x * 255), UInt8(rgb.y * 255), UInt8(rgb.z * 255), 255))
            }
        }

        mesh.indices.reserveCapacity(pathSteps * ringSteps * 6)
        for i in 0..<pathSteps {
            let iNext = (i + 1) % pathSteps
            for j in 0..<ringSteps {
                let jNext = (j + 1) % ringSteps
                let a = UInt32(i * ringSteps + j)
                let b = UInt32(iNext * ringSteps + j)
                let c = UInt32(iNext * ringSteps + jNext)
                let d = UInt32(i * ringSteps + jNext)
                mesh.indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        // Lift it so it "sits" like a scanned object (center roughly at origin height).
        let (lo, _) = mesh.bounds()
        for i in 0..<mesh.positions.count {
            mesh.positions[i].y -= lo.y
        }
        return mesh
    }

    private static func anyPerpendicular(to v: SIMD3<Float>) -> SIMD3<Float> {
        let candidate = abs(v.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        return simd_normalize(simd_cross(v, candidate))
    }

    private static func fract(_ x: Float) -> Float {
        x - floor(x)
    }

    private static func hsbToRGB(h: Float, s: Float, b: Float) -> SIMD3<Float> {
        let h6 = fract(h) * 6
        let i = Int(h6) % 6
        let f = h6 - Float(Int(h6))
        let p = b * (1 - s)
        let q = b * (1 - f * s)
        let t = b * (1 - (1 - f) * s)
        switch i {
        case 0: return SIMD3(b, t, p)
        case 1: return SIMD3(q, b, p)
        case 2: return SIMD3(p, b, t)
        case 3: return SIMD3(p, q, b)
        case 4: return SIMD3(t, p, b)
        default: return SIMD3(b, p, q)
        }
    }
}
