import Foundation
import Containerization
import ContainerizationOCI

/// Read-only inspection of OCI image indexes (manifest lists).
///
/// Wraps `Containerization.ImageStore` so callers can pretty-print the manifest list
/// for a multi-architecture image — the equivalent of `docker manifest inspect`.
public actor ManifestManager {
    private let imageStore: Containerization.ImageStore

    public init(config: MockerConfig = MockerConfig()) throws {
        self.imageStore = try Containerization.ImageStore(path: config.ociStorePath)
    }

    /// Decode the OCI index for an image reference and return its JSON representation.
    /// Throws `MockerError.imageNotFound` if the reference is not in the local store,
    /// or `MockerError.operationFailed` if the underlying blob isn't an index/manifest list.
    public func inspect(_ reference: String) async throws -> Data {
        // Apple's container CLI stores some references verbatim (e.g. "myimg:v1") while
        // others are fully normalized ("docker.io/library/myimg:v1"). Try the verbatim
        // form first — falling back to the normalized form keeps mocker's view aligned
        // with `container image inspect` even when the input cannot be parsed as a full
        // reference (e.g. ad-hoc local tags built without a registry).
        var candidates = [reference]
        if let normalized = try? Self.normalize(reference), normalized != reference {
            candidates.append(normalized)
        }
        var image: Containerization.Image?
        for candidate in candidates {
            if let hit = try? await imageStore.get(reference: candidate) {
                image = hit
                break
            }
        }
        guard let image else {
            throw MockerError.imageNotFound(reference)
        }

        let mediaType = image.mediaType
        guard mediaType == MediaTypes.index || mediaType == MediaTypes.dockerManifestList else {
            throw MockerError.operationFailed(
                "image \(reference) is not a manifest list (mediaType: \(mediaType))"
            )
        }

        let index = try await image.index()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(index)
    }

    private static func normalize(_ reference: String) throws -> String {
        var fullRef = reference
        let parts = reference.split(separator: "/", maxSplits: 1)
        if parts.count == 1 {
            fullRef = "docker.io/library/\(reference)"
        } else {
            let domain = String(parts[0])
            let looksLikeDomain = domain.contains(".") || domain.contains(":") || domain == "localhost"
            if !looksLikeDomain {
                fullRef = "docker.io/\(reference)"
            }
        }
        let ref = try ContainerizationOCI.Reference.parse(fullRef)
        ref.normalize()
        return ref.description
    }
}
