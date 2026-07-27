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
        lines.append(contentsOf: await scanDiffTest(store: store, renderInto: modesDir))
        lines.append(contentsOf: await momentTest(store: store, renderInto: modesDir))

        return lines
    }

    /// Moment check: build a synthetic animated clip (rotating sample points),
    /// round-trip it through serialization and the store, render frames, and
    /// produce a spatial-replay video into Photos.
    private static func momentTest(store: ScanStore, renderInto directory: URL) async -> [String] {
        let sample = SampleMeshFactory.yarnBall()
        var basePositions: [SIMD3<Float>] = []
        var baseColors: [SIMD4<UInt8>] = []
        for i in Swift.stride(from: 0, to: sample.vertexCount, by: 3) {
            basePositions.append(sample.positions[i])
            baseColors.append(sample.colors[i])
        }
        let (lo, hi) = sample.bounds()
        let center = (lo + hi) * 0.5

        var frames: [MomentFrame] = []
        for f in 0..<24 {
            let angle = Float(f) * 0.09
            let bob = 0.02 * sin(Float(f) * 0.5)
            let (s, c) = (sin(angle), cos(angle))
            let rotated = basePositions.map { p -> SIMD3<Float> in
                let d = p - center
                return center + SIMD3(c * d.x + s * d.z, d.y + bob, -s * d.x + c * d.z)
            }
            frames.append(MomentFrame(time: Float(f) / 15, positions: rotated, colors: baseColors))
        }
        let clip = MomentClip(frames: frames)

        var lines: [String] = []
        do {
            let reloaded = try MomentClip.load(from: clip.serialized())
            let framesOK = reloaded.frames.count == clip.frames.count
                && reloaded.totalPoints == clip.totalPoints
                && abs(reloaded.duration - clip.duration) < 0.001
            let firstPoint = reloaded.frames[0].positions[0]
            let pointOK = simd_length(firstPoint - frames[0].positions[0]) < 1e-6
            lines.append("moment-roundtrip: \(framesOK && pointOK ? "ok" : "FAIL") frames=\(reloaded.frames.count) points=\(reloaded.totalPoints) duration=\(String(format: "%.2f", reloaded.duration))s")
        } catch {
            lines.append("moment-roundtrip: FAIL \(error)")
        }

        for index in [0, 12] {
            if let image = SceneKitSupport.renderThumbnail(mesh: clip.pointMesh(at: index),
                                                           size: CGSize(width: 480, height: 480),
                                                           mode: .points),
               let png = image.pngData() {
                try? png.write(to: directory.appendingPathComponent("moment-frame-\(index).png"))
                lines.append("moment-frame-\(index): ok")
            } else {
                lines.append("moment-frame-\(index): FAIL")
            }
        }

        do {
            let renderer = MomentVideoRenderer()
            let url = try await renderer.render(clip: clip,
                                                size: CGSize(width: 360, height: 360),
                                                fps: 12,
                                                loops: 1)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            try await PhotoSaver.save(videoAt: url)
            lines.append("moment-video: ok bytes=\((attributes?[.size] as? Int) ?? -1)")
        } catch {
            lines.append("moment-video: FAIL \(error)")
        }

        do {
            let representative = clip.pointMesh(at: frames.count / 2)
            let document = try await store.save(mesh: representative,
                                                name: "Moment AutoTest",
                                                duration: TimeInterval(clip.duration),
                                                colorFraction: 1,
                                                captureMode: ScanMode.moment.rawValue,
                                                ancillaryFiles: ["moment.catmoment": clip.serialized()],
                                                thumbnail: nil)
            let loaded = try store.loadMomentClip(for: document)
            lines.append("moment-store: \(loaded.frames.count == clip.frames.count && document.isMoment ? "ok" : "FAIL")")
        } catch {
            lines.append("moment-store: FAIL \(error)")
        }
        return lines
    }

    /// Diff check: chop a region off the sample and weld a sphere onto it,
    /// then verify the diff reports both changes with the right areas and the
    /// artifacts round-trip through the store.
    private static func scanDiffTest(store: ScanStore, renderInto directory: URL) async -> [String] {
        let reference = SampleMeshFactory.yarnBall()
        var modified = reference

        // Remove everything right of a chop plane.
        let (lo, hi) = reference.bounds()
        let chopX = lo.x + (hi.x - lo.x) * 0.55
        var keptIndices: [UInt32] = []
        var choppedArea: Float = 0
        // The diff's match tolerance (~2 cells) intentionally forgives a
        // boundary band near surviving geometry, so only area beyond the band
        // is guaranteed to be flagged.
        var definitelyChoppedArea: Float = 0
        let bandWidth = ScanDiff.defaultTolerance * 2.2
        var i = 0
        while i + 2 < reference.indices.count {
            let a = reference.positions[Int(reference.indices[i])]
            let b = reference.positions[Int(reference.indices[i + 1])]
            let c = reference.positions[Int(reference.indices[i + 2])]
            let centroidX = (a.x + b.x + c.x) / 3
            if centroidX > chopX {
                let area = simd_length(simd_cross(b - a, c - a)) * 0.5
                choppedArea += area
                if centroidX > chopX + bandWidth {
                    definitelyChoppedArea += area
                }
            } else {
                keptIndices.append(contentsOf: [reference.indices[i], reference.indices[i + 1], reference.indices[i + 2]])
            }
            i += 3
        }
        modified.indices = keptIndices
        modified.faceClasses = nil
        MeshBuilder.compactVertices(&modified)

        // Add a floating blob well clear of the original surface.
        let blob = uvSphere(center: SIMD3(0, hi.y + 0.12, 0), radius: 0.06)
        let blobArea = blob.surfaceArea()
        let base = UInt32(modified.vertexCount)
        modified.positions.append(contentsOf: blob.positions)
        modified.normals.append(contentsOf: blob.normals)
        modified.colors.append(contentsOf: [SIMD4<UInt8>](repeating: SIMD4(200, 200, 205, 255), count: blob.vertexCount))
        modified.indices.append(contentsOf: blob.indices.map { $0 + base })

        let diff = ScanDiff.compute(new: modified, reference: reference)
        let addedRatio = diff.addedArea / max(0.0001, blobArea)
        let removedOK = diff.removedArea >= definitelyChoppedArea * 0.85
            && diff.removedArea <= choppedArea * 1.05
        let addedCount = diff.addedMask.filter { $0 }.count

        let parent = SCNNode()
        parent.addChildNode(SCNNode(geometry: SceneKitSupport.changesGeometry(mesh: modified, addedMask: diff.addedMask)))
        if let ghost = SceneKitSupport.removedGhostNode(removed: diff.removedSubmesh) {
            parent.addChildNode(ghost)
        }
        let (mlo, mhi) = reference.bounds()
        if let image = SceneKitSupport.renderPreview(node: parent,
                                                     center: (mlo + mhi) * 0.5 + SIMD3(0, 0.06, 0),
                                                     extent: (mhi - mlo) + SIMD3(0, 0.24, 0),
                                                     size: CGSize(width: 500, height: 500)),
           let png = image.pngData() {
            try? png.write(to: directory.appendingPathComponent("changes-diff.png"))
        }

        var lines = [String(format: "scan-diff: %@ addedRatio=%.3f removed=%.3f (band-adjusted floor %.3f, total %.3f) addedVerts=%d removedFaces=%d",
                            (abs(addedRatio - 1) < 0.15 && removedOK && addedCount > 0) ? "ok" : "FAIL",
                            addedRatio, diff.removedArea, definitelyChoppedArea, choppedArea,
                            addedCount, diff.removedSubmesh.faceCount)]

        // Round-trip the artifacts through the store like a real rescan.
        do {
            let refDoc = try await store.save(mesh: reference, name: "DiffRef", duration: 0,
                                              colorFraction: 1, thumbnail: nil)
            let ancillary: [String: Data] = [
                "diff-added.bytes": Data(diff.addedMask.map { $0 ? 1 : 0 }),
                "diff-removed.catmesh": diff.removedSubmesh.serialized(),
            ]
            let rescanDoc = try await store.save(mesh: modified, name: "DiffRef · Rescan", duration: 0,
                                                 colorFraction: 1,
                                                 referenceScanId: refDoc.id,
                                                 diffAddedArea: diff.addedArea,
                                                 diffRemovedArea: diff.removedArea,
                                                 ancillaryFiles: ancillary,
                                                 thumbnail: nil)
            let loaded = try store.loadDiff(for: rescanDoc)
            let ok = loaded.added.count == modified.vertexCount
                && loaded.removed.faceCount == diff.removedSubmesh.faceCount
                && rescanDoc.hasDiff
            lines.append("scan-diff-roundtrip: \(ok ? "ok" : "FAIL") mask=\(loaded.added.count) ghostFaces=\(loaded.removed.faceCount)")
        } catch {
            lines.append("scan-diff-roundtrip: FAIL \(error)")
        }
        return lines
    }

    private static func uvSphere(center: SIMD3<Float>, radius: Float, rings: Int = 14, segments: Int = 20) -> MeshData {
        var mesh = MeshData()
        for ring in 0...rings {
            let phi = Float.pi * Float(ring) / Float(rings)
            for segment in 0..<segments {
                let theta = 2 * Float.pi * Float(segment) / Float(segments)
                let normal = SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                mesh.positions.append(center + normal * radius)
                mesh.normals.append(normal)
            }
        }
        for ring in 0..<rings {
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = UInt32(ring * segments + segment)
                let b = UInt32((ring + 1) * segments + segment)
                let c = UInt32((ring + 1) * segments + next)
                let d = UInt32(ring * segments + next)
                if ring > 0 { mesh.indices.append(contentsOf: [a, b, d]) }
                if ring < rings - 1 { mesh.indices.append(contentsOf: [b, c, d]) }
            }
        }
        return mesh
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
