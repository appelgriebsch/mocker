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
        try Self.requireIndexMediaType(image.mediaType, reference: reference)
        let index = try await image.index()
        return try Self.encodeIndex(index)
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
            try Self.requireIndexMediaType(image.mediaType, reference: child)
            let childIndex = try await image.index()
            for desc in Self.filterPlatformDescriptors(childIndex.manifests) {
                let key = Self.platformKey(desc)
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
        try await writeIndex(index, as: normalizedName)
        return try Self.encodeIndex(index)
    }

    /// Add a child image's platform descriptors to an existing manifest list.
    /// New descriptors REPLACE existing entries with the same platform (add-semantics:
    /// the latest add wins). Creates a new content blob and re-points the reference.
    @discardableResult
    public func add(list: String, child: String) async throws -> Data {
        let listImage = try await resolveImage(list)
        let normalizedListName = listImage.reference
        try Self.requireIndexMediaType(listImage.mediaType, reference: list)
        let existing = try await listImage.index()
        let originalDigest = listImage.descriptor.digest

        let childImage = try await resolveImage(child)
        try Self.requireIndexMediaType(childImage.mediaType, reference: child)
        let childIndex = try await childImage.index()
        let incoming = Self.filterPlatformDescriptors(childIndex.manifests)
        guard !incoming.isEmpty else {
            throw MockerError.operationFailed(
                "child image \(child) has no usable image-manifest descriptors with platform info"
            )
        }

        // Drop any existing descriptor whose platform equals an incoming descriptor's
        // platform — we use ContainerizationOCI.Platform == directly so arm64 nil-vs-v8
        // is treated as the same platform.
        let incomingPlatforms: [Platform] = incoming.compactMap { $0.platform }
        var merged = existing.manifests.filter { desc in
            guard let platform = desc.platform else { return true }
            return !incomingPlatforms.contains { $0 == platform }
        }
        merged.append(contentsOf: incoming)

        let index = Self.rebuild(existing, manifests: merged)
        try await assertUnchanged(reference: normalizedListName, expectedDigest: originalDigest)
        try await writeIndex(index, as: normalizedListName, mediaType: listImage.mediaType)
        return try Self.encodeIndex(index)
    }

    /// Remove a platform from an existing manifest list.
    /// `target` may be a platform spec ("linux/amd64", "linux/arm64/v8") or a manifest
    /// digest ("sha256:..."). Throws if no entry matches.
    @discardableResult
    public func remove(list: String, target: String) async throws -> Data {
        let listImage = try await resolveImage(list)
        let normalizedListName = listImage.reference
        try Self.requireIndexMediaType(listImage.mediaType, reference: list)
        let existing = try await listImage.index()
        let originalDigest = listImage.descriptor.digest

        let isDigest = target.hasPrefix("sha256:")
        let platformMatch = isDigest ? nil : try ContainerizationOCI.Platform(from: target)

        let filtered = existing.manifests.filter { desc in
            if isDigest { return desc.digest != target }
            if let p = platformMatch, desc.platform == p { return false }
            return true
        }
        guard filtered.count != existing.manifests.count else {
            throw MockerError.operationFailed(
                "no manifest entry matching \(target) in \(list)"
            )
        }
        guard !filtered.isEmpty else {
            throw MockerError.operationFailed(
                "removing \(target) would leave \(list) empty; delete the list with 'mocker rmi' instead"
            )
        }

        let index = Self.rebuild(existing, manifests: filtered)
        try await assertUnchanged(reference: normalizedListName, expectedDigest: originalDigest)
        try await writeIndex(index, as: normalizedListName, mediaType: listImage.mediaType)
        return try Self.encodeIndex(index)
    }

    /// Override platform metadata for a specific entry inside a manifest list.
    ///
    /// `child` is resolved locally and must be unambiguous — its index must contain exactly
    /// one image-manifest descriptor with platform info. The entry in `list` whose digest
    /// matches that child manifest is rewritten with the supplied overrides; nil overrides
    /// keep the existing value. Other descriptors and index-level metadata are preserved.
    ///
    /// Note: only os/arch/variant are exposed. ContainerizationOCI's Platform Codable
    /// implementation drops osVersion/osFeatures on encode, so those fields don't round-trip
    /// through the on-disk index. Re-add them when upstream gains support.
    @discardableResult
    public func annotate(
        list: String,
        child: String,
        os: String? = nil,
        arch: String? = nil,
        variant: String? = nil
    ) async throws -> Data {
        let listImage = try await resolveImage(list)
        let normalizedListName = listImage.reference
        try Self.requireIndexMediaType(listImage.mediaType, reference: list)
        let existing = try await listImage.index()
        let originalDigest = listImage.descriptor.digest

        let childImage = try await resolveImage(child)
        try Self.requireIndexMediaType(childImage.mediaType, reference: child)
        let childIndex = try await childImage.index()
        let childDescriptors = Self.filterPlatformDescriptors(childIndex.manifests)
        guard childDescriptors.count == 1 else {
            throw MockerError.operationFailed(
                "child image \(child) is ambiguous (\(childDescriptors.count) platform manifests); annotate requires a single-platform child"
            )
        }
        let targetDigest = childDescriptors[0].digest

        guard let targetIndex = existing.manifests.firstIndex(where: { $0.digest == targetDigest }) else {
            throw MockerError.operationFailed(
                "manifest list \(list) has no entry with digest \(targetDigest) (child \(child))"
            )
        }

        let original = existing.manifests[targetIndex]
        let basePlatform = original.platform ?? childDescriptors[0].platform
        let updatedPlatform = Platform(
            arch: arch ?? basePlatform?.architecture ?? "",
            os: os ?? basePlatform?.os ?? "linux",
            osVersion: basePlatform?.osVersion,
            osFeatures: basePlatform?.osFeatures,
            variant: variant ?? basePlatform?.variant
        )

        var manifests = existing.manifests
        manifests[targetIndex] = Descriptor(
            mediaType: original.mediaType,
            digest: original.digest,
            size: original.size,
            urls: original.urls,
            annotations: original.annotations,
            platform: updatedPlatform,
            artifactType: original.artifactType
        )

        let index = Self.rebuild(existing, manifests: manifests)
        try await assertUnchanged(reference: normalizedListName, expectedDigest: originalDigest)
        try await writeIndex(index, as: normalizedListName, mediaType: listImage.mediaType)
        return try Self.encodeIndex(index)
    }

    /// Push a manifest list to its registry.
    public func push(_ reference: String) async throws {
        let image = try await resolveImage(reference)
        try Self.requireIndexMediaType(image.mediaType, reference: reference)
        // resolveImage gives us back the canonical reference the store knows about,
        // which is the form push needs.
        try await imageStore.push(reference: image.reference, platform: nil)
    }

    // MARK: - Helpers

    /// Rebuild an Index preserving the original media type and any annotations/subject/
    /// artifactType so manifest-list metadata isn't silently stripped on edit.
    private static func rebuild(_ existing: Index, manifests: [Descriptor]) -> Index {
        Index(
            schemaVersion: existing.schemaVersion,
            mediaType: existing.mediaType.isEmpty ? MediaTypes.index : existing.mediaType,
            manifests: manifests,
            annotations: existing.annotations,
            subject: existing.subject,
            artifactType: existing.artifactType
        )
    }

    /// Compare-and-swap guard: re-read the reference's current descriptor and bail if it
    /// differs from the digest we captured when the operation started. This catches the
    /// common case where a second process mutated the list while we were assembling the
    /// edit. Not airtight — there's still a TOCTOU window between this check and the
    /// final write — but materially better than no check.
    private func assertUnchanged(reference: String, expectedDigest: String) async throws {
        guard let current = try? await imageStore.get(reference: reference) else {
            throw MockerError.operationFailed(
                "manifest list \(reference) disappeared during edit; aborting"
            )
        }
        if current.descriptor.digest != expectedDigest {
            throw MockerError.operationFailed(
                "manifest list \(reference) changed during edit (digest mismatch); aborting"
            )
        }
    }

    private func writeIndex(_ index: Index, as normalizedName: String, mediaType: String = MediaTypes.index) async throws {
        let contentStore = try LocalContentStore(path: storePath.appendingPathComponent("content"))
        let session = try await contentStore.newIngestSession()
        do {
            let writer = try ContentWriter(for: session.ingestDir)
            let result = try writer.create(from: index)
            _ = try await contentStore.completeIngestSession(session.id)
            let descriptor = Descriptor(
                mediaType: mediaType,
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
    }

    private static func filterPlatformDescriptors(_ descriptors: [Descriptor]) -> [Descriptor] {
        descriptors.filter { desc in
            guard desc.mediaType == MediaTypes.imageManifest || desc.mediaType == MediaTypes.dockerManifest else {
                return false
            }
            guard let p = desc.platform,
                  !p.os.isEmpty, !p.architecture.isEmpty,
                  p.os != "unknown", p.architecture != "unknown" else {
                return false
            }
            return true
        }
    }

    private static func platformKey(_ desc: Descriptor) -> String {
        guard let p = desc.platform else { return "" }
        return platformKey(forPlatform: p)
    }

    private static func platformKey(forPlatform p: Platform) -> String {
        // Normalize arm64 nil-variant to v8 so two descriptors that ContainerizationOCI's
        // Platform == treats as equal also collide in the dedup set.
        let variant: String
        if p.architecture == "arm64", p.variant == nil {
            variant = "v8"
        } else {
            variant = p.variant ?? ""
        }
        return "\(p.os)/\(p.architecture)/\(variant)"
    }

    private static func requireIndexMediaType(_ mediaType: String, reference: String) throws {
        guard mediaType == MediaTypes.index || mediaType == MediaTypes.dockerManifestList else {
            throw MockerError.operationFailed(
                "image \(reference) is not a manifest list (mediaType: \(mediaType))"
            )
        }
    }

    private static func encodeIndex(_ index: Index) throws -> Data {
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
