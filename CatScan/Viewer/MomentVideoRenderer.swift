import Metal
import Observation
import SceneKit
import UIKit
import simd

/// Renders a Moment's "spatial replay": the volumetric clip plays back while
/// the camera slowly orbits it — a shareable video of a moving 3D capture
/// seen from angles the phone never stood at.
@Observable
final class MomentVideoRenderer {
    var progress: Double = 0

    @ObservationIgnored private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func render(clip: MomentClip,
                size: CGSize = CGSize(width: 1080, height: 1080),
                fps: Int = 30,
                loops: Int = 2) async throws -> URL {
        guard !clip.frames.isEmpty else { throw VideoWriterError.renderFailed }

        let scene = SCNScene()
        scene.background.contents = AppGradients.viewerBackground(dark: true)

        let (lo, hi) = clip.bounds()
        let center = (lo + hi) * 0.5
        let pointNode = SCNNode()
        pointNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(pointNode)

        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let radius = max(0.15, simd_length(hi - lo) * 0.5)
        let distance = radius / tan(Float(camera.fieldOfView) * .pi / 360) * 1.2
        let elevation: Float = 0.32

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode

        let playDuration = max(1.5, Double(clip.duration)) * Double(max(1, loops))
        let frameCount = Int(playDuration * Double(fps))
        var lastClipFrame = -1

        return try await VideoWriter.write(frameCount: frameCount,
                                           fps: fps,
                                           size: size,
                                           isCancelled: { self.cancelled },
                                           progress: { fraction in
                                               Task { @MainActor in self.progress = fraction }
                                           },
                                           renderFrame: { frame in
                                               let t = Float(Double(frame) / Double(fps))
                                               let clipTime = clip.duration > 0
                                                   ? t.truncatingRemainder(dividingBy: max(0.001, clip.duration))
                                                   : 0
                                               let clipFrame = clip.frameIndex(at: clipTime)
                                               if clipFrame != lastClipFrame {
                                                   lastClipFrame = clipFrame
                                                   pointNode.geometry = SceneKitSupport.geometry(for: clip.pointMesh(at: clipFrame),
                                                                                                 mode: .points)
                                               }
                                               let azimuth = Float(frame) / Float(frameCount) * 2 * .pi
                                               cameraNode.position = SCNVector3(distance * sin(azimuth) * cos(elevation),
                                                                                distance * sin(elevation),
                                                                                distance * cos(azimuth) * cos(elevation))
                                               cameraNode.look(at: SCNVector3Zero)
                                               return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)
                                           })
    }
}
