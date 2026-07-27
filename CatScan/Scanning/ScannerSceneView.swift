import ARKit
import SceneKit
import SwiftUI

/// Hosts the ARSCNView that shows the camera feed plus our recolorable mesh
/// overlay (wireframe or color-coverage heatmap). ARSCNView renders the camera
/// background and tracks the device pose on its own; anchor visualization is
/// driven by ScanSessionController through MeshOverlayRenderer, so the
/// controller stays the session's delegate.
struct ScannerSceneView: UIViewRepresentable {
    let controller: ScanSessionController
    let colorize: Bool
    let classify: Bool
    let simplifyCell: Float?
    let scanMode: ScanMode
    let detailVolume: DetailVolume
    var referenceScan: ScanDocument?
    var referenceWorldMapURL: URL?
    var referenceMeshURL: URL?

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = controller.session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.scene.rootNode.addChildNode(controller.overlay.rootNode)

        controller.colorizeEnabled = colorize
        controller.classifyEnabled = classify
        controller.simplifyCellSize = simplifyCell
        controller.scanMode = scanMode
        controller.detailVolume = detailVolume
        if let referenceScan, let referenceWorldMapURL, let referenceMeshURL {
            controller.loadReference(scan: referenceScan,
                                     worldMapURL: referenceWorldMapURL,
                                     meshURL: referenceMeshURL)
        }
        controller.startSession()

        let coaching = ARCoachingOverlayView()
        coaching.session = controller.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}
