import Foundation

struct LocalMLXRuntimeDiagnostic: Sendable {
    let isAvailable: Bool
    let message: String
    let detail: String

    static func current() -> LocalMLXRuntimeDiagnostic {
        let candidates = metallibCandidateURLs()
        if let existingURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return LocalMLXRuntimeDiagnostic(
                isAvailable: true,
                message: L10n.text(en: "Ready", zh: "已就绪"),
                detail: existingURL.path
            )
        }

        return LocalMLXRuntimeDiagnostic(
            isAvailable: false,
            message: L10n.text(en: "Missing Metal Library", zh: "缺少 Metal Library"),
            detail: L10n.text(en: "Checked \(candidates.count) expected locations for default.metallib or mlx.metallib.", zh: "已检查 \(candidates.count) 个 default.metallib 或 mlx.metallib 可能位置。")
        )
    }

    private static func metallibCandidateURLs() -> [URL] {
        var urls: [URL] = []

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executableDirectory.appendingPathComponent("mlx.metallib"))
            urls.append(executableDirectory.appendingPathComponent("Resources/mlx.metallib"))
            urls.append(executableDirectory.appendingPathComponent("default.metallib"))
            urls.append(executableDirectory.appendingPathComponent("Resources/default.metallib"))
        }

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("mlx.metallib"))
            urls.append(resourceURL.appendingPathComponent("default.metallib"))
            urls.append(resourceURL.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"))
        }

        urls.append(Bundle.main.bundleURL.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"))

        for bundle in Bundle.allBundles {
            if let resourceURL = bundle.resourceURL {
                urls.append(resourceURL.appendingPathComponent("default.metallib"))
                urls.append(resourceURL.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"))
            }
        }

        return Array(Set(urls)).sorted { $0.path < $1.path }
    }
}
