import Foundation
import Observation
import UIKit

/// Manages the on-disk scan library: Documents/Scans/<uuid>/{mesh.catmesh, meta.json, thumb.png}
@Observable
final class ScanStore {
    private(set) var scans: [ScanDocument] = []

    @ObservationIgnored let rootURL: URL
    /// Captured at init (main thread) — UIDevice is main-actor-isolated, and
    /// save() runs from background tasks.
    @ObservationIgnored private let deviceModel = UIDevice.current.model

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        scans = Self.loadAll(from: rootURL)
    }

    // MARK: - Paths

    func folderURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func meshURL(for document: ScanDocument) -> URL {
        folderURL(for: document.id).appendingPathComponent("mesh.catmesh")
    }

    func thumbnailURL(for document: ScanDocument) -> URL {
        folderURL(for: document.id).appendingPathComponent("thumb.png")
    }

    /// The ARWorldMap saved with the scan, when tracking allowed capturing one.
    /// Future scan-diffing will relocalize against this for a shared frame.
    func worldMapURL(for document: ScanDocument) -> URL {
        folderURL(for: document.id).appendingPathComponent("worldmap.armap")
    }

    func hasWorldMap(for document: ScanDocument) -> Bool {
        FileManager.default.fileExists(atPath: worldMapURL(for: document).path)
    }

    private func metaURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("meta.json")
    }

    // MARK: - Loading

    private static func loadAll(from root: URL) -> [ScanDocument] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [ScanDocument] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let doc = try? decoder.decode(ScanDocument.self, from: data) else { continue }
            result.append(doc)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func loadMesh(for document: ScanDocument) throws -> MeshData {
        try MeshData.load(from: meshURL(for: document))
    }

    // MARK: - Mutations

    /// Serializes and writes a new scan, then registers it in the library.
    /// Safe to call from any thread/task.
    func save(mesh: MeshData,
              name: String,
              duration: TimeInterval,
              colorFraction: Float,
              worldMap: Data? = nil,
              thumbnail: UIImage?) async throws -> ScanDocument {
        let id = UUID()
        let folder = folderURL(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let meshData = mesh.serialized()
        try meshData.write(to: folder.appendingPathComponent("mesh.catmesh"), options: .atomic)
        if let png = thumbnail?.pngData() {
            try? png.write(to: folder.appendingPathComponent("thumb.png"), options: .atomic)
        }
        if let worldMap {
            try? worldMap.write(to: folder.appendingPathComponent("worldmap.armap"), options: .atomic)
        }

        let (lo, hi) = mesh.bounds()
        let document = ScanDocument(
            id: id,
            name: name,
            createdAt: Date(),
            duration: duration,
            vertexCount: mesh.vertexCount,
            faceCount: mesh.faceCount,
            surfaceArea: mesh.surfaceArea(),
            boundsMin: [lo.x, lo.y, lo.z],
            boundsMax: [hi.x, hi.y, hi.z],
            hasClassification: mesh.faceClasses != nil,
            colorFraction: colorFraction,
            deviceModel: deviceModel,
            fileSizeBytes: meshData.count
        )
        try writeMeta(document)

        await MainActor.run {
            scans.insert(document, at: 0)
        }
        return document
    }

    func delete(_ document: ScanDocument) {
        try? FileManager.default.removeItem(at: folderURL(for: document.id))
        scans.removeAll { $0.id == document.id }
    }

    func rename(_ document: ScanDocument, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = scans.firstIndex(where: { $0.id == document.id }) else { return }
        scans[index].name = trimmed
        try? writeMeta(scans[index])
    }

    private func writeMeta(_ document: ScanDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: metaURL(for: document.id), options: .atomic)
    }

    // MARK: - Sample content

    /// Builds the procedural demo scan so every feature works without LiDAR hardware.
    func addSampleScan() async throws -> ScanDocument {
        let existing = scans.filter { $0.name.hasPrefix("Yarn Ball") }.count
        let name = existing == 0 ? "Yarn Ball (Sample)" : "Yarn Ball (Sample \(existing + 1))"
        return try await Task.detached(priority: .userInitiated) { [self] in
            let mesh = SampleMeshFactory.yarnBall()
            let thumbnail = SceneKitSupport.renderThumbnail(mesh: mesh, size: CGSize(width: 640, height: 640))
            return try await save(mesh: mesh, name: name, duration: 0, colorFraction: 1, thumbnail: thumbnail)
        }.value
    }
}
