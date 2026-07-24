import QuickLook
import SwiftUI

/// Presents a USDZ file in AR Quick Look (object mode in the simulator,
/// full AR placement on device).
struct ARQuickLookView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QuickLookContainer(url: url)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

private struct QuickLookContainer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: PreviewItem

        init(url: URL) {
            item = PreviewItem(url: url)
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            item
        }
    }

    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL) {
            previewItemURL = url
            previewItemTitle = url.deletingPathExtension().lastPathComponent
        }
    }
}
