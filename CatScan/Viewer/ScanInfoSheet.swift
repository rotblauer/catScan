import SwiftUI

struct ScanInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store
    let document: ScanDocument

    var body: some View {
        NavigationStack {
            List {
                Section("Scan") {
                    LabeledContent("Name", value: document.name)
                    LabeledContent("Created", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if document.duration > 0 {
                        LabeledContent("Scan time", value: document.duration.clockString)
                    }
                    LabeledContent("File size", value: document.fileSizeBytes.byteString)
                }
                Section("Geometry") {
                    LabeledContent("Vertices", value: document.vertexCount.formatted())
                    LabeledContent("Triangles", value: document.faceCount.formatted())
                    LabeledContent("Surface area", value: document.areaString)
                    LabeledContent("Dimensions", value: document.dimensionsString)
                }
                Section("Capture") {
                    LabeledContent("Capture mode", value: document.isDetailCapture ? "Detail (depth fusion)" : "Room (ARKit mesh)")
                    LabeledContent("Colored", value: document.isColored
                        ? "\(Int((document.colorFraction * 100).rounded()))% of vertices"
                        : "No")
                    LabeledContent("Surface classes", value: document.hasClassification ? "Yes" : "No")
                    LabeledContent("Relocalization map", value: store.hasWorldMap(for: document) ? "Saved" : "None")
                }
                if document.hasDiff {
                    Section("Comparison") {
                        if let referenceId = document.referenceScanId,
                           let reference = store.scans.first(where: { $0.id == referenceId }) {
                            LabeledContent("Compared against", value: reference.name)
                        }
                        if let added = document.diffAddedArea {
                            LabeledContent("Added surface", value: String(format: "%.2f m²", added))
                        }
                        if let removed = document.diffRemovedArea {
                            LabeledContent("Removed surface", value: String(format: "%.2f m²", removed))
                        }
                    }
                }
            }
            .navigationTitle("Scan Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
