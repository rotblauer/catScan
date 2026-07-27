import Metal
import Observation
import SceneKit
import UIKit

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

        return try await VideoWriter.write(frameCount: frameCount,
                                           fps: fps,
                                           size: size,
                                           isCancelled: { self.cancelled },
                                           progress: { fraction in
                                               Task { @MainActor in self.progress = fraction }
                                           },
                                           renderFrame: { frame in
                                               pivot.eulerAngles.y = Float(frame) / Float(frameCount) * 2 * .pi
                                               return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)
                                           })
    }
}
