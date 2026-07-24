import Photos
import UIKit

enum PhotoSaverError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        "Photos access is off. Allow \"Add Photos Only\" for CatScan in Settings → Privacy & Security → Photos."
    }
}

enum PhotoSaver {

    private static func ensureAccess() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw PhotoSaverError.accessDenied
        }
    }

    static func save(image: UIImage) async throws {
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func save(videoAt url: URL) async throws {
        try await ensureAccess()
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
