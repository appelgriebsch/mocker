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
            ManifestAdd.self,
            ManifestRm.self,
            ManifestAnnotate.self,
            ManifestPush.self,
        ],
        defaultSubcommand: ManifestInspect.self
    )
}

struct ManifestAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a child image's platforms to an existing manifest list"
    )

    @Argument(help: "Name of the existing manifest list")
    var manifestList: String

    @Argument(help: "Child image reference to add")
    var manifest: String

    func run() async throws {
        let manager = try ManifestManager(config: MockerConfig())
        let json = try await manager.add(list: manifestList, child: manifest)
        if let pretty = String(data: json, encoding: .utf8) { print(pretty) }
        print("Updated manifest list \(manifestList)")
    }
}

struct ManifestRm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a platform or digest from a manifest list"
    )

    @Argument(help: "Name of the manifest list")
    var manifestList: String

    @Argument(help: "Platform spec (linux/amd64) or manifest digest (sha256:...) to remove")
    var target: String

    func run() async throws {
        let manager = try ManifestManager(config: MockerConfig())
        let json = try await manager.remove(list: manifestList, target: target)
        if let pretty = String(data: json, encoding: .utf8) { print(pretty) }
        print("Updated manifest list \(manifestList)")
    }
}

struct ManifestAnnotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotate",
        abstract: "Override platform metadata for an entry in a manifest list"
    )

    @Argument(help: "Name of the manifest list")
    var manifestList: String

    @Argument(help: "Child image reference whose entry to annotate (must be single-platform)")
    var manifest: String

    @Option(name: .long, help: "Override OS (e.g., linux)")
    var os: String?

    @Option(name: .long, help: "Override architecture (e.g., amd64, arm64)")
    var arch: String?

    @Option(name: .long, help: "Override variant (e.g., v8)")
    var variant: String?

    func run() async throws {
        let manager = try ManifestManager(config: MockerConfig())
        let json = try await manager.annotate(
            list: manifestList,
            child: manifest,
            os: os,
            arch: arch,
            variant: variant
        )
        if let pretty = String(data: json, encoding: .utf8) { print(pretty) }
        print("Updated manifest list \(manifestList)")
    }
}

struct ManifestPush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push a manifest list to its registry"
    )

    @Argument(help: "Name of the manifest list to push (e.g., myrepo/multi:latest)")
    var manifestList: String

    func run() async throws {
        let manager = try ManifestManager(config: MockerConfig())
        try await manager.push(manifestList)
        print("Pushed manifest list \(manifestList)")
    }
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
