import ARKit
import Foundation
import Observation
import QuartzCore
import UIKit

/// Owns the ARSession for a scanning run: collects mesh anchors, feeds the
/// color sampler, and drives the post-scan processing pipeline.
///
/// Threading model: ARKit delegate callbacks arrive on `sessionQueue`; all
/// observable UI state is only mutated on the main queue.
@Observable
final class ScanSessionController: NSObject, ARSessionDelegate {

    enum Phase: Equatable {
        case ready
        case scanning
        case processing(stage: String, progress: Double)
        case failed(message: String, isCameraDenied: Bool)
    }

    struct LiveStats: Equatable {
        var anchorCount = 0
        var vertexCount = 0
        var faceCount = 0
        var elapsed: TimeInterval = 0
        var colorCellCount = 0
    }

    var phase: Phase = .ready
    var stats = LiveStats()
    var trackingWarning: String?
    var torchOn = false
    var finishedDocument: ScanDocument?
    /// UI mirror of the overlay's mode (the source of truth lives on the
    /// session queue inside `overlay`).
    var overlayMode: MeshOverlayRenderer.Mode = .mesh

    @ObservationIgnored let overlay = MeshOverlayRenderer()
    @ObservationIgnored let session = ARSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "dev.catscan.arsession", qos: .userInitiated)

    // Session-queue-only state.
    @ObservationIgnored private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    @ObservationIgnored private let colorStore = SpatialColorStore()
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var captureStarted: Date?
    @ObservationIgnored private var lastColorPass: TimeInterval = 0
    @ObservationIgnored private var lastOverlaySweep: TimeInterval = 0
    @ObservationIgnored private var lastStatsPush: TimeInterval = 0

    // Configured before the session starts.
    @ObservationIgnored var colorizeEnabled = true
    @ObservationIgnored var classifyEnabled = true
    @ObservationIgnored var simplifyCellSize: Float?

    // MARK: - Session lifecycle

    func startSession() {
        guard DeviceSupport.supportsLiDARScanning else { return }
        session.delegateQueue = sessionQueue
        session.delegate = self
        session.run(makeConfiguration())
    }

    func stopSession() {
        session.pause()
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        if classifyEnabled, DeviceSupport.supportsClassification {
            configuration.sceneReconstruction = .meshWithClassification
        } else {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        configuration.environmentTexturing = .none
        configuration.worldAlignment = .gravity
        return configuration
    }

    func applySettingsAndRestart(colorize: Bool, classify: Bool, simplifyCell: Float?) {
        guard phase == .ready else { return }
        colorizeEnabled = colorize
        classifyEnabled = classify
        simplifyCellSize = simplifyCell
        if overlayMode == .coverage, !colorize {
            overlayMode = .mesh
        }
        let mode = overlayMode
        sessionQueue.async {
            self.meshAnchors.removeAll()
            self.colorStore.removeAll()
            self.overlay.clear()
            self.overlay.setMode(mode, anchors: [], store: self.colorStore)
        }
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
    }

    /// Cycles Off → Mesh → Coverage (skipping Coverage when color capture is off).
    func cycleOverlayMode() {
        var next = overlayMode.next
        if next == .coverage, !colorizeEnabled {
            next = .off
        }
        overlayMode = next
        Haptics.impact(.light)
        sessionQueue.async {
            self.overlay.setMode(next, anchors: Array(self.meshAnchors.values), store: self.colorStore)
        }
    }

    // MARK: - Scan control

    func beginScan() {
        Haptics.impact(.medium)
        phase = .scanning
        stats = LiveStats()
        sessionQueue.async {
            self.isCapturing = true
            self.captureStarted = Date()
        }
    }

    func resetScan() {
        Haptics.impact(.light)
        stats = LiveStats()
        sessionQueue.async {
            self.meshAnchors.removeAll()
            self.colorStore.removeAll()
            self.overlay.clear()
            if self.isCapturing { self.captureStarted = Date() }
        }
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
    }

    func retryAfterFailure() {
        phase = .ready
        stats = LiveStats()
        trackingWarning = nil
        sessionQueue.async {
            self.isCapturing = false
            self.captureStarted = nil
            self.meshAnchors.removeAll()
            self.colorStore.removeAll()
            self.overlay.clear()
        }
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
    }

    func finishScan(store: ScanStore) {
        Haptics.impact(.heavy)
        phase = .processing(stage: "Capturing mesh", progress: 0.02)

        // Grab the relocalization map before pausing — groundwork for scan
        // diffing: any two scans with maps can later share a coordinate frame.
        session.getCurrentWorldMap { [weak self] worldMap, _ in
            guard let self else { return }
            let mapData = worldMap.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
            DispatchQueue.main.async {
                self.captureAndProcess(store: store, worldMapData: mapData)
            }
        }
    }

    private func captureAndProcess(store: ScanStore, worldMapData: Data?) {
        session.pause()
        torchOn = false

        sessionQueue.async { [self] in
            isCapturing = false
            let captured = meshAnchors.values.map { CapturedAnchorMesh(anchor: $0) }
            let duration = captureStarted.map { Date().timeIntervalSince($0) } ?? 0
            let colors: SpatialColorStore? = colorizeEnabled ? colorStore : nil
            let simplifyCell = simplifyCellSize

            guard captured.contains(where: { !$0.indices.isEmpty }) else {
                DispatchQueue.main.async {
                    self.phase = .failed(message: "No mesh was captured. Point the camera at your surroundings and move around for a few seconds before finishing.",
                                         isCameraDenied: false)
                }
                return
            }

            Task.detached(priority: .userInitiated) {
                await self.processAndSave(captured: captured,
                                          colorStore: colors,
                                          simplifyCell: simplifyCell,
                                          duration: duration,
                                          worldMapData: worldMapData,
                                          store: store)
            }
        }
    }

    // MARK: - Processing

    private static let stageSpans: [ProcessingStage: (start: Double, span: Double)] = [
        .merging: (0.05, 0.15),
        .welding: (0.20, 0.15),
        .coloring: (0.35, 0.30),
        .cleaning: (0.65, 0.08),
        .normals: (0.73, 0.10),
        .simplifying: (0.83, 0.05),
    ]

    private func processAndSave(captured: [CapturedAnchorMesh],
                                colorStore: SpatialColorStore?,
                                simplifyCell: Float?,
                                duration: TimeInterval,
                                worldMapData: Data?,
                                store: ScanStore) async {
        var lastReported = -1.0
        let (mesh, colorFraction) = MeshBuilder.process(anchors: captured,
                                                        colorStore: colorStore,
                                                        simplifyCellSize: simplifyCell) { stage, fraction in
            let (start, span) = Self.stageSpans[stage] ?? (0.5, 0.1)
            let overall = start + span * min(1, max(0, fraction))
            guard overall - lastReported > 0.01 else { return }
            lastReported = overall
            let label = stage.label
            Task { @MainActor in
                self.phase = .processing(stage: label, progress: overall)
            }
        }

        guard mesh.faceCount > 0 else {
            await MainActor.run {
                self.phase = .failed(message: "The captured mesh was empty after cleanup. Try scanning for a bit longer.",
                                     isCameraDenied: false)
            }
            return
        }

        await MainActor.run {
            self.phase = .processing(stage: "Rendering preview", progress: 0.90)
        }
        let thumbnail = SceneKitSupport.renderThumbnail(mesh: mesh, size: CGSize(width: 640, height: 640))

        await MainActor.run {
            self.phase = .processing(stage: "Saving scan", progress: 0.96)
        }
        do {
            let name = "Scan " + Date().formatted(date: .abbreviated, time: .shortened)
            let document = try await store.save(mesh: mesh,
                                                name: name,
                                                duration: duration,
                                                colorFraction: colorFraction,
                                                worldMap: worldMapData,
                                                thumbnail: thumbnail)
            await MainActor.run {
                self.finishedDocument = document
            }
        } catch {
            await MainActor.run {
                self.phase = .failed(message: "Couldn't save the scan: \(error.localizedDescription)",
                                     isCameraDenied: false)
            }
        }
    }

    // MARK: - Torch

    var torchAvailable: Bool {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera?.hasTorch ?? false
    }

    func toggleTorch() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if torchOn {
                device.torchMode = .off
            } else {
                try device.setTorchModeOn(level: 1.0)
            }
            device.unlockForConfiguration()
            torchOn.toggle()
        } catch {
            // Torch is best-effort; ignore failures.
        }
    }

    // MARK: - ARSessionDelegate (session queue)

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            meshAnchors.removeValue(forKey: anchor.identifier)
            overlay.remove(id: anchor.identifier)
        }
    }

    private func ingest(_ anchors: [ARAnchor]) {
        var changed = false
        for case let meshAnchor as ARMeshAnchor in anchors {
            meshAnchors[meshAnchor.identifier] = meshAnchor
            overlay.update(anchor: meshAnchor, store: colorStore)
            changed = true
        }
        if changed { pushStatsIfNeeded() }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        if colorizeEnabled, frame.timestamp - lastColorPass >= 0.25 {
            lastColorPass = frame.timestamp
            DepthColorSampler.integrate(frame: frame, into: colorStore)
        }
        if frame.timestamp - lastOverlaySweep >= 1.0 {
            lastOverlaySweep = frame.timestamp
            overlay.sweep(anchors: Array(meshAnchors.values), store: colorStore)
        }
        pushStatsIfNeeded()
    }

    private func pushStatsIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastStatsPush >= 0.25 else { return }
        lastStatsPush = now

        var snapshot = LiveStats()
        snapshot.anchorCount = meshAnchors.count
        for anchor in meshAnchors.values {
            snapshot.vertexCount += anchor.geometry.vertices.count
            snapshot.faceCount += anchor.geometry.faces.count
        }
        snapshot.colorCellCount = colorStore.count
        snapshot.elapsed = captureStarted.map { Date().timeIntervalSince($0) } ?? 0

        DispatchQueue.main.async {
            self.stats = snapshot
        }
    }

    // MARK: - ARSessionObserver

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let warning: String?
        switch camera.trackingState {
        case .normal:
            warning = nil
        case .notAvailable:
            warning = "Tracking unavailable"
        case .limited(.excessiveMotion):
            warning = "Slow down a little"
        case .limited(.insufficientFeatures):
            warning = "Add more light or texture"
        case .limited(.initializing):
            warning = "Getting ready…"
        case .limited(.relocalizing):
            warning = "Re-finding position…"
        case .limited:
            warning = "Limited tracking"
        }
        DispatchQueue.main.async {
            self.trackingWarning = warning
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.trackingWarning = "Session interrupted"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            self.trackingWarning = nil
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let isDenied = (error as NSError).code == ARError.Code.cameraUnauthorized.rawValue
        let message = isDenied
            ? "CatScan needs camera access to scan. You can enable it in Settings."
            : error.localizedDescription
        DispatchQueue.main.async {
            self.phase = .failed(message: message, isCameraDenied: isDenied)
        }
    }
}
