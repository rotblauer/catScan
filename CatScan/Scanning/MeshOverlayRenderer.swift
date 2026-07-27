import ARKit
import QuartzCore
import SceneKit
import UIKit
import simd

/// Renders our own copy of the ARKit reconstruction mesh inside the scanner,
/// so the overlay can be recolored live — including the color-coverage heatmap
/// (green = good color samples, red = never seen) that stock debug meshes
/// can't show.
///
/// Threading: geometry is built on the session queue (where the anchor dict
/// and color store live) and applied to nodes on the main thread.
final class MeshOverlayRenderer {

    enum Mode: Int, CaseIterable {
        case off, mesh, coverage

        var next: Mode {
            Mode(rawValue: (rawValue + 1) % Mode.allCases.count) ?? .off
        }

        var systemImage: String {
            switch self {
            case .off: return "eye.slash"
            case .mesh: return "grid"
            case .coverage: return "paintpalette.fill"
            }
        }
    }

    /// Parent of the overlay content; added to the scanner scene on main.
    let rootNode = SCNNode()
    /// Per-anchor mesh nodes live here so mode .off can hide them while the
    /// Detail-mode capture volume box stays visible.
    private let anchorContainer = SCNNode()

    /// Quality at (and above) which a vertex counts as fully covered.
    /// A high-confidence sample from ~0.9 m reaches this.
    static let goodQuality: Float = 1.1

    // Session-queue-only state.
    private var mode: Mode = .mesh
    private var lastBuildTimes: [UUID: TimeInterval] = [:]

    // Main-thread-only state.
    private var nodes: [UUID: SCNNode] = [:]
    private var volumeBoxNode: SCNNode?

    init() {
        rootNode.addChildNode(anchorContainer)
    }

    // MARK: - Session-queue API

    func setMode(_ newMode: Mode, anchors: [ARMeshAnchor], store: SpatialColorStore?) {
        mode = newMode
        DispatchQueue.main.async {
            self.anchorContainer.isHidden = (newMode == .off)
        }
        guard newMode != .off else { return }
        lastBuildTimes.removeAll()
        for anchor in anchors {
            update(anchor: anchor, store: store, force: true)
        }
    }

    func update(anchor: ARMeshAnchor, store: SpatialColorStore?, force: Bool = false) {
        guard mode != .off else { return }
        let now = CACurrentMediaTime()
        if !force, let last = lastBuildTimes[anchor.identifier], now - last < 0.5 {
            return
        }
        lastBuildTimes[anchor.identifier] = now

        let localPositions = anchor.geometry.vertices.asSIMD3Array()
        let indices = anchor.geometry.faces.asUInt32Array()
        guard !localPositions.isEmpty, !indices.isEmpty else { return }

        let geometry: SCNGeometry
        if mode == .coverage, let store {
            geometry = Self.coverageGeometry(localPositions: localPositions,
                                             indices: indices,
                                             transform: anchor.transform,
                                             store: store)
        } else {
            geometry = Self.wireGeometry(localPositions: localPositions, indices: indices)
        }

        let id = anchor.identifier
        let transform = anchor.transform
        DispatchQueue.main.async {
            let node: SCNNode
            if let existing = self.nodes[id] {
                node = existing
            } else {
                node = SCNNode()
                self.nodes[id] = node
                self.anchorContainer.addChildNode(node)
            }
            node.simdTransform = transform
            node.geometry = geometry
        }
    }

    func remove(id: UUID) {
        lastBuildTimes.removeValue(forKey: id)
        DispatchQueue.main.async {
            self.nodes[id]?.removeFromParentNode()
            self.nodes.removeValue(forKey: id)
        }
    }

    /// Rebuilds the stalest anchors (~1 Hz from the frame callback) so static
    /// geometry keeps absorbing newly captured color samples.
    func sweep(anchors: [ARMeshAnchor], store: SpatialColorStore?) {
        guard mode == .coverage, store != nil else { return }
        let stalest = anchors
            .sorted { (lastBuildTimes[$0.identifier] ?? 0) < (lastBuildTimes[$1.identifier] ?? 0) }
            .prefix(4)
        for anchor in stalest {
            update(anchor: anchor, store: store, force: true)
        }
    }

    func clear() {
        lastBuildTimes.removeAll()
        DispatchQueue.main.async {
            for node in self.nodes.values {
                node.removeFromParentNode()
            }
            self.nodes.removeAll()
            self.volumeBoxNode?.removeFromParentNode()
            self.volumeBoxNode = nil
        }
    }

    // MARK: - Detail-mode capture volume box

    func showVolumeBox(center: SIMD3<Float>, size: Float) {
        let geometry = Self.boxLineGeometry(size: size)
        DispatchQueue.main.async {
            self.volumeBoxNode?.removeFromParentNode()
            let node = SCNNode(geometry: geometry)
            node.simdPosition = center
            self.rootNode.addChildNode(node)
            self.volumeBoxNode = node
        }
    }

    func hideVolumeBox() {
        DispatchQueue.main.async {
            self.volumeBoxNode?.removeFromParentNode()
            self.volumeBoxNode = nil
        }
    }

    static func boxLineGeometry(size: Float) -> SCNGeometry {
        let h = size / 2
        var corners: [SIMD3<Float>] = []
        for z: Float in [-h, h] {
            for y: Float in [-h, h] {
                for x: Float in [-h, h] {
                    corners.append(SIMD3(x, y, z))
                }
            }
        }
        // Corner index bits: x = 1, y = 2, z = 4.
        let edges: [UInt32] = [
            0, 1, 2, 3, 4, 5, 6, 7,        // x-parallel
            0, 2, 1, 3, 4, 6, 5, 7,        // y-parallel
            0, 4, 1, 5, 2, 6, 3, 7,        // z-parallel
        ]
        let element = SCNGeometryElement(indices: edges, primitiveType: .line)
        let geometry = SCNGeometry(sources: [SceneKitSupport.vertexSource(corners)], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.30, green: 0.90, blue: 0.80, alpha: 1)
        material.transparency = 0.9
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    // MARK: - Geometry builders (pure functions; reused by DebugAutomation)

    static func wireGeometry(localPositions: [SIMD3<Float>], indices: [UInt32]) -> SCNGeometry {
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [SceneKitSupport.vertexSource(localPositions)], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.35, green: 0.92, blue: 0.83, alpha: 1)
        material.fillMode = .lines
        material.transparency = 0.55
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    static func coverageGeometry(localPositions: [SIMD3<Float>],
                                 indices: [UInt32],
                                 transform: simd_float4x4,
                                 store: SpatialColorStore) -> SCNGeometry {
        var colors = [SIMD4<UInt8>]()
        colors.reserveCapacity(localPositions.count)
        for local in localPositions {
            let world4 = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            let quality = store.maxQuality(near: SIMD3(world4.x, world4.y, world4.z))
            let rgb = heatColor(quality)
            colors.append(SIMD4(UInt8(rgb.x * 255), UInt8(rgb.y * 255), UInt8(rgb.z * 255), 255))
        }

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [SceneKitSupport.vertexSource(localPositions),
                                             SceneKitSupport.colorSource(colors)],
                                   elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.transparency = 0.62
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    /// 0 → red, half coverage → amber, goodQuality+ → green.
    static func heatColor(_ quality: Float) -> SIMD3<Float> {
        let t = min(1, max(0, quality / goodQuality))
        let red = SIMD3<Float>(0.94, 0.23, 0.20)
        let amber = SIMD3<Float>(0.96, 0.78, 0.18)
        let green = SIMD3<Float>(0.18, 0.85, 0.42)
        if t < 0.5 {
            return simd_mix(red, amber, SIMD3(repeating: t * 2))
        }
        return simd_mix(amber, green, SIMD3(repeating: (t - 0.5) * 2))
    }
}
