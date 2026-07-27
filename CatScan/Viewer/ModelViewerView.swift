import SceneKit
import SwiftUI

struct ModelViewerView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rescanAction) private var rescanAction

    let document: ScanDocument

    @State private var mesh: MeshData?
    @State private var diff: (added: [Bool], removed: MeshData)?
    @State private var momentClip: MomentClip?
    @State private var loadError: String?
    @State private var mode: ViewerDisplayMode = .shaded
    @State private var proxy = SCNViewProxy()
    @State private var toast: ToastState?

    @State private var showExport = false
    @State private var showInfo = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
    @State private var preparingAR = false

    @State private var turntable: TurntableRenderer?
    @State private var momentVideo: MomentVideoRenderer?
    @State private var showTurntable = false

    /// Live copy so renames show immediately.
    private var currentDocument: ScanDocument {
        store.scans.first { $0.id == document.id } ?? document
    }

    var body: some View {
        ZStack {
            if let momentClip {
                MomentPlayerView(clip: momentClip, colorScheme: colorScheme, proxy: proxy)
            } else if let mesh, !currentDocument.isMoment {
                SceneKitViewer(mesh: mesh, mode: mode, colorScheme: colorScheme, proxy: proxy, diff: diff)
                    .ignoresSafeArea(edges: .bottom)
            } else if let loadError {
                ContentUnavailableView("Couldn't Load Scan",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView("Loading scan…")
            }
        }
        .navigationTitle(currentDocument.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        proxy.resetCamera()
                    } label: {
                        Label("Reset Camera", systemImage: "camera.rotate")
                    }
                    Button {
                        renameText = currentDocument.name
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if store.hasWorldMap(for: currentDocument) {
                        Button {
                            rescanAction(currentDocument)
                        } label: {
                            Label("Rescan & Compare", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Scan", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if momentClip != nil {
                momentControls
            } else if mesh != nil, !currentDocument.isMoment {
                controls
            }
        }
        .task { await loadMesh() }
        .sheet(isPresented: $showExport) {
            if let mesh {
                ExportSheet(document: currentDocument, mesh: mesh)
            }
        }
        .sheet(isPresented: $showInfo) {
            ScanInfoSheet(document: currentDocument)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTurntable) {
            RenderProgressSheet(title: currentDocument.isMoment ? "Rendering Spatial Replay" : "Rendering Turntable",
                                progress: turntable?.progress ?? momentVideo?.progress ?? 0) {
                turntable?.cancel()
                momentVideo?.cancel()
            }
            .presentationDetents([.height(190)])
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showQuickLook) {
            if let quickLookURL {
                ARQuickLookView(url: quickLookURL)
                    .ignoresSafeArea()
            }
        }
        .alert("Rename Scan", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { store.rename(currentDocument, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(currentDocument)
                dismiss()
            }
        } message: {
            Text("This permanently removes the scan and its files from this device.")
        }
        .toast($toast)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if mode == .classification, let mesh {
                ClassificationLegend(classes: SceneKitSupport.presentClasses(in: mesh))
            }
            if mode == .changes {
                ChangesLegend(document: currentDocument)
            }
            if let mesh {
                Picker("Display mode", selection: $mode) {
                    ForEach(ViewerDisplayMode.available(for: mesh, hasDiff: diff != nil)) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack(spacing: 0) {
                viewerAction("Photo", systemImage: "camera.fill", action: saveSnapshot)
                viewerAction("Video", systemImage: "arrow.triangle.2.circlepath.camera.fill", action: saveTurntable)
                viewerAction("AR", systemImage: "arkit", busy: preparingAR, action: viewInAR)
                viewerAction("Export", systemImage: "square.and.arrow.up") { showExport = true }
                viewerAction("Info", systemImage: "info.circle") { showInfo = true }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private var momentControls: some View {
        HStack(spacing: 0) {
            viewerAction("Photo", systemImage: "camera.fill", action: saveSnapshot)
            viewerAction("Video", systemImage: "arrow.triangle.2.circlepath.camera.fill", action: saveMomentVideo)
            viewerAction("Info", systemImage: "info.circle") { showInfo = true }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private func saveMomentVideo() {
        guard let momentClip else { return }
        let renderer = MomentVideoRenderer()
        momentVideo = renderer
        showTurntable = true
        Task {
            do {
                let url = try await renderer.render(clip: momentClip)
                try await PhotoSaver.save(videoAt: url)
                try? FileManager.default.removeItem(at: url)
                showTurntable = false
                Haptics.success()
                toast = ToastState(message: "Spatial replay saved to Photos")
            } catch is CancellationError {
                showTurntable = false
            } catch {
                showTurntable = false
                toast = ToastState(message: error.localizedDescription, isError: true)
            }
            momentVideo = nil
        }
    }

    private func viewerAction(_ title: String, systemImage: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if busy {
                    ProgressView()
                        .frame(height: 22)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 19))
                        .frame(height: 22)
                }
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(busy)
    }

    // MARK: - Actions

    private func loadMesh() async {
        guard mesh == nil, momentClip == nil else { return }
        let doc = document
        let store = self.store
        do {
            if doc.isMoment {
                momentClip = try await Task.detached(priority: .userInitiated) {
                    try store.loadMomentClip(for: doc)
                }.value
                return
            }
            let loaded = try await Task.detached(priority: .userInitiated) {
                try store.loadMesh(for: doc)
            }.value
            mesh = loaded
            if doc.hasDiff, store.hasDiffFiles(for: doc) {
                diff = try? await Task.detached(priority: .userInitiated) {
                    try store.loadDiff(for: doc)
                }.value
                if diff != nil, mode == .shaded {
                    mode = .changes   // a rescan's whole point is the comparison
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveSnapshot() {
        guard let image = proxy.snapshot() else {
            toast = ToastState(message: "Couldn't capture the view", isError: true)
            return
        }
        Task {
            do {
                try await PhotoSaver.save(image: image)
                Haptics.success()
                toast = ToastState(message: "Snapshot saved to Photos")
            } catch {
                toast = ToastState(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func saveTurntable() {
        guard let mesh else { return }
        let renderer = TurntableRenderer()
        turntable = renderer
        showTurntable = true
        Task {
            do {
                let url = try await renderer.render(mesh: mesh)
                try await PhotoSaver.save(videoAt: url)
                try? FileManager.default.removeItem(at: url)
                showTurntable = false
                Haptics.success()
                toast = ToastState(message: "Turntable video saved to Photos")
            } catch is CancellationError {
                showTurntable = false
            } catch {
                showTurntable = false
                toast = ToastState(message: error.localizedDescription, isError: true)
            }
            turntable = nil
        }
    }

    private func viewInAR() {
        guard let mesh else { return }
        preparingAR = true
        let doc = currentDocument
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try USDZExporter.cachedUSDZ(for: doc, mesh: mesh)
                }.value
                quickLookURL = url
                showQuickLook = true
            } catch {
                toast = ToastState(message: "Couldn't prepare the AR model: \(error.localizedDescription)", isError: true)
            }
            preparingAR = false
        }
    }
}

// MARK: - Pieces

struct ChangesLegend: View {
    let document: ScanDocument

    var body: some View {
        HStack(spacing: 10) {
            legendChip(color: Color(red: 0.19, green: 0.82, blue: 0.35),
                       label: document.diffAddedArea.map { String(format: "Added %.2f m²", $0) } ?? "Added")
            legendChip(color: Color(red: 1.0, green: 0.27, blue: 0.23),
                       label: document.diffRemovedArea.map { String(format: "Removed %.2f m²", $0) } ?? "Removed")
            legendChip(color: Color(white: 0.72), label: "Unchanged")
        }
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }
}

struct ClassificationLegend: View {
    let classes: [SurfaceClass]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(classes, id: \.rawValue) { surfaceClass in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(uiColor: surfaceClass.color))
                            .frame(width: 9, height: 9)
                        Text(surfaceClass.label)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                }
            }
        }
    }
}

struct RenderProgressSheet: View {
    let title: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 240)
            Text("\(Int(progress * 100))%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        }
        .padding()
    }
}
