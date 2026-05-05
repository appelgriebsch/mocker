import Foundation
import Containerization
import ContainerizationOCI

/// Read-only inspection and assembly of OCI image indexes (manifest lists).
///
/// Wraps `Containerization.ImageStore` so callers can pretty-print or build the manifest list
/// for a multi-architecture image — the equivalent of `docker manifest inspect`/`create`.
public actor ManifestManager {
    private let imageStore: Containerization.ImageStore
    private let storePath: URL

    public init(config: MockerConfig = MockerConfig()) throws {
        self.storePath = config.ociStorePath
        self.imageStore = try Containerization.ImageStore(path: storePath)
    }

    /// Decode the OCI index for an image reference and return its JSON representation.
    /// Throws `MockerError.imageNotFound` if the reference is not in the local store,
    /// or `MockerError.operationFailed` if the underlying blob isn't an index/manifest list.
    public func inspect(_ reference: String) async throws -> Data {
        // Apple's container CLI stores some references verbatim (e.g. "myimg:v1") while
        // others are fully normalized ("docker.io/library/myimg:v1"). resolveImage tries
        // the verbatim form first then the normalized form so mocker stays aligned with
        // `container image inspect` even for ad-hoc local tags.
        let image = try await resolveImage(reference)

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

    /// Create a manifest list (OCI image index) from existing local images.
    ///
    /// For each `child` reference, this looks up the image in the local store, reads its
    /// OCI index, and copies image-manifest descriptors (skipping attestations and other
    /// artifact types) into a new index. Duplicate platforms are kept in first-seen order —
    /// the caller controls precedence by ordering `children`.
    ///
    /// The new index is written to the local content store and registered under `name`.
    /// Fails if `name` already exists (pass `replace: true` to overwrite), if a child is
    /// missing or not a manifest list, or if no usable platform descriptors are found.
    @discardableResult
    public func create(name: String, children: [String], replace: Bool = false) async throws -> Data {
        guard !children.isEmpty else {
            throw MockerError.operationFailed("manifest create requires at least one child reference")
        }

        // Validate target name and check for existing reference *before* writing anything.
        let normalizedName = try Self.normalize(name)
        if !replace, (try? await imageStore.get(reference: normalizedName)) != nil {
            throw MockerError.operationFailed(
                "image \(name) already exists; pass --replace to overwrite"
            )
        }

        var seenPlatforms = Set<String>()
        var manifests: [Descriptor] = []
        for child in children {
            let image = try await resolveImage(child)
            // Children must themselves be an index — Apple's container CLI stores even
            // single-platform builds this way, so this works for both single- and multi-arch.
            let childMediaType = image.mediaType
            guard childMediaType == MediaTypes.index || childMediaType == MediaTypes.dockerManifestList else {
                throw MockerError.operationFailed(
                    "child image \(child) is not a manifest list (mediaType: \(childMediaType))"
                )
            }
            let childIndex = try await image.index()
            for desc in childIndex.manifests {
                // Skip non-runnable descriptors: attestations, SBOMs, nested indexes, signatures.
                guard desc.mediaType == MediaTypes.imageManifest || desc.mediaType == MediaTypes.dockerManifest else {
                    continue
                }
                guard let platform = desc.platform,
                      !platform.os.isEmpty,
                      !platform.architecture.isEmpty,
                      platform.os != "unknown",
                      platform.architecture != "unknown" else {
                    continue
                }
                let key = "\(platform.os)/\(platform.architecture)/\(platform.variant ?? "")"
                if seenPlatforms.insert(key).inserted {
                    manifests.append(desc)
                }
            }
        }

        guard !manifests.isEmpty else {
            throw MockerError.operationFailed(
                "no usable image manifests with platform info found in children; nothing to assemble"
            )
        }

        let index = Index(manifests: manifests)
        let contentStore = try LocalContentStore(path: storePath.appendingPathComponent("content"))
        let session = try await contentStore.newIngestSession()
        do {
            let writer = try ContentWriter(for: session.ingestDir)
            let result = try writer.create(from: index)
            _ = try await contentStore.completeIngestSession(session.id)

            let descriptor = Descriptor(
                mediaType: MediaTypes.index,
                digest: "sha256:" + result.digest.encoded,
                size: result.size
            )
            _ = try await imageStore.create(
                description: Containerization.Image.Description(reference: normalizedName, descriptor: descriptor)
            )
        } catch {
            try? await contentStore.cancelIngestSession(session.id)
            throw error
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(index)
    }

    private func resolveImage(_ reference: String) async throws -> Containerization.Image {
        var candidates = [reference]
        if let normalized = try? Self.normalize(reference), normalized != reference {
            candidates.append(normalized)
        }
        for candidate in candidates {
            if let hit = try? await imageStore.get(reference: candidate) {
                return hit
            }
        }
        throw MockerError.imageNotFound(reference)
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
