import Observation
import SceneKit
import SwiftUI
import simd

/// Composes a spatial replay by direct manipulation: the preview plays the
/// clip live, dragging orbits the framing, and a **flick** sets the video's
/// spin — the flick direction becomes the rotation axis, its strength the
/// speed. Grabbing the preview stops the spin (tripod shot); a slider offers
/// fine speed control. What the preview does is exactly what exports.
struct ReplayComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let clip: MomentClip
    let onExport: (ReplayCameraPath, Int) -> Void

    @State private var model: ReplayComposerModel

    init(clip: MomentClip, onExport: @escaping (ReplayCameraPath, Int) -> Void) {
        self.clip = clip
        self.onExport = onExport
        _model = State(initialValue: ReplayComposerModel(clip: clip))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ReplayPreview(clip: clip, model: model)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                VStack(spacing: 10) {
                    HStack {
                        Label(spinDescription, systemImage: model.degreesPerSecond > 0.01 ? "rotate.3d" : "camera.on.rectangle")
                            .font(.footnote.weight(.medium))
                        Spacer()
                        Button("No Spin") {
                            model.degreesPerSecond = 0
                        }
                        .font(.footnote)
                        .disabled(model.degreesPerSecond < 0.01)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "tortoise")
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(model.degreesPerSecond) },
                                              set: { model.degreesPerSecond = Float($0) }),
                               in: 0...120)
                        Image(systemName: "hare")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Video length", selection: $model.loops) {
                        Text("1 loop").tag(1)
                        Text("2 loops").tag(2)
                        Text("3 loops").tag(3)
                    }
                    .pickerStyle(.segmented)

                    Text("Drag to frame the shot · flick to set the spin — its direction becomes the rotation axis · pinch to zoom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle("Spatial Replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        let path = model.makePath()
                        dismiss()
                        onExport(path, model.loops)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var spinDescription: String {
        guard model.degreesPerSecond > 0.01 else { return "Locked view — no spin" }
        let axisKind = abs(simd_dot(model.axis, SIMD3<Float>(0, 1, 0))) > 0.92 ? "Turntable" : "Custom axis"
        return String(format: "%@ · %.0f°/s", axisKind, model.degreesPerSecond)
    }
}

// MARK: - Shared composer state

@Observable
final class ReplayComposerModel {
    var degreesPerSecond: Float = 40
    var axis = SIMD3<Float>(0, 1, 0)
    var loops = 2

    /// Live camera framing, maintained by the preview's coordinator.
    @ObservationIgnored var center: SIMD3<Float>
    @ObservationIgnored var offset: SIMD3<Float>
    @ObservationIgnored var up: SIMD3<Float>
    @ObservationIgnored let fitDistance: Float

    init(clip: MomentClip) {
        let standard = ReplayCameraPath.standard(for: clip)
        center = standard.center
        offset = standard.startOffset
        up = standard.up
        fitDistance = simd_length(standard.startOffset)
    }

    func makePath() -> ReplayCameraPath {
        ReplayCameraPath(center: center,
                         startOffset: offset,
                         up: up,
                         axis: axis,
                         degreesPerSecond: degreesPerSecond)
    }
}

// MARK: - Live preview

private struct ReplayPreview: UIViewRepresentable {
    let clip: MomentClip
    let model: ReplayComposerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(clip: clip, model: model)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
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

        view.scene = scene
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling2X
        view.rendersContinuously = true
        view.pointOfView = cameraNode

        let coordinator = context.coordinator
        coordinator.pointNode = pointNode
        coordinator.cameraNode = cameraNode
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        private let clip: MomentClip
        private let model: ReplayComposerModel

        var pointNode: SCNNode?
        var cameraNode: SCNNode?

        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval = 0
        private var clipTime: Float = 0
        private var lastClipFrame = -1

        private static let dragRadiansPerPoint: Float = 0.008
        private static let flickDegreesPerVelocityPoint: Float = 0.14
        private static let flickThreshold: Float = 120

        init(clip: MomentClip, model: ReplayComposerModel) {
            self.clip = clip
            self.model = model
        }

        func attach(to view: SCNView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            view.addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)

            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = CACurrentMediaTime()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            let dt = Float(min(0.1, now - lastTick))
            lastTick = now

            if model.degreesPerSecond > 0.01 {
                let rotation = simd_quatf(angle: model.degreesPerSecond * .pi / 180 * dt, axis: model.axis)
                model.offset = rotation.act(model.offset)
                model.up = simd_normalize(rotation.act(model.up))
            }

            if !clip.frames.isEmpty {
                clipTime += dt
                let span = max(0.2, clip.duration + 1.0 / 15)
                if clipTime > span { clipTime = 0 }
                let frame = clip.frameIndex(at: min(clipTime, clip.duration))
                if frame != lastClipFrame {
                    lastClipFrame = frame
                    pointNode?.geometry = SceneKitSupport.geometry(for: clip.pointMesh(at: frame), mode: .points)
                }
            }

            guard let cameraNode else { return }
            let position = model.center + model.offset
            cameraNode.simdPosition = position
            cameraNode.look(at: SCNVector3(model.center.x, model.center.y, model.center.z),
                            up: SCNVector3(model.up.x, model.up.y, model.up.z),
                            localFront: SCNVector3(0, 0, -1))
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                // Grabbing the scene stops any spin — release with a flick to restart it.
                model.degreesPerSecond = 0
            case .changed:
                let translation = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                rotateFraming(dx: Float(translation.x), dy: Float(translation.y))
            case .ended:
                let velocity = gesture.velocity(in: view)
                let speed = Float(hypot(velocity.x, velocity.y))
                guard speed > Self.flickThreshold else { return }
                // The flick's rotation vector: horizontal motion spins about the
                // current up axis, vertical about the current right axis. Their
                // blend IS the user-defined axis, frozen in world space.
                let forward = simd_normalize(-model.offset)
                let right = simd_normalize(simd_cross(forward, model.up))
                let omega = model.up * (-Float(velocity.x)) + right * Float(velocity.y)
                let magnitude = simd_length(omega)
                guard magnitude > 1e-3 else { return }
                model.axis = omega / magnitude
                model.degreesPerSecond = min(120, magnitude * Self.flickDegreesPerVelocityPoint)
            default:
                break
            }
        }

        private func rotateFraming(dx: Float, dy: Float) {
            let forward = simd_normalize(-model.offset)
            let right = simd_normalize(simd_cross(forward, model.up))
            let yaw = simd_quatf(angle: -dx * Self.dragRadiansPerPoint, axis: model.up)
            let pitch = simd_quatf(angle: dy * Self.dragRadiansPerPoint, axis: right)
            let combined = yaw * pitch
            model.offset = combined.act(model.offset)
            model.up = simd_normalize(combined.act(model.up))
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .changed else { return }
            let scale = Float(gesture.scale)
            gesture.scale = 1
            guard scale > 0.01 else { return }
            let length = simd_length(model.offset) / scale
            let clamped = min(model.fitDistance * 4, max(model.fitDistance * 0.35, length))
            model.offset = simd_normalize(model.offset) * clamped
        }
    }
}
