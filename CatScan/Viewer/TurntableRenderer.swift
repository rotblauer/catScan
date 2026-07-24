import AVFoundation
import CoreVideo
import Metal
import Observation
import SceneKit
import UIKit

enum TurntableError: LocalizedError {
    case renderFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "Rendering the turntable failed."
        case .writerFailed(let detail): return "Couldn't write the video: \(detail)"
        }
    }
}

/// Renders an offscreen 360° spin of a mesh into an H.264 movie, suitable for
/// saving to the photo library.
@Observable
final class TurntableRenderer {
    var progress: Double = 0

    @ObservationIgnored private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func render(mesh: MeshData,
                size: CGSize = CGSize(width: 1080, height: 1080),
                duration: Double = 6,
                fps: Int = 30) async throws -> URL {
        let frameCount = Int(duration * Double(fps))
        let (scene, pivot, camera) = SceneKitSupport.makeScene(mesh: mesh, mode: .shaded)
        scene.background.contents = AppGradients.viewerBackground(dark: true)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatScan-turntable-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        guard writer.canAdd(input) else { throw TurntableError.writerFailed("incompatible input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw TurntableError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            if cancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }

            pivot.eulerAngles.y = Float(frame) / Float(frameCount) * 2 * .pi
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)
            guard let cgImage = image.cgImage else { throw TurntableError.renderFailed }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw TurntableError.renderFailed }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { throw TurntableError.renderFailed }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                       width: Int(size.width),
                                       height: Int(size.height),
                                       bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))

            let fraction = Double(frame + 1) / Double(frameCount)
            await MainActor.run { self.progress = fraction }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TurntableError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return url
    }
}
