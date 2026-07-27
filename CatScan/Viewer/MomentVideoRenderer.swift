import Metal
import Observation
import SceneKit
import UIKit
import simd

/// A user-composed camera move for a spatial replay: start from a framed
/// viewpoint and rotate around the subject about an arbitrary world axis at a
/// constant rate (0°/s = locked tripod shot). Quaternion-based, so tilted
/// axes and over-the-top orbits behave with no gimbal surprises — the up
/// vector rides the same rotation.
struct ReplayCameraPath {
    var center: SIMD3<Float>
    /// Camera position minus center at t = 0.
    var startOffset: SIMD3<Float>
    var up: SIMD3<Float>
    /// Unit rotation axis in world space (ignored when the rate is 0).
    var axis: SIMD3<Float>
    var degreesPerSecond: Float

    func cameraPose(at time: Float) -> (position: SIMD3<Float>, up: SIMD3<Float>) {
        guard abs(degreesPerSecond) > 0.01 else {
            return (center + startOffset, up)
        }
        let rotation = simd_quatf(angle: degreesPerSecond * .pi / 180 * time, axis: axis)
        return (center + rotation.act(startOffset), rotation.act(up))
    }

    /// A gentle default turntable framing the whole clip.
    static func standard(for clip: MomentClip, degreesPerSecond: Float = 40) -> ReplayCameraPath {
        let (lo, hi) = clip.bounds()
        let center = (lo + hi) * 0.5
        let radius = max(0.15, simd_length(hi - lo) * 0.5)
        let distance = radius / tan(55 * .pi / 360) * 1.2
        let azimuth: Float = 0.5
        let elevation: Float = 0.32
        let offset = SIMD3<Float>(distance * sin(azimuth) * cos(elevation),
                                  distance * sin(elevation),
                                  distance * cos(azimuth) * cos(elevation))
        return ReplayCameraPath(center: center,
                                startOffset: offset,
                                up: SIMD3(0, 1, 0),
                                axis: SIMD3(0, 1, 0),
                                degreesPerSecond: degreesPerSecond)
    }
}

/// Renders a Moment's "spatial replay": the volumetric clip plays back while
/// the camera follows a user-composed path — footage from angles the phone
/// never stood at.
@Observable
final class MomentVideoRenderer {
    var progress: Double = 0

    @ObservationIgnored private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func render(clip: MomentClip,
                path: ReplayCameraPath,
                size: CGSize = CGSize(width: 1080, height: 1080),
                fps: Int = 30,
                loops: Int = 2) async throws -> URL {
        guard !clip.frames.isEmpty else { throw VideoWriterError.renderFailed }

        let scene = SCNScene()
        scene.background.contents = AppGradients.viewerBackground(dark: true)

        let pointNode = SCNNode()
        scene.rootNode.addChildNode(pointNode)

        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

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
                                               let pose = path.cameraPose(at: t)
                                               cameraNode.simdPosition = pose.position
                                               cameraNode.look(at: SCNVector3(path.center.x, path.center.y, path.center.z),
                                                               up: SCNVector3(pose.up.x, pose.up.y, pose.up.z),
                                                               localFront: SCNVector3(0, 0, -1))
                                               return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)
                                           })
    }
}
