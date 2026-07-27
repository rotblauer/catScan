import ARKit
import Foundation
import Observation
import QuartzCore
import UIKit

/// How a scan captures geometry.
enum ScanMode: String, CaseIterable, Identifiable {
    /// ARKit scene reconstruction — whole rooms, ~2–5 cm features.
    case room
    /// Our own TSDF depth fusion inside a bounded box — 4–8 mm features.
    case detail

    var id: String { rawValue }

    var label: String {
        switch self {
        case .room: return "Room"
        case .detail: return "Detail"
        }
    }
}

/// Capture volume for Detail mode. Smaller volume → finer voxels.
enum DetailVolume: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "0.5 m"
        case .medium: return "1 m"
        case .large: return "2 m"
        }
    }

    var note: String {
        switch self {
        case .small: return "Objects — 4 mm voxels."
        case .medium: return "Furniture — 6 mm voxels."
        case .large: return "A corner of a room — 8 mm voxels."
        }
    }

    var size: Float {
        switch self {
        case .small: return 0.5
        case .medium: return 1.0
        case .large: return 2.0
        }
    }

    var voxelSize: Float {
        switch self {
        case .small: return 0.004
        case .medium: return 0.006
        case .large: return 0.008
        }
    }
}

/// Owns the ARSession for a scanning run: collects mesh anchors, feeds the
/// color sampler and (in Detail mode) the TSDF volume, and drives the
/// post-scan processing pipeline.
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
        var tsdfBricks = 0
    }

    var phase: Phase = .ready
    var stats = LiveStats()
    var trackingWarning: String?
    var torchOn = false
    var finishedDocument: ScanDocument?
    /// UI mirror of the overlay's mode (the source of truth lives on the
    /// session queue inside `overlay`).
    var overlayMode: MeshOverlayRenderer.Mode = .mesh
    /// True once ARKit has locked onto a reference scan's world map (always
    /// true when there is no reference).
    var isRelocalized = true

    @ObservationIgnored let overlay = MeshOverlayRenderer()
    @ObservationIgnored let session = ARSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "dev.catscan.arsession", qos: .userInitiated)

    // Session-queue-only state.
    @ObservationIgnored private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    @ObservationIgnored private var colorStore = SpatialColorStore()
    @ObservationIgnored private var tsdf: TSDFVolume?
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var captureStarted: Date?
    @ObservationIgnored private var lastColorPass: TimeInterval = 0
    @ObservationIgnored private var lastTSDFPass: TimeInterval = 0
    @ObservationIgnored private var lastOverlaySweep: TimeInterval = 0
    @ObservationIgnored private var lastStatsPush: TimeInterval = 0

    // Configured before the session starts.
    @ObservationIgnored var colorizeEnabled = true
    @ObservationIgnored var classifyEnabled = true
    @ObservationIgnored var simplifyCellSize: Float?
    @ObservationIgnored var scanMode: ScanMode = .room
    @ObservationIgnored var detailVolume: DetailVolume = .medium

    // Rescan-and-compare state.
    @ObservationIgnored private var referenceMap: ARWorldMap?
    @ObservationIgnored private var referenceScan: ScanDocument?
    @ObservationIgnored private var referenceMeshURL: URL?

    /// Puts the controller in rescan mode: the session starts from the
    /// reference scan's world map so both scans share a coordinate frame, and
    /// the finished mesh is diffed against the reference. Forces Room mode.
    func loadReference(scan: ScanDocument, worldMapURL: URL, meshURL: URL) {
        guard let data = try? Data(contentsOf: worldMapURL),
              let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            return
        }
        referenceMap = map
        referenceScan = scan
        referenceMeshURL = meshURL
        scanMode = .room
        isRelocalized = false
    }

    var isRescan: Bool { referenceScan != nil }

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
        configuration.initialWorldMap = referenceMap
        return configuration
    }

    func applySettingsAndRestart(colorize: Bool, classify: Bool, simplifyCell: Float?,
                                 mode: ScanMode, volume: DetailVolume) {
        guard phase == .ready else { return }
        colorizeEnabled = colorize
        classifyEnabled = classify
        simplifyCellSize = simplifyCell
        scanMode = mode
        detailVolume = volume
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
            self.setupCaptureBackend()
        }
    }

    /// Session queue. Creates the per-run color store and, in Detail mode, the
    /// TSDF volume placed straight ahead of the camera.
    private func setupCaptureBackend() {
        switch scanMode {
        case .room:
            colorStore = SpatialColorStore()
            tsdf = nil
            overlay.hideVolumeBox()
        case .detail:
            // Finer color cells to match the finer geometry.
            colorStore = SpatialColorStore(cellSize: max(0.004, detailVolume.voxelSize))
            let camera = session.currentFrame?.camera.transform ?? matrix_identity_float4x4
            let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
            let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
            let center = position + forward * (detailVolume.size / 2 + 0.30)
            tsdf = TSDFVolume(center: center, size: detailVolume.size, voxelSize: detailVolume.voxelSize)
            overlay.showVolumeBox(center: center, size: detailVolume.size)
        }
    }

    func resetScan() {
        Haptics.impact(.light)
        stats = LiveStats()
        sessionQueue.async {
            self.meshAnchors.removeAll()
            self.colorStore.removeAll()
            self.tsdf = nil
            self.overlay.clear()
            if self.isCapturing {
                self.captureStarted = Date()
                self.setupCaptureBackend()
            }
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
            self.tsdf = nil
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
            let duration = captureStarted.map { Date().timeIntervalSince($0) } ?? 0
            let colors: SpatialColorStore? = colorizeEnabled ? colorStore : nil
            let simplifyCell = simplifyCellSize

            if let volume = tsdf {
                Task.detached(priority: .userInitiated) {
                    await self.processDetailAndSave(volume: volume,
                                                    colorStore: colors,
                                                    simplifyCell: simplifyCell,
                                                    duration: duration,
                                                    worldMapData: worldMapData,
                                                    store: store)
                }
                return
            }

            let captured = meshAnchors.values.map { CapturedAnchorMesh(anchor: $0) }
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
        .extracting: (0.05, 0.30),
        .coloring: (0.35, 0.30),
        .cleaning: (0.65, 0.08),
        .normals: (0.73, 0.10),
        .simplifying: (0.83, 0.05),
    ]

    private func makeProgressReporter() -> (ProcessingStage, Double) -> Void {
        var lastReported = -1.0
        return { stage, fraction in
            let (start, span) = Self.stageSpans[stage] ?? (0.5, 0.1)
            let overall = start + span * min(1, max(0, fraction))
            guard overall - lastReported > 0.01 else { return }
            lastReported = overall
            let label = stage.label
            Task { @MainActor in
                self.phase = .processing(stage: label, progress: overall)
            }
        }
    }

    private func processAndSave(captured: [CapturedAnchorMesh],
                                colorStore: SpatialColorStore?,
                                simplifyCell: Float?,
                                duration: TimeInterval,
                                worldMapData: Data?,
                                store: ScanStore) async {
        let (mesh, colorFraction) = MeshBuilder.process(anchors: captured,
                                                        colorStore: colorStore,
                                                        simplifyCellSize: simplifyCell,
                                                        progress: makeProgressReporter())

        // Rescan mode: compare against the reference now that both live in the
        // same coordinate frame.
        var diff: ScanDiffResult?
        if let referenceScan, let referenceMeshURL, mesh.faceCount > 0 {
            await MainActor.run {
                self.phase = .processing(stage: "Comparing with \(referenceScan.name)", progress: 0.86)
            }
            if let referenceMesh = try? MeshData.load(from: referenceMeshURL) {
                diff = ScanDiff.compute(new: mesh, reference: referenceMesh)
            }
        }

        await finalizeAndSave(mesh: mesh,
                              colorFraction: colorFraction,
                              duration: duration,
                              worldMapData: worldMapData,
                              captureMode: ScanMode.room.rawValue,
                              diff: diff,
                              emptyMessage: "The captured mesh was empty after cleanup. Try scanning for a bit longer.",
                              store: store)
    }

    private func processDetailAndSave(volume: TSDFVolume,
                                      colorStore: SpatialColorStore?,
                                      simplifyCell: Float?,
                                      duration: TimeInterval,
                                      worldMapData: Data?,
                                      store: ScanStore) async {
        let progress = makeProgressReporter()
        progress(.extracting, 0)
        let surface = volume.extractSurface()
        progress(.extracting, 1)

        guard surface.faceCount > 0 else {
            await MainActor.run {
                self.phase = .failed(message: "Nothing was captured inside the volume box. Keep your subject inside the teal box and circle it slowly.",
                                     isCameraDenied: false)
            }
            return
        }

        let (mesh, colorFraction) = MeshBuilder.processDetail(surface: surface,
                                                              colorStore: colorStore,
                                                              simplifyCellSize: simplifyCell,
                                                              progress: progress)
        await finalizeAndSave(mesh: mesh,
                              colorFraction: colorFraction,
                              duration: duration,
                              worldMapData: worldMapData,
                              captureMode: ScanMode.detail.rawValue,
                              diff: nil,
                              emptyMessage: "The detail capture was empty after cleanup. Move a little closer and circle the subject.",
                              store: store)
    }

    private func finalizeAndSave(mesh: MeshData,
                                 colorFraction: Float,
                                 duration: TimeInterval,
                                 worldMapData: Data?,
                                 captureMode: String,
                                 diff: ScanDiffResult?,
                                 emptyMessage: String,
                                 store: ScanStore) async {
        guard mesh.faceCount > 0 else {
            await MainActor.run {
                self.phase = .failed(message: emptyMessage, isCameraDenied: false)
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
            let name: String
            if let referenceScan {
                name = referenceScan.name + " · Rescan"
            } else {
                name = "Scan " + Date().formatted(date: .abbreviated, time: .shortened)
            }

            var ancillary: [String: Data] = [:]
            if let diff {
                ancillary["diff-added.bytes"] = Data(diff.addedMask.map { $0 ? 1 : 0 })
                ancillary["diff-removed.catmesh"] = diff.removedSubmesh.serialized()
            }

            let document = try await store.save(mesh: mesh,
                                                name: name,
                                                duration: duration,
                                                colorFraction: colorFraction,
                                                captureMode: captureMode,
                                                worldMap: worldMapData,
                                                referenceScanId: diff != nil ? referenceScan?.id : nil,
                                                diffAddedArea: diff?.addedArea,
                                                diffRemovedArea: diff?.removedArea,
                                                ancillaryFiles: ancillary,
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
        if let tsdf, frame.timestamp - lastTSDFPass >= 0.15 {
            lastTSDFPass = frame.timestamp
            tsdf.integrate(frame: frame)
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
        snapshot.tsdfBricks = tsdf?.brickCount ?? 0
        snapshot.elapsed = captureStarted.map { Date().timeIntervalSince($0) } ?? 0

        DispatchQueue.main.async {
            self.stats = snapshot
        }
    }

    // MARK: - ARSessionObserver

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        if case .normal = camera.trackingState, referenceMap != nil {
            DispatchQueue.main.async {
                if !self.isRelocalized {
                    self.isRelocalized = true
                    Haptics.success()
                }
            }
        }
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
