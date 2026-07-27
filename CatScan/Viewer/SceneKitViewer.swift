import SceneKit
import SwiftUI

/// Lets SwiftUI reach into the live SCNView for snapshots and camera reset.
final class SCNViewProxy {
    weak var scnView: SCNView?
    var homeTransform = SCNMatrix4Identity

    func snapshot() -> UIImage? {
        scnView?.snapshot()
    }

    func resetCamera() {
        guard let view = scnView, let pov = view.pointOfView else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        pov.transform = homeTransform
        SCNTransaction.commit()
        view.defaultCameraController.target = SCNVector3Zero
    }
}

struct SceneKitViewer: UIViewRepresentable {
    let mesh: MeshData
    let mode: ViewerDisplayMode
    let colorScheme: ColorScheme
    let proxy: SCNViewProxy
    /// Present on rescans: powers the Changes display mode.
    var diff: (added: [Bool], removed: MeshData)?

    final class Coordinator {
        var modelPivot: SCNNode?
        var currentMode: ViewerDisplayMode?
        var currentScheme: ColorScheme?
        var geometryCache: [ViewerDisplayMode: SCNGeometry] = [:]
        var removedGhost: SCNNode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let (scene, pivot, camera) = SceneKitSupport.makeScene(mesh: mesh, mode: mode)
        scene.background.contents = AppGradients.viewerBackground(dark: colorScheme == .dark)
        view.scene = scene
        view.pointOfView = camera
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.inertiaEnabled = true
        view.backgroundColor = .clear

        context.coordinator.modelPivot = pivot
        context.coordinator.currentMode = mode
        context.coordinator.currentScheme = colorScheme
        if let geometry = pivot.childNodes.first?.geometry {
            context.coordinator.geometryCache[mode] = geometry
        }
        proxy.scnView = view
        proxy.homeTransform = camera.transform
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.currentMode != mode {
            coordinator.currentMode = mode
            let geometry: SCNGeometry
            if let cached = coordinator.geometryCache[mode] {
                geometry = cached
            } else if mode == .changes, let diff {
                geometry = SceneKitSupport.changesGeometry(mesh: mesh, addedMask: diff.added)
                coordinator.geometryCache[mode] = geometry
            } else {
                geometry = SceneKitSupport.geometry(for: mesh, mode: mode)
                coordinator.geometryCache[mode] = geometry
            }
            coordinator.modelPivot?.childNodes.first?.geometry = geometry
            updateRemovedGhost(coordinator: coordinator)
        }
        if coordinator.currentScheme != colorScheme {
            coordinator.currentScheme = colorScheme
            view.scene?.background.contents = AppGradients.viewerBackground(dark: colorScheme == .dark)
        }
    }

    /// The red removed-geometry overlay rides along only in Changes mode. It
    /// shares the model node's parent, so the pivot's centering translation
    /// applies to both (the diff lives in the same world frame as the mesh).
    private func updateRemovedGhost(coordinator: Coordinator) {
        if mode == .changes, let diff {
            if coordinator.removedGhost == nil {
                coordinator.removedGhost = SceneKitSupport.removedGhostNode(removed: diff.removed)
                if let ghost = coordinator.removedGhost,
                   let model = coordinator.modelPivot?.childNodes.first {
                    ghost.position = model.position
                }
            }
            if let ghost = coordinator.removedGhost, ghost.parent == nil {
                coordinator.modelPivot?.addChildNode(ghost)
            }
        } else {
            coordinator.removedGhost?.removeFromParentNode()
        }
    }
}
