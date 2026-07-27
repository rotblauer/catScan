import Metal
import SceneKit
import UIKit
import simd

enum ViewerDisplayMode: String, CaseIterable, Identifiable {
    case shaded, unlit, wireframe, points, classification

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shaded: return "Shaded"
        case .unlit: return "Unlit"
        case .wireframe: return "Wire"
        case .points: return "Points"
        case .classification: return "Classes"
        }
    }

    static func available(for mesh: MeshData) -> [ViewerDisplayMode] {
        var modes: [ViewerDisplayMode] = [.shaded, .unlit, .wireframe, .points]
        if let classes = mesh.faceClasses, !classes.isEmpty {
            modes.append(.classification)
        }
        return modes
    }
}

/// Mirrors ARMeshClassification raw values.
enum SurfaceClass: UInt8, CaseIterable {
    case none = 0, wall, floor, ceiling, table, seat, window, door

    var label: String {
        switch self {
        case .none: return "Other"
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .seat: return "Seat"
        case .window: return "Window"
        case .door: return "Door"
        }
    }

    var rgba: SIMD4<UInt8> {
        switch self {
        case .none: return SIMD4(142, 142, 147, 255)
        case .wall: return SIMD4(222, 184, 135, 255)
        case .floor: return SIMD4(52, 199, 89, 255)
        case .ceiling: return SIMD4(100, 210, 255, 255)
        case .table: return SIMD4(255, 159, 10, 255)
        case .seat: return SIMD4(191, 90, 242, 255)
        case .window: return SIMD4(48, 176, 199, 255)
        case .door: return SIMD4(255, 55, 95, 255)
        }
    }

    var color: UIColor {
        let c = rgba
        return UIColor(red: CGFloat(c.x) / 255, green: CGFloat(c.y) / 255, blue: CGFloat(c.z) / 255, alpha: 1)
    }
}

enum SceneKitSupport {

    // MARK: - Geometry

    static func geometry(for mesh: MeshData, mode: ViewerDisplayMode) -> SCNGeometry {
        let colors: [SIMD4<UInt8>]?
        switch mode {
        case .classification:
            colors = classificationVertexColors(for: mesh)
        default:
            colors = mesh.colors.count == mesh.vertexCount ? mesh.colors : nil
        }

        var sources: [SCNGeometrySource] = [vertexSource(mesh.positions)]
        if mesh.normals.count == mesh.vertexCount {
            sources.append(normalSource(mesh.normals))
        }
        if let colors {
            sources.append(colorSource(colors))
        }

        let element: SCNGeometryElement
        if mode == .points {
            let pointIndices = [UInt32](0..<UInt32(mesh.vertexCount))
            element = SCNGeometryElement(indices: pointIndices, primitiveType: .point)
            element.pointSize = 4
            element.minimumPointScreenSpaceRadius = 1.5
            element.maximumPointScreenSpaceRadius = 7
        } else {
            element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        }

        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material(for: mode)]
        return geometry
    }

    private static func material(for mode: ViewerDisplayMode) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        switch mode {
        case .shaded, .classification:
            material.lightingModel = .lambert
        case .unlit, .points:
            material.lightingModel = .constant
        case .wireframe:
            material.lightingModel = .constant
            material.fillMode = .lines
        }
        return material
    }

    static func vertexSource(_ positions: [SIMD3<Float>]) -> SCNGeometrySource {
        let floats = MeshData.flatten(positions)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data,
                                 semantic: .vertex,
                                 vectorCount: positions.count,
                                 usesFloatComponents: true,
                                 componentsPerVector: 3,
                                 bytesPerComponent: 4,
                                 dataOffset: 0,
                                 dataStride: 12)
    }

    private static func normalSource(_ normals: [SIMD3<Float>]) -> SCNGeometrySource {
        let floats = MeshData.flatten(normals)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data,
                                 semantic: .normal,
                                 vectorCount: normals.count,
                                 usesFloatComponents: true,
                                 componentsPerVector: 3,
                                 bytesPerComponent: 4,
                                 dataOffset: 0,
                                 dataStride: 12)
    }

    static func colorSource(_ colors: [SIMD4<UInt8>]) -> SCNGeometrySource {
        var floats = [Float]()
        floats.reserveCapacity(colors.count * 3)
        for c in colors {
            floats.append(Float(c.x) / 255)
            floats.append(Float(c.y) / 255)
            floats.append(Float(c.z) / 255)
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data,
                                 semantic: .color,
                                 vectorCount: colors.count,
                                 usesFloatComponents: true,
                                 componentsPerVector: 3,
                                 bytesPerComponent: 4,
                                 dataOffset: 0,
                                 dataStride: 12)
    }

    private static func classificationVertexColors(for mesh: MeshData) -> [SIMD4<UInt8>] {
        var colors = [SIMD4<UInt8>](repeating: SurfaceClass.none.rgba, count: mesh.vertexCount)
        guard let classes = mesh.faceClasses else { return colors }
        var i = 0
        var face = 0
        while i + 2 < mesh.indices.count, face < classes.count {
            let rgba = (SurfaceClass(rawValue: classes[face]) ?? .none).rgba
            colors[Int(mesh.indices[i])] = rgba
            colors[Int(mesh.indices[i + 1])] = rgba
            colors[Int(mesh.indices[i + 2])] = rgba
            i += 3
            face += 1
        }
        return colors
    }

    /// Which classes actually occur in this mesh, for the legend.
    static func presentClasses(in mesh: MeshData) -> [SurfaceClass] {
        guard let classes = mesh.faceClasses else { return [] }
        var seen = Set<UInt8>()
        for c in classes { seen.insert(c) }
        return SurfaceClass.allCases.filter { seen.contains($0.rawValue) }
    }

    // MARK: - Scene assembly

    static func makeScene(mesh: MeshData, mode: ViewerDisplayMode) -> (scene: SCNScene, model: SCNNode, camera: SCNNode) {
        let scene = SCNScene()
        let model = SCNNode(geometry: geometry(for: mesh, mode: mode))
        let (lo, hi) = mesh.bounds()
        let center = (lo + hi) * 0.5
        model.position = SCNVector3(-center.x, -center.y, -center.z)

        // Parent so turntable rotation happens about the model's center.
        let pivot = SCNNode()
        pivot.addChildNode(model)
        scene.rootNode.addChildNode(pivot)

        addLights(to: scene)
        let camera = makeCamera(extent: hi - lo)
        scene.rootNode.addChildNode(camera)
        return (scene, pivot, camera)
    }

    private static func addLights(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 350
        fill.eulerAngles = SCNVector3(-Float.pi / 12, Float.pi + Float.pi / 4, 0)
        scene.rootNode.addChildNode(fill)
    }

    static func makeCamera(extent: SIMD3<Float>) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.automaticallyAdjustsZRange = true
        let node = SCNNode()
        node.camera = camera

        let radius = max(0.15, simd_length(extent) * 0.5)
        let distance = radius / tan(Float(camera.fieldOfView) * .pi / 360) * 1.25
        let azimuth: Float = .pi / 5.5
        let elevation: Float = .pi / 9
        node.position = SCNVector3(distance * sin(azimuth) * cos(elevation),
                                   distance * sin(elevation),
                                   distance * cos(azimuth) * cos(elevation))
        node.look(at: SCNVector3Zero)
        return node
    }

    // MARK: - Thumbnail

    /// Offscreen render of an arbitrary node (used by debug verification).
    static func renderPreview(node: SCNNode, center: SIMD3<Float>, extent: SIMD3<Float>, size: CGSize) -> UIImage? {
        let scene = SCNScene()
        node.position = SCNVector3(-center.x, -center.y, -center.z)
        let pivot = SCNNode()
        pivot.addChildNode(node)
        scene.rootNode.addChildNode(pivot)
        addLights(to: scene)
        let camera = makeCamera(extent: extent)
        scene.rootNode.addChildNode(camera)
        scene.background.contents = AppGradients.thumbnailBackground
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    static func renderThumbnail(mesh: MeshData, size: CGSize, mode: ViewerDisplayMode = .shaded) -> UIImage? {
        let (scene, _, camera) = makeScene(mesh: mesh, mode: mode)
        scene.background.contents = AppGradients.thumbnailBackground
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
