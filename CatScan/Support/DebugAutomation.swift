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

        return lines
    }
}
#endif
