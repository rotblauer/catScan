import SwiftUI

/// Mesh resolution applied during post-processing.
enum MeshDetail: String, CaseIterable, Identifiable {
    case maximum, balanced, compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .maximum: return "Maximum"
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        }
    }

    var note: String {
        switch self {
        case .maximum: return "Keeps every triangle ARKit produces."
        case .balanced: return "Merges detail below 2 cm. Smaller files, still crisp."
        case .compact: return "Merges detail below 4 cm. Great for sharing rooms."
        }
    }

    var cellSize: Float? {
        switch self {
        case .maximum: return nil
        case .balanced: return 0.02
        case .compact: return 0.04
        }
    }
}

struct ScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(ScanStore.self) private var store

    /// When set, this session relocalizes into the reference scan's frame and
    /// the result is diffed against it ("Rescan & Compare").
    var referenceScan: ScanDocument?
    let onFinished: (ScanDocument) -> Void

    @State private var controller = ScanSessionController()
    @State private var showOptions = false
    @State private var confirmDiscard = false

    @AppStorage("catscan.colorize") private var colorize = true
    @AppStorage("catscan.classify") private var classify = true
    @AppStorage("catscan.detail") private var detailRaw = MeshDetail.maximum.rawValue
    @AppStorage("catscan.scanmode") private var scanModeRaw = ScanMode.room.rawValue
    @AppStorage("catscan.detailvolume") private var detailVolumeRaw = DetailVolume.medium.rawValue

    private var detail: MeshDetail { MeshDetail(rawValue: detailRaw) ?? .maximum }
    private var storedScanMode: ScanMode { ScanMode(rawValue: scanModeRaw) ?? .room }
    /// Rescans always run in Room mode so the diff compares like with like.
    private var scanMode: ScanMode { referenceScan != nil ? .room : storedScanMode }
    private var detailVolume: DetailVolume { DetailVolume(rawValue: detailVolumeRaw) ?? .medium }

    var body: some View {
        ZStack {
            if DeviceSupport.supportsLiDARScanning {
                ScannerSceneView(controller: controller,
                                 colorize: colorize,
                                 classify: classify,
                                 simplifyCell: detail.cellSize,
                                 scanMode: scanMode,
                                 detailVolume: detailVolume,
                                 referenceScan: referenceScan,
                                 referenceWorldMapURL: referenceScan.map { store.worldMapURL(for: $0) },
                                 referenceMeshURL: referenceScan.map { store.meshURL(for: $0) })
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ContentUnavailableView("LiDAR Required",
                                       systemImage: "camera.metering.unknown",
                                       description: Text("This device can't capture 3D scans."))
                    .foregroundStyle(.white)
            }

            overlays
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: controller.finishedDocument) { _, document in
            if let document {
                Haptics.success()
                dismiss()
                onFinished(document)
            }
        }
        .onChange(of: controller.momentLimitReached) { _, reached in
            if reached, case .scanning = controller.phase {
                controller.finishScan(store: store)
            }
        }
        .sheet(isPresented: $showOptions) {
            ScanOptionsSheet(colorize: $colorize,
                             classify: $classify,
                             detailRaw: $detailRaw,
                             scanModeRaw: $scanModeRaw,
                             detailVolumeRaw: $detailVolumeRaw)
                .presentationDetents([.medium, .large])
                .onDisappear {
                    controller.applySettingsAndRestart(colorize: colorize,
                                                       classify: classify,
                                                       simplifyCell: detail.cellSize,
                                                       mode: scanMode,
                                                       volume: detailVolume)
                }
        }
        .alert("Discard this scan?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) {
                controller.stopSession()
                dismiss()
            }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text("The mesh captured so far will be lost.")
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        switch controller.phase {
        case .ready:
            scanChrome(isScanning: false)
        case .scanning:
            scanChrome(isScanning: true)
        case .processing(let stage, let progress):
            ProcessingOverlay(stage: stage, progress: progress)
        case .failed(let message, let isCameraDenied):
            failureOverlay(message: message, isCameraDenied: isCameraDenied)
        }
    }

    private func scanChrome(isScanning: Bool) -> some View {
        VStack {
            HStack(spacing: 12) {
                CircleIconButton(systemImage: "xmark") {
                    if isScanning {
                        confirmDiscard = true
                    } else {
                        controller.stopSession()
                        dismiss()
                    }
                }
                Spacer()
                if scanMode != .moment {
                    CircleIconButton(systemImage: controller.overlayMode.systemImage) {
                        controller.cycleOverlayMode()
                    }
                }
                if controller.torchAvailable {
                    CircleIconButton(systemImage: controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                        controller.toggleTorch()
                    }
                }
                if !isScanning, referenceScan == nil {
                    CircleIconButton(systemImage: "gearshape.fill") { showOptions = true }
                }
            }
            .padding(.horizontal)

            if isScanning {
                statsChip
                    .padding(.top, 6)
            }

            if referenceScan != nil, !controller.isRelocalized {
                Label("Point at an area from the original scan…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.blue.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }

            if controller.overlayMode == .coverage {
                Text(isScanning ? "Green is captured — aim at red areas" : "Coverage paints in once you start scanning")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 6)
            }

            if let warning = controller.trackingWarning {
                Text(warning)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.top, 8)
            }

            Spacer()

            if isScanning {
                HStack(spacing: 24) {
                    CircleIconButton(systemImage: "arrow.counterclockwise") {
                        controller.resetScan()
                    }
                    Button {
                        controller.finishScan(store: store)
                    } label: {
                        Label("Finish", systemImage: "stop.fill")
                            .font(.headline)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 15)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    // Balance the reset button so Finish stays centered.
                    CircleIconButton(systemImage: "arrow.counterclockwise") {}
                        .hidden()
                }
                .padding(.bottom, 30)
            } else {
                VStack(spacing: 14) {
                    Text(hintText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                    Button {
                        controller.beginScan()
                    } label: {
                        Label(referenceScan == nil ? "Start Scanning" : "Start Rescan", systemImage: "record.circle")
                            .font(.headline)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 16)
                            .background(controller.isRelocalized ? Color.accentColor : Color.gray, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .disabled(!controller.isRelocalized)
                }
                .padding(.bottom, 30)
            }
        }
    }

    private var hintText: String {
        if referenceScan != nil {
            return controller.isRelocalized
                ? "Locked on! Re-scan the areas you want to compare."
                : "Walk to where the original scan started so CatScan can align to it."
        }
        switch scanMode {
        case .detail:
            return "Detail mode: aim at your subject — the capture box appears when you start."
        case .moment:
            return "Moment mode: film up to 10 seconds of moving 3D — hold steady or orbit slowly."
        case .room:
            return "Move slowly and keep the mesh overlay growing."
        }
    }

    private var statsChip: some View {
        HStack(spacing: 14) {
            Label(controller.stats.elapsed.clockString, systemImage: "timer")
            switch scanMode {
            case .moment:
                Label("\(controller.stats.momentFrames)/\(ScanSessionController.momentMaxFrames) fr", systemImage: "film")
                Label("\(controller.stats.momentPoints.abbreviated) pts", systemImage: "circle.dotted")
            case .detail:
                Label("\((controller.stats.tsdfBricks * 512).abbreviated) vox", systemImage: "cube.fill")
            case .room:
                Label("\(controller.stats.faceCount.abbreviated) tris", systemImage: "triangle")
            }
            if colorize, scanMode != .moment {
                Label("\(controller.stats.colorCellCount.abbreviated) colors", systemImage: "paintpalette")
            }
        }
        .font(.footnote.weight(.medium).monospacedDigit())
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    private func failureOverlay(message: String, isCameraDenied: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if isCameraDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try Again") { controller.retryAfterFailure() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Close") {
                controller.stopSession()
                dismiss()
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(28)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 22))
        .padding(30)
    }
}

// MARK: - Pieces

struct CircleIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
    }
}

struct ProcessingOverlay: View {
    let stage: String
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "cat.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating)
                Text(stage)
                    .font(.headline)
                    .foregroundStyle(.white)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .frame(width: 220)
                Text("\(Int(progress * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(30)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

struct ScanOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var colorize: Bool
    @Binding var classify: Bool
    @Binding var detailRaw: String
    @Binding var scanModeRaw: String
    @Binding var detailVolumeRaw: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Capture mode", selection: $scanModeRaw) {
                        ForEach(ScanMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    if scanModeRaw == ScanMode.detail.rawValue {
                        Picker("Volume", selection: $detailVolumeRaw) {
                            ForEach(DetailVolume.allCases) { volume in
                                Text(volume.label).tag(volume.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Capture mode")
                } footer: {
                    if scanModeRaw == ScanMode.detail.rawValue {
                        Text("Detail fuses raw depth frames inside a fixed box for 4–8 mm precision — far finer than ARKit's mesh. " +
                             (DetailVolume(rawValue: detailVolumeRaw) ?? .medium).note)
                    } else if scanModeRaw == ScanMode.moment.rawValue {
                        Text("Moment records a short volumetric video — a moving 3D point cloud you can orbit during playback and export as a spatial replay. Up to 10 seconds.")
                    } else {
                        Text("Room uses ARKit's scene mesh — unlimited size, ~2–5 cm features. Switch to Detail for small subjects.")
                    }
                }

                Section {
                    Toggle("Capture colors", isOn: $colorize)
                } footer: {
                    Text("Samples the camera image while you scan and paints the mesh with per-vertex colors.")
                }
                Section {
                    Toggle("Classify surfaces", isOn: $classify)
                } footer: {
                    Text("Labels faces as wall, floor, table, and so on. Adds a Classes view mode in the viewer.")
                }
                Section("Mesh detail") {
                    Picker("Detail", selection: $detailRaw) {
                        ForEach(MeshDetail.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text((MeshDetail(rawValue: detailRaw) ?? .maximum).note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scan Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
