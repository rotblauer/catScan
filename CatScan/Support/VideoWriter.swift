import AVFoundation
import CoreVideo
import UIKit

enum VideoWriterError: LocalizedError {
    case renderFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "Rendering the video failed."
        case .writerFailed(let detail): return "Couldn't write the video: \(detail)"
        }
    }
}

/// Shared H.264 writing loop for offscreen-rendered videos (turntables,
/// Moment spatial replays). The caller supplies a frame renderer; frames are
/// pulled sequentially and appended with exact timestamps.
enum VideoWriter {

    static func write(frameCount: Int,
                      fps: Int,
                      size: CGSize,
                      isCancelled: () -> Bool,
                      progress: (Double) -> Void,
                      renderFrame: (Int) -> UIImage?) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatScan-video-\(UUID().uuidString).mp4")

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
        guard writer.canAdd(input) else { throw VideoWriterError.writerFailed("incompatible input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoWriterError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            if isCancelled() {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            guard let image = renderFrame(frame), let cgImage = image.cgImage else {
                throw VideoWriterError.renderFailed
            }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw VideoWriterError.renderFailed }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { throw VideoWriterError.renderFailed }

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
            progress(Double(frame + 1) / Double(frameCount))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoWriterError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return url
    }
}
