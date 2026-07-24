import SwiftUI

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: ScanDocument
    let mesh: MeshData

    @State private var format: ExportFormat = .usdz
    @State private var includeColors = true
    @State private var isWorking = false
    @State private var result: ExportResult?
    @State private var errorMessage: String?

    struct ExportResult: Identifiable {
        let id = UUID()
        let url: URL
        let sizeBytes: Int
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ExportFormat.allCases) { candidate in
                        Button {
                            format = candidate
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: candidate.systemImage)
                                    .frame(width: 26)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.displayName)
                                        .foregroundStyle(.primary)
                                    Text(candidate.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if format == candidate {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Format")
                }

                Section {
                    Toggle("Include vertex colors", isOn: $includeColors)
                        .disabled(!format.supportsColor)
                } footer: {
                    if !format.supportsColor {
                        Text("STL carries geometry only.")
                    } else if !document.isColored {
                        Text("This scan has no captured colors; a neutral gray is exported.")
                    }
                }

                Section {
                    LabeledContent("Triangles", value: document.faceCount.formatted())
                    LabeledContent("Estimated size",
                                   value: MeshExporter.estimatedSize(mesh: mesh,
                                                                     format: format,
                                                                     includeColors: includeColors && format.supportsColor).byteString)
                }
            }
            .navigationTitle("Export Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { runExport() }
                        .disabled(isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Exporting \(format.displayName)…")
                            .padding(22)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .sheet(item: $result) { exported in
                ShareSheet(items: [exported.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .alert("Export Failed", isPresented: .init(get: { errorMessage != nil },
                                                       set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func runExport() {
        isWorking = true
        Task {
            do {
                let url = try await MeshExporter.export(mesh: mesh,
                                                        name: document.name,
                                                        format: format,
                                                        includeColors: includeColors && format.supportsColor)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                result = ExportResult(url: url, sizeBytes: (attributes?[.size] as? Int) ?? 0)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
