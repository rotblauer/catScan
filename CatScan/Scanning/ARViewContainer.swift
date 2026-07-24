import ARKit
import RealityKit
import SwiftUI

/// Hosts the RealityKit ARView that visualizes the live reconstruction mesh.
struct ARViewContainer: UIViewRepresentable {
    let controller: ScanSessionController
    let colorize: Bool
    let classify: Bool
    let simplifyCell: Float?

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = controller.session
        view.debugOptions.insert(.showSceneUnderstanding)
        view.renderOptions.formUnion([.disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain])

        controller.colorizeEnabled = colorize
        controller.classifyEnabled = classify
        controller.simplifyCellSize = simplifyCell
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

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}
