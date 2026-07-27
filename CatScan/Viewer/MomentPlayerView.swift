import SceneKit
import SwiftUI
import simd

/// Plays a volumetric Moment: the clip's point-cloud frames advance at capture
/// rate while the user freely orbits with the standard camera gestures.
struct MomentPlayerView: View {
    let clip: MomentClip
    let colorScheme: ColorScheme
    let proxy: SCNViewProxy

    @State private var frameIndex = 0
    @State private var isPlaying = true

    var body: some View {
        MomentSceneView(clip: clip,
                        frameIndex: frameIndex,
                        colorScheme: colorScheme,
                        proxy: proxy)
            .ignoresSafeArea(edges: .bottom)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / 15))
                    if isPlaying, !clip.frames.isEmpty {
                        frameIndex = (frameIndex + 1) % clip.frames.count
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { transport }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 34, height: 34)
            }
            Slider(value: Binding(get: { Double(frameIndex) },
                                  set: { newValue in
                                      isPlaying = false
                                      frameIndex = min(clip.frames.count - 1, max(0, Int(newValue)))
                                  }),
                   in: 0...Double(max(1, clip.frames.count - 1)),
                   step: 1)
            Text(String(format: "%.1f / %.1f s",
                        clip.frames.indices.contains(frameIndex) ? clip.frames[frameIndex].time : 0,
                        clip.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

private struct MomentSceneView: UIViewRepresentable {
    let clip: MomentClip
    let frameIndex: Int
    let colorScheme: ColorScheme
    let proxy: SCNViewProxy

    final class Coordinator {
        var pointNode: SCNNode?
        var lastFrame = -1
        var lastScheme: ColorScheme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        scene.background.contents = AppGradients.viewerBackground(dark: colorScheme == .dark)

        let (lo, hi) = clip.bounds()
        let center = (lo + hi) * 0.5
        let pointNode = SCNNode()
        pointNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(pointNode)

        let camera = SceneKitSupport.makeCamera(extent: hi - lo)
        scene.rootNode.addChildNode(camera)

        view.scene = scene
        view.pointOfView = camera
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .clear

        context.coordinator.pointNode = pointNode
        context.coordinator.lastScheme = colorScheme
        proxy.scnView = view
        proxy.homeTransform = camera.transform
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastFrame != frameIndex {
            coordinator.lastFrame = frameIndex
            coordinator.pointNode?.geometry = SceneKitSupport.geometry(for: clip.pointMesh(at: frameIndex),
                                                                       mode: .points)
        }
        if coordinator.lastScheme != colorScheme {
            coordinator.lastScheme = colorScheme
            view.scene?.background.contents = AppGradients.viewerBackground(dark: colorScheme == .dark)
        }
    }
}
