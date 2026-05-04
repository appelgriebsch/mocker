import Testing
import ArgumentParser
@testable import Mocker

@Suite("CLI Tests")
struct CLITests {
    @Test("Mocker version is defined and consistent")
    func version() {
        let version = Version.currentVersion
        #expect(!version.isEmpty)
        #expect(version == "0.2.0")
    }

    @Test("Run command accepts --env-file flag")
    func runEnvFileFlag() throws {
        let command = try Run.parse(["--env-file", "test.env", "alpine"])
        #expect(command.envFile == "test.env")
        #expect(command.image == "alpine")
    }

    @Test("Run command accepts nested virtualization flags")
    func runVirtualizationFlags() throws {
        let command = try Run.parse(["--virtualization", "--kernel", "/tmp/vmlinux", "ubuntu:latest"])
        #expect(command.virtualization == true)
        #expect(command.kernel == "/tmp/vmlinux")
        #expect(command.image == "ubuntu:latest")
    }

    @Test("Create command accepts nested virtualization flags")
    func createVirtualizationFlags() throws {
        let command = try Create.parse(["--virtualization", "--kernel", "/tmp/vmlinux", "ubuntu:latest"])
        #expect(command.virtualization == true)
        #expect(command.kernel == "/tmp/vmlinux")
        #expect(command.image == "ubuntu:latest")
    }

    @Test("Pull command accepts --platform flag")
    func pullPlatformFlag() throws {
        let command = try Pull.parse(["--platform", "linux/amd64", "alpine:latest"])
        #expect(command.platform == "linux/amd64")
        #expect(command.image == "alpine:latest")
    }

    @Test("Pull command leaves platform nil when omitted")
    func pullPlatformDefaultsNil() throws {
        let command = try Pull.parse(["alpine:latest"])
        #expect(command.platform == nil)
    }

    @Test("Push command accepts --platform flag")
    func pushPlatformFlag() throws {
        let command = try Push.parse(["--platform", "linux/arm64", "myrepo/app:1.0"])
        #expect(command.platform == "linux/arm64")
        #expect(command.image == "myrepo/app:1.0")
    }
}
