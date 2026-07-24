import SwiftUI

/// Shown when the user taps Scan on a device without LiDAR (or in the simulator).
struct UnsupportedDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let onAddSample: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 28)
            Text("LiDAR Required")
                .font(.title2.bold())
            Text("Scanning needs a LiDAR sensor, found on iPhone Pro models (iPhone 12 Pro and later) and iPad Pro (2020 and later). Everything else — the viewer, exports, and Photos features — works right here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                dismiss()
                onAddSample()
            } label: {
                Label("Add a Sample Scan", systemImage: "cube.transparent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            Button("Not Now") { dismiss() }
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
