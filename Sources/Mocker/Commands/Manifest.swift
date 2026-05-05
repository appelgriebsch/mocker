import ArgumentParser
import Foundation
import MockerKit

struct ManifestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Manage OCI image manifests and manifest lists",
        subcommands: [
            ManifestInspect.self,
            ManifestCreate.self,
        ],
        defaultSubcommand: ManifestInspect.self
    )
}

struct ManifestCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a manifest list (OCI image index) from existing local images"
    )

    @Argument(help: "Name for the new manifest list (e.g., myrepo/multi:latest)")
    var manifestList: String

    @Argument(help: "Child image references to include (one per platform)")
    var manifests: [String] = []

    @Flag(name: [.long, .customLong("amend")], help: "Replace an existing manifest list with the same name")
    var replace: Bool = false

    func run() async throws {
        guard !manifests.isEmpty else {
            throw ValidationError("at least one child manifest reference is required")
        }
        let config = MockerConfig()
        let manager = try ManifestManager(config: config)
        let json = try await manager.create(name: manifestList, children: manifests, replace: replace)
        if let pretty = String(data: json, encoding: .utf8) {
            print(pretty)
        }
        print("Created manifest list \(manifestList)")
    }
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
