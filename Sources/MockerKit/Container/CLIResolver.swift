import Foundation

/// Resolves the path to Apple's `container` CLI binary.
///
/// Lookup order:
///   1. `MOCKER_CONTAINER_CLI` environment override (if executable)
///   2. `PATH` lookup
///   3. Known install locations (Homebrew, then `/usr/local/bin`)
///   4. Final fallback: `/usr/local/bin/container`
public enum CLIResolver {
    public static let envOverride = "MOCKER_CONTAINER_CLI"

    public static let fallbackPaths = [
        "/opt/homebrew/bin/container",
        "/opt/homebrew/opt/container/bin/container",
        "/usr/local/bin/container",
    ]

    public static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let raw = environment[envOverride] {
            let override = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty, fileManager.isExecutableFile(atPath: override) {
                return override
            }
        }

        if let path = environment["PATH"], !path.isEmpty {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = "\(dir)/container"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        if let hit = fallbackPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return hit
        }

        return "/usr/local/bin/container"
    }
}
