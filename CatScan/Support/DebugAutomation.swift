#if DEBUG
import Foundation
import SceneKit
import UIKit
import simd

/// Headless test hooks, compiled out of Release builds.
///
/// Launch arguments:
///  - `-catscanAutoTest`  builds the sample scan, runs every exporter, renders a
///    short turntable, saves a snapshot + video to Photos, and writes
///    Documents/autotest-report.txt with the results.
///  - `-catscanOpenFirst` (handled in LibraryView) navigates straight to the
///    first scan so screenshots show the viewer.
enum DebugAutomation {

    static var wantsOpenFirst: Bool {
        ProcessInfo.processInfo.arguments.contains("-catscanOpenFirst")
    }

    static func runIfRequested(store: ScanStore) {
        guard ProcessInfo.processInfo.arguments.contains("-catscanAutoTest") else { return }
        Task.detached(priority: .userInitiated) {
            let lines = await run(store: store)
            let report = lines.joined(separator: "\n") + "\ndone\n"
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("autotest-report.txt")
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func run(store: ScanStore) async -> [String] {
        var lines: [String] = []
        let document: ScanDocument
        let mesh: MeshData
        do {
            document = try await store.addSampleScan()
            lines.append("sample: ok vertices=\(document.vertexCount) faces=\(document.faceCount) area=\(document.surfaceArea)")
            mesh = try store.loadMesh(for: document)
            lines.append("roundtrip: ok vertices=\(mesh.vertexCount) faces=\(mesh.faceCount) colors=\(mesh.colors.count) normals=\(mesh.normals.count)")
        } catch {
            lines.append("FATAL: \(error)")
            return lines
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDir = documents.appendingPathComponent("AutoExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        for format in ExportFormat.allCases {
            do {
                let url = try await MeshExporter.export(mesh: mesh,
                                                        name: "AutoTest",
                                                        format: format,
                                                        includeColors: true)
                let destination = exportDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let size = (attributes?[.size] as? Int) ?? -1
                lines.append("export \(format.rawValue): ok bytes=\(size)")
            } catch {
                lines.append("export \(format.rawValue): FAIL \(error)")
            }
        }

        if let thumbnail = SceneKitSupport.renderThumbnail(mesh: mesh, size: CGSize(width: 480, height: 480)) {
            do {
                try await PhotoSaver.save(image: thumbnail)
                lines.append("photo-image: ok")
            } catch {
                lines.append("photo-image: FAIL \(error)")
            }
        } else {
            lines.append("photo-image: FAIL render returned nil")
        }

        do {
            let renderer = TurntableRenderer()
            let videoURL = try await renderer.render(mesh: mesh,
                                                     size: CGSize(width: 540, height: 540),
                                                     duration: 2,
                                                     fps: 12)
            let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
            let size = (attributes?[.size] as? Int) ?? -1
            try await PhotoSaver.save(videoAt: videoURL)
            lines.append("photo-video: ok bytes=\(size)")
        } catch {
            lines.append("photo-video: FAIL \(error)")
        }

        do {
            let usdzURL = try USDZExporter.cachedUSDZ(for: document, mesh: mesh)
            let attributes = try? FileManager.default.attributesOfItem(atPath: usdzURL.path)
            lines.append("usdz-cache: ok bytes=\((attributes?[.size] as? Int) ?? -1)")
        } catch {
            lines.append("usdz-cache: FAIL \(error)")
        }

        // Render every display mode offscreen — same geometry builders the viewer uses.
        let modesDir = documents.appendingPathComponent("AutoModes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        var classifiedMesh = mesh
        classifiedMesh.faceClasses = (0..<classifiedMesh.faceCount).map { UInt8($0 % 8) }
        for mode in ViewerDisplayMode.allCases {
            let source = mode == .classification ? classifiedMesh : mesh
            if let image = SceneKitSupport.renderThumbnail(mesh: source, size: CGSize(width: 500, height: 500), mode: mode),
               let png = image.pngData() {
                try? png.write(to: modesDir.appendingPathComponent("\(mode.rawValue).png"))
                lines.append("mode \(mode.rawValue): ok")
            } else {
                lines.append("mode \(mode.rawValue): FAIL")
            }
        }

        // Coverage heatmap geometry — synthetic store paints half the sample
        // with a bottom-to-top quality ramp; the other half should be red.
        let coverageStore = SpatialColorStore()
        let (clo, chi) = mesh.bounds()
        let midX = (clo.x + chi.x) / 2
        for p in mesh.positions where p.x > midX {
            let t = (p.y - clo.y) / max(0.001, chi.y - clo.y)
            coverageStore.integrate(point: p, r: 200, g: 200, b: 200, quality: 0.1 + 1.3 * t)
        }
        let coverageGeometry = MeshOverlayRenderer.coverageGeometry(localPositions: mesh.positions,
                                                                    indices: mesh.indices,
                                                                    transform: matrix_identity_float4x4,
                                                                    store: coverageStore)
        if let image = SceneKitSupport.renderPreview(node: SCNNode(geometry: coverageGeometry),
                                                     center: (clo + chi) * 0.5,
                                                     extent: chi - clo,
                                                     size: CGSize(width: 500, height: 500)),
           let png = image.pngData() {
            try? png.write(to: modesDir.appendingPathComponent("coverage-overlay.png"))
            lines.append("coverage-render: ok cells=\(coverageStore.count)")
        } else {
            lines.append("coverage-render: FAIL")
        }

        lines.append(contentsOf: tsdfSphereTest(renderInto: modesDir))
        lines.append(contentsOf: tsdfPlaneTest())

        return lines
    }

    /// Detail-mode extraction check: an analytic sphere SDF must come out as a
    /// closed (zero boundary edges), outward-facing surface whose area matches
    /// 4πr² — this validates Surface Nets topology, winding, and metric scale.
    private static func tsdfSphereTest(renderInto directory: URL) -> [String] {
        let radius: Float = 0.22
        let volume = TSDFVolume(center: .zero, size: 0.6, voxelSize: 0.005)
        volume.fill { p in simd_length(p) - radius }
        var mesh = volume.extractSurface()
        guard mesh.faceCount > 0 else { return ["tsdf-sphere: FAIL empty"] }

        let boundary = boundaryEdgeCount(mesh)
        MeshBuilder.recomputeNormals(&mesh)
        var outward: Float = 0
        for i in 0..<mesh.vertexCount {
            outward += simd_dot(simd_normalize(mesh.positions[i]), mesh.normals[i])
        }
        outward /= Float(max(1, mesh.vertexCount))
        let idealArea = 4 * Float.pi * radius * radius
        let areaRatio = mesh.surfaceArea() / idealArea

        mesh.colors = [SIMD4<UInt8>](repeating: SIMD4(120, 200, 235, 255), count: mesh.vertexCount)
        if let image = SceneKitSupport.renderThumbnail(mesh: mesh, size: CGSize(width: 500, height: 500)),
           let png = image.pngData() {
            try? png.write(to: directory.appendingPathComponent("tsdf-sphere.png"))
        }

        let ok = boundary == 0 && outward > 0.9 && abs(areaRatio - 1) < 0.05
        return [String(format: "tsdf-sphere: %@ v=%d f=%d boundary=%d outward=%.3f areaRatio=%.3f",
                       ok ? "ok" : "FAIL", mesh.vertexCount, mesh.faceCount, boundary, outward, areaRatio)]
    }

    /// Detail-mode integration check: synthetic depth frames of a flat wall at
    /// z = -1 m pushed through the real `integrate` ray path must reconstruct a
    /// plane at the right depth with camera-facing normals.
    private static func tsdfPlaneTest() -> [String] {
        let width = 96, height = 72
        let depth = [Float32](repeating: 1.0, count: width * height)
        let volume = TSDFVolume(center: SIMD3(0, 0, -1), size: 0.5, voxelSize: 0.006)
        depth.withUnsafeBufferPointer { buffer in
            for _ in 0..<12 {
                volume.integrate(depth: buffer.baseAddress!, depthRowStride: width,
                                 confidence: nil, confidenceRowStride: 0,
                                 width: width, height: height,
                                 fx: 80, fy: 80, cx: Float(width) / 2, cy: Float(height) / 2,
                                 cameraTransform: matrix_identity_float4x4)
            }
        }
        var mesh = volume.extractSurface()
        guard mesh.vertexCount > 0 else { return ["tsdf-plane: FAIL empty"] }

        var depthError: Float = 0
        for p in mesh.positions {
            depthError += abs(p.z + 1)
        }
        depthError /= Float(mesh.vertexCount)
        MeshBuilder.recomputeNormals(&mesh)
        var facing: Float = 0
        for n in mesh.normals {
            facing += n.z
        }
        facing /= Float(max(1, mesh.vertexCount))

        let ok = depthError < 0.004 && facing > 0.9
        return [String(format: "tsdf-plane: %@ v=%d f=%d meanDepthErr=%.4fm facingCamera=%.3f bricks=%d",
                       ok ? "ok" : "FAIL", mesh.vertexCount, mesh.faceCount, depthError, facing, volume.brickCount)]
    }

    private static func boundaryEdgeCount(_ mesh: MeshData) -> Int {
        var counts = [UInt64: Int](minimumCapacity: mesh.indices.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let tri = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
            for e in 0..<3 {
                let a = tri[e], b = tri[(e + 1) % 3]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                counts[key, default: 0] += 1
            }
            i += 3
        }
        return counts.values.filter { $0 == 1 }.count
    }
}
#endif
