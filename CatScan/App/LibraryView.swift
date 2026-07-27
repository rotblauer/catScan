import SwiftUI

/// Lets any descendant (the viewer, context menus) launch a Rescan & Compare
/// session; LibraryView owns the actual scanner presentation.
private struct RescanActionKey: EnvironmentKey {
    static let defaultValue: (ScanDocument) -> Void = { _ in }
}

extension EnvironmentValues {
    var rescanAction: (ScanDocument) -> Void {
        get { self[RescanActionKey.self] }
        set { self[RescanActionKey.self] = newValue }
    }
}

struct LibraryView: View {
    @Environment(ScanStore.self) private var store

    @State private var path: [ScanDocument] = []
    @State private var showScanner = false
    @State private var rescanTarget: ScanDocument?
    @State private var showUnsupported = false
    @State private var renameTarget: ScanDocument?
    @State private var renameText = ""
    @State private var deleteTarget: ScanDocument?
    @State private var buildingSample = false
    @State private var toast: ToastState?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("CatScan")
            .navigationDestination(for: ScanDocument.self) { document in
                ModelViewerView(document: document)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            addSample()
                        } label: {
                            Label("Add Sample Scan", systemImage: "cube.transparent")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !store.scans.isEmpty { scanButton }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerView { document in
                path.append(document)
            }
        }
        .fullScreenCover(item: $rescanTarget) { reference in
            ScannerView(referenceScan: reference) { document in
                path.append(document)
            }
        }
        .environment(\.rescanAction) { document in
            if DeviceSupport.supportsLiDARScanning {
                rescanTarget = document
            } else {
                showUnsupported = true
            }
        }
        .sheet(isPresented: $showUnsupported) {
            UnsupportedDeviceView { addSample() }
                .presentationDetents([.medium, .large])
        }
        .overlay {
            if buildingSample {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("Winding up the yarn ball…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Rename Scan", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    store.rename(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete this scan?",
                            isPresented: deletePresented,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    store.delete(target)
                }
                deleteTarget = nil
            }
        } message: {
            Text("This permanently removes the scan and its files from this device.")
        }
        .toast($toast)
        #if DEBUG
        .task {
            DebugAutomation.runIfRequested(store: store)
            if DebugAutomation.wantsOpenFirst, path.isEmpty,
               let first = store.scans.first(where: { $0.isMoment }) ?? store.scans.first {
                path.append(first)
            }
        }
        #endif
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - Content

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                ForEach(store.scans) { document in
                    NavigationLink(value: document) {
                        ScanCard(document: document, thumbnailURL: store.thumbnailURL(for: document))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            path.append(document)
                        } label: {
                            Label("View", systemImage: "eye")
                        }
                        Button {
                            renameTarget = document
                            renameText = document.name
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteTarget = document
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cat.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("No Scans Yet")
                .font(.title2.bold())
            Text("Capture your world in 3D with the LiDAR sensor, then view, export, and share your scans.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            VStack(spacing: 12) {
                Button {
                    startScan()
                } label: {
                    Label("New Scan", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    addSample()
                } label: {
                    Label("Add a Sample Scan", systemImage: "cube.transparent")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 44)
            Spacer()
            Spacer()
        }
    }

    private var scanButton: some View {
        Button {
            startScan()
        } label: {
            Label("New Scan", systemImage: "viewfinder")
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.black)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .padding(.bottom, 6)
    }

    // MARK: - Actions

    private func startScan() {
        if DeviceSupport.supportsLiDARScanning {
            showScanner = true
        } else {
            showUnsupported = true
        }
    }

    private func addSample() {
        guard !buildingSample else { return }
        buildingSample = true
        Task {
            do {
                let document = try await store.addSampleScan()
                buildingSample = false
                path.append(document)
            } catch {
                buildingSample = false
                toast = ToastState(message: error.localizedDescription, isError: true)
            }
        }
    }
}

// MARK: - Card

struct ScanCard: View {
    let document: ScanDocument
    let thumbnailURL: URL

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "cat")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(document.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack {
                Text(document.createdAt, format: .dateTime.month(.abbreviated).day())
                Spacer()
                if document.isMoment {
                    Label(String(format: "%.1f s", document.duration), systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text("\(document.faceCount.abbreviated) tris")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .task(id: document.id) {
            guard thumbnail == nil else { return }
            let url = thumbnailURL
            thumbnail = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
    }
}
