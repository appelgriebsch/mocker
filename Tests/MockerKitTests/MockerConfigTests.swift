import Testing
import Foundation
@testable import MockerKit

@Suite("MockerConfig Tests")
struct MockerConfigTests {

    @Test("appleContainerStorePath returns nil when nothing exists")
    func appleStoreAbsent() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mocker-config-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let resolved = MockerConfig.appleContainerStorePath(
            fileManager: .default,
            homeDirectory: tmpHome.path
        )
        #expect(resolved == nil)
    }

    @Test("appleContainerStorePath detects state.json")
    func appleStoreFromStateJSON() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mocker-config-state-\(UUID().uuidString)")
        let storeRoot = tmpHome
            .appendingPathComponent("Library/Application Support/com.apple.container")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: storeRoot.appendingPathComponent("state.json").path,
            contents: Data("{}".utf8)
        )
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let resolved = MockerConfig.appleContainerStorePath(
            fileManager: .default,
            homeDirectory: tmpHome.path
        )
        #expect(resolved?.path == storeRoot.path)
    }

    @Test("appleContainerStorePath detects content directory")
    func appleStoreFromContentDir() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mocker-config-content-\(UUID().uuidString)")
        let contentDir = tmpHome
            .appendingPathComponent("Library/Application Support/com.apple.container/content")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let resolved = MockerConfig.appleContainerStorePath(
            fileManager: .default,
            homeDirectory: tmpHome.path
        )
        #expect(resolved != nil)
        #expect(resolved?.lastPathComponent == "com.apple.container")
    }
}
