import SwiftUI
import UIKit

extension Int {
    /// 1234 → "1k", 2_400_000 → "2.4M"
    var abbreviated: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.0fk", Double(self) / 1_000) }
        return "\(self)"
    }

    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}

extension TimeInterval {
    /// 83 → "1:23"
    var clockString: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension String {
    var sanitizedForFilename: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Scan" : cleaned
    }
}

enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

enum AppGradients {
    private static func gradient(top: UIColor, bottom: UIColor) -> UIImage {
        let size = CGSize(width: 8, height: 512)
        return UIGraphicsImageRenderer(size: size).image { context in
            guard let cgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                              colors: [top.cgColor, bottom.cgColor] as CFArray,
                                              locations: [0, 1]) else { return }
            context.cgContext.drawLinearGradient(cgGradient,
                                                 start: .zero,
                                                 end: CGPoint(x: 0, y: size.height),
                                                 options: [])
        }
    }

    static let dark = gradient(top: UIColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1),
                               bottom: UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))

    static let light = gradient(top: UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1),
                                bottom: UIColor(red: 0.83, green: 0.85, blue: 0.89, alpha: 1))

    static let thumbnailBackground = gradient(top: UIColor(red: 0.19, green: 0.20, blue: 0.26, alpha: 1),
                                              bottom: UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1))

    static func viewerBackground(dark isDark: Bool) -> UIImage {
        isDark ? dark : light
    }
}
