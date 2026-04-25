import Testing
import Foundation
@testable import MockerKit

@Suite("ContainerEngine Tests")
struct ContainerEngineTests {

    @Test("Create throws unsupported error")
    func testCreateUnsupported() async throws {
        let config = MockerConfig()
        try config.ensureDirectories()
        let engine = try ContainerEngine(config: config)
        let containerConfig = ContainerConfig(image: "alpine:latest")

        do {
            _ = try await engine.create(containerConfig)
            #expect(Bool(false), "create should have thrown")
        } catch {
            let msg = "\(error)"
            #expect(msg.contains("not supported"))
        }
    }

    @Test("Pause throws unsupported error")
    func testPauseUnsupported() async throws {
        let config = MockerConfig()
        try config.ensureDirectories()
        let engine = try ContainerEngine(config: config)

        do {
            try await engine.pause("nonexistent")
            #expect(Bool(false), "pause should have thrown")
        } catch let error as MockerError {
            switch error {
            case .containerNotFound:
                break // Expected: container doesn't exist
            case .operationFailed(let msg):
                #expect(msg.contains("not supported"))
            default:
                #expect(Bool(false), "Unexpected error: \(error)")
            }
        }
    }

    @Test("Unpause throws unsupported error")
    func testUnpauseUnsupported() async throws {
        let config = MockerConfig()
        try config.ensureDirectories()
        let engine = try ContainerEngine(config: config)

        do {
            try await engine.unpause("nonexistent")
            #expect(Bool(false), "unpause should have thrown")
        } catch let error as MockerError {
            switch error {
            case .containerNotFound:
                break // Expected
            case .operationFailed(let msg):
                #expect(msg.contains("not supported"))
            default:
                #expect(Bool(false), "Unexpected error: \(error)")
            }
        }
    }

    @Test("Rename throws unsupported error")
    func testRenameUnsupported() async throws {
        let config = MockerConfig()
        try config.ensureDirectories()
        let engine = try ContainerEngine(config: config)

        do {
            try await engine.rename("nonexistent", to: "newname")
            #expect(Bool(false), "rename should have thrown")
        } catch let error as MockerError {
            switch error {
            case .containerNotFound:
                break // Expected
            case .operationFailed(let msg):
                #expect(msg.contains("not supported"))
            default:
                #expect(Bool(false), "Unexpected error: \(error)")
            }
        }
    }

    @Test("ContainerConfig default values")
    func testContainerConfigDefaults() {
        let config = ContainerConfig(image: "nginx:latest")
        #expect(config.image == "nginx:latest")
        #expect(config.command.isEmpty)
        #expect(config.environment.isEmpty)
        #expect(config.ports.isEmpty)
        #expect(config.rm == false)
        #expect(config.cidfile == nil)
        #expect(config.dnsSearch.isEmpty)
        #expect(config.dnsOption.isEmpty)
        #expect(config.interactive == false)
        #expect(config.tty == false)
        #expect(config.virtualization == false)
        #expect(config.kernel == nil)
    }

    @Test("ContainerConfig with all new fields")
    func testContainerConfigNewFields() {
        let config = ContainerConfig(
            image: "alpine",
            interactive: true,
            tty: true,
            virtualization: true,
            kernel: "/tmp/vmlinux",
            memory: "512m",
            cpus: "2",
            cidfile: "/tmp/cid",
            rm: true,
            dnsSearch: ["example.com"],
            dnsOption: ["ndots:5"]
        )
        #expect(config.rm == true)
        #expect(config.cidfile == "/tmp/cid")
        #expect(config.dnsSearch == ["example.com"])
        #expect(config.dnsOption == ["ndots:5"])
        #expect(config.interactive == true)
        #expect(config.tty == true)
        #expect(config.memory == "512m")
        #expect(config.cpus == "2")
        #expect(config.virtualization == true)
        #expect(config.kernel == "/tmp/vmlinux")
    }

    @Test("Run arguments include nested virtualization flags")
    func testRunArgumentsIncludeVirtualizationFlags() {
        let config = ContainerConfig(
            image: "ubuntu:latest",
            command: ["sh", "-c", "dmesg | grep kvm"],
            virtualization: true,
            kernel: "/path/to/kernel"
        )

        let args = ContainerEngine.buildRunArguments(name: "nested-virtualization", config: config)

        #expect(args.contains("--virtualization"))
        #expect(args.contains("--kernel"))
        #expect(args.contains("/path/to/kernel"))
    }

    @Test("Container CLI resolver prefers Homebrew installation")
    func testContainerCLIResolverPrefersHomebrew() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mocker-container-cli-\(UUID().uuidString)")
        let homebrewBin = root.appendingPathComponent("opt/homebrew/bin", isDirectory: true)
        let localBin = root.appendingPathComponent("usr/local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homebrewBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)

        let homebrewContainer = homebrewBin.appendingPathComponent("container")
        let localContainer = localBin.appendingPathComponent("container")
        FileManager.default.createFile(atPath: homebrewContainer.path, contents: Data())
        FileManager.default.createFile(atPath: localContainer.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: homebrewContainer.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localContainer.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = RootedFileManager(root: root.path)
        let resolved = ContainerEngine.resolveContainerCLI(fileManager: fileManager)

        #expect(resolved == "/opt/homebrew/bin/container")
    }
}

private final class RootedFileManager: FileManager, @unchecked Sendable {
    private let root: String

    init(root: String) {
        self.root = root
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        super.isExecutableFile(atPath: root + path)
    }
}
