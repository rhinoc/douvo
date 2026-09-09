import Foundation

private final class DouvoResourceBundleAnchor: NSObject {}

enum DouvoResourceLocator {
    static func url(forResource name: String, withExtension pathExtension: String) -> URL? {
        let resourceName = pathExtension.isEmpty ? name : "\(name).\(pathExtension)"
        let anchorBundle = Bundle(for: DouvoResourceBundleAnchor.self)
        let bundleCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Douvo_Douvo.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Douvo_Douvo.bundle"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Douvo_Douvo.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Douvo_Douvo.bundle"),
            anchorBundle.resourceURL?.appendingPathComponent("Douvo_Douvo.bundle"),
            anchorBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Douvo_Douvo.bundle"),
            anchorBundle.bundleURL.appendingPathComponent("Douvo_Douvo.bundle")
        ]

        var checkedPaths = Set<String>()
        for bundleURL in bundleCandidates.compactMap({ $0 }) {
            guard checkedPaths.insert(bundleURL.path).inserted else { continue }
            let resourceURL = bundleURL.appendingPathComponent(resourceName)
            if FileManager.default.isReadableFile(atPath: resourceURL.path) {
                return resourceURL
            }
        }

        let directCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent(resourceName),
            Bundle.main.bundleURL.appendingPathComponent(resourceName),
            anchorBundle.resourceURL?.appendingPathComponent(resourceName),
            anchorBundle.bundleURL.appendingPathComponent(resourceName)
        ]
        for resourceURL in directCandidates.compactMap({ $0 }) {
            guard checkedPaths.insert(resourceURL.path).inserted else { continue }
            if FileManager.default.isReadableFile(atPath: resourceURL.path) {
                return resourceURL
            }
        }

        AppLog.error("Resource missing name=\(resourceName) checkedPaths=\(checkedPaths.sorted())")
        return nil
    }
}
