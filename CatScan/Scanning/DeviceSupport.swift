import ARKit

enum DeviceSupport {
    /// True on LiDAR-equipped devices (iPhone 12 Pro and later Pro models, iPad Pro 2020+).
    static var supportsLiDARScanning: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var supportsClassification: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }
}
