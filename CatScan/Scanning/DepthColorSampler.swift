import ARKit
import CoreVideo
import simd

/// Converts one ARFrame's LiDAR depth map into colored world-space points and
/// feeds them to a SpatialColorStore. Each depth pixel is unprojected with the
/// camera intrinsics and paired with the camera image color at the same spot.
enum DepthColorSampler {

    /// One frame's colored points, collected instead of integrated — the
    /// capture path for volumetric Moments. `pixelStride` subsamples the depth
    /// map (2 → ~12k points per frame).
    static func collectPoints(frame: ARFrame,
                              pixelStride: Int = 2,
                              maxDepth: Float = 3.0) -> (positions: [SIMD3<Float>], colors: [SIMD4<UInt8>])? {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<UInt8>] = []
        positions.reserveCapacity(16_384)
        colors.reserveCapacity(16_384)
        let collected = withPixels(frame: frame) { point, r, g, b, _, depth in
            if depth <= maxDepth {
                positions.append(point)
                colors.append(SIMD4(r, g, b, 255))
            }
        } stride: { pixelStride }
        guard collected else { return nil }
        return (positions, colors)
    }

    static func integrate(frame: ARFrame, into store: SpatialColorStore) {
        _ = withPixels(frame: frame) { point, r, g, b, quality, _ in
            store.integrate(point: point, r: r, g: g, b: b, quality: quality)
        } stride: { 1 }
    }

    /// Shared unproject-and-color loop. Calls `body` for every valid depth
    /// pixel with the world position, RGB, quality score, and depth. Returns
    /// false when the frame lacks usable depth/image buffers.
    @discardableResult
    private static func withPixels(frame: ARFrame,
                                   body: (SIMD3<Float>, UInt8, UInt8, UInt8, Float, Float) -> Void,
                                   stride pixelStrideProvider: () -> Int) -> Bool {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return false }
        let depthMap = sceneDepth.depthMap
        let image = frame.capturedImage

        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return false }
        let pixelStride = max(1, pixelStrideProvider())
        let imageFormat = CVPixelBufferGetPixelFormatType(image)
        let fullRange: Bool
        switch imageFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: fullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: fullRange = false
        default: return false
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let confidenceMap = sceneDepth.confidenceMap
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0,
              let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return false }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var confBase: UnsafeRawPointer?
        var confRowBytes = 0
        if let confidenceMap, let base = CVPixelBufferGetBaseAddress(confidenceMap) {
            confBase = UnsafeRawPointer(base)
            confRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        }

        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return false }
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // Intrinsics are expressed for the full-resolution captured image;
        // rescale them to depth-map resolution.
        let intrinsics = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution
        let sx = Float(depthWidth) / Float(imageSize.width)
        let sy = Float(depthHeight) / Float(imageSize.height)
        let fx = intrinsics[0][0] * sx
        let fy = intrinsics[1][1] * sy
        let cx = intrinsics[2][0] * sx
        let cy = intrinsics[2][1] * sy
        guard fx > 0, fy > 0 else { return false }
        let cameraTransform = frame.camera.transform

        let imgScaleX = Float(imageWidth) / Float(depthWidth)
        let imgScaleY = Float(imageHeight) / Float(depthHeight)

        for v in Swift.stride(from: 0, to: depthHeight, by: pixelStride) {
            let depthRow = depthBase.advanced(by: v * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confRow = confBase.map { $0.advanced(by: v * confRowBytes).assumingMemoryBound(to: UInt8.self) }
            for u in Swift.stride(from: 0, to: depthWidth, by: pixelStride) {
                let depth = depthRow[u]
                guard depth.isFinite, depth > 0.15, depth < 5.0 else { continue }

                var confidenceWeight: Float = 1
                if let confRow {
                    let confidence = confRow[u]
                    guard confidence >= 1 else { continue }   // skip ARConfidenceLevel.low
                    confidenceWeight = confidence >= 2 ? 1.0 : 0.55
                }

                // Unproject to camera space (ARKit camera: +x right, +y up, -z forward;
                // pixel coordinates have +y down).
                let uf = Float(u) + 0.5
                let vf = Float(v) + 0.5
                let xc = (uf - cx) * depth / fx
                let yc = (vf - cy) * depth / fy
                let world = cameraTransform * SIMD4<Float>(xc, -yc, -depth, 1)

                // Sample the camera image at the matching pixel.
                let px = min(imageWidth - 1, max(0, Int(uf * imgScaleX)))
                let py = min(imageHeight - 1, max(0, Int(vf * imgScaleY)))
                let yValue = Float(luma[py * lumaRowBytes + px])
                let chromaIndex = (py >> 1) * chromaRowBytes + (px >> 1) * 2
                let cb = Float(chroma[chromaIndex]) - 128
                let cr = Float(chroma[chromaIndex + 1]) - 128

                var r: Float, g: Float, b: Float
                if fullRange {
                    r = yValue + 1.402 * cr
                    g = yValue - 0.344136 * cb - 0.714136 * cr
                    b = yValue + 1.772 * cb
                } else {
                    let y1 = 1.1643 * (yValue - 16)
                    r = y1 + 1.5958 * cr
                    g = y1 - 0.39176 * cb - 0.81297 * cr
                    b = y1 + 2.017 * cb
                }

                let quality = confidenceWeight * min(2.5, 1.0 / max(depth, 0.4))
                body(SIMD3(world.x, world.y, world.z),
                     UInt8(min(255, max(0, r))),
                     UInt8(min(255, max(0, g))),
                     UInt8(min(255, max(0, b))),
                     quality,
                     depth)
            }
        }
        return true
    }
}
