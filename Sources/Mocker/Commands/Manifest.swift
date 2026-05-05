import ArgumentParser
import Foundation
import MockerKit

struct ManifestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Manage OCI image manifests and manifest lists",
        subcommands: [
            ManifestInspect.self,
        ],
        defaultSubcommand: ManifestInspect.self
    )
}

struct ManifestInspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Display an image's manifest list (OCI image index)"
    )

    @Argument(help: "Image reference (e.g., myrepo/multi:latest)")
    var manifestList: String

    func run() async throws {
        let config = MockerConfig()
        let manager = try ManifestManager(config: config)
        let json = try await manager.inspect(manifestList)
        if let pretty = String(data: json, encoding: .utf8) {
            print(pretty)
        }
    }
}
