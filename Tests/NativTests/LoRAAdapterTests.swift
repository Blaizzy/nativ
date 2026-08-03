import XCTest
@testable import NativServerKit

final class LoRAAdapterTests: XCTestCase {
    func testReferenceRoundTripsAndNormalizesUnsafePathComponents() throws {
        let reference = HubLoRAAdapterReference(
            repoID: "example/address-parser",
            revisionSHA: "0123456789abcdef0123456789abcdef01234567",
            subfolder: "/mlx/./../release/"
        )

        XCTAssertEqual(reference.subfolder, "mlx/_/_/release")
        XCTAssertEqual(
            try PropertyListDecoder().decode(
                HubLoRAAdapterReference.self,
                from: PropertyListEncoder().encode(reference)
            ),
            reference
        )

        let unsafeData = Data(
            #"{"repoID":"example/address-parser","revisionSHA":"../main","subfolder":"../../outside"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            HubLoRAAdapterReference.self,
            from: unsafeData
        )
        XCTAssertEqual(decoded.revisionSHA, "invalid-revision")
        XCTAssertEqual(decoded.subfolder, "_/_/outside")
    }

    func testValidatorAcceptsCompleteNativeMLXPackage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeAdapterPackage(
            at: directory,
            tensorNames: [
                "model.layers.0.self_attn.q_proj.lora_a",
                "model.layers.0.self_attn.q_proj.lora_b",
            ]
        )

        let summary = try LoRAAdapterPackageValidator.validate(at: directory)

        XCTAssertEqual(summary.rank, 8)
        XCTAssertEqual(summary.tensorCount, 2)
        XCTAssertEqual(
            summary.sizeBytes,
            try fileSize(directory.appendingPathComponent("adapter_config.json"))
                + fileSize(directory.appendingPathComponent("adapters.safetensors"))
        )
    }

    func testValidatorRejectsForeignTensorNamesAndIncompletePackages() throws {
        let peftDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: peftDirectory) }
        try writeAdapterPackage(
            at: peftDirectory,
            tensorNames: ["base_model.model.layers.0.q_proj.lora_A.weight"]
        )
        XCTAssertThrowsError(try LoRAAdapterPackageValidator.validate(at: peftDirectory)) {
            XCTAssertEqual(
                $0 as? LoRAAdapterCompatibilityError,
                .unsupportedTensor("base_model.model.layers.0.q_proj.lora_A.weight")
            )
        }

        let incompleteDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: incompleteDirectory) }
        try writeAdapterPackage(
            at: incompleteDirectory,
            tensorNames: ["model.layers.0.q_proj.lora_a"]
        )
        XCTAssertThrowsError(try LoRAAdapterPackageValidator.validate(at: incompleteDirectory)) {
            XCTAssertEqual(
                $0 as? LoRAAdapterCompatibilityError,
                .incompletePair("model.layers.0.q_proj.lora_a")
            )
        }
    }

    func testValidatorAcceptsPEFTConfigAndPEFTTensorLayout() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePEFTAdapterPackage(at: directory, rank: 16)
        try Data("stale".utf8).write(
            to: directory.appendingPathComponent("adapters.safetensors")
        )

        let summary = try LoRAAdapterPackageValidator.validate(at: directory)

        XCTAssertEqual(summary.rank, 16)
        XCTAssertEqual(summary.tensorCount, 2)
        XCTAssertEqual(
            LoRAAdapterPackageValidator.weightsURL(at: directory)?.lastPathComponent,
            "adapter_model.safetensors"
        )
    }

    func testBundledRuntimeValidatorUsesCanonicalPEFTPolicy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePEFTAdapterPackage(at: directory, rank: 8)

        XCTAssertNoThrow(try LoRAAdapterRuntimePackageValidator.validate(at: directory))

        let configURL = directory.appendingPathComponent("adapter_config.json")
        var config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
                as? [String: Any]
        )
        config["rank_pattern"] = ["q_proj": 4]
        try JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys]
        ).write(to: configURL)

        XCTAssertThrowsError(
            try LoRAAdapterRuntimePackageValidator.validate(at: directory)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("rank_pattern"))
        }
    }

    func testValidatorRejectsUnsupportedDtypesAndIncorrectTensorByteRanges() throws {
        let unsupportedDtypeDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: unsupportedDtypeDirectory) }
        try writeAdapterPackage(
            at: unsupportedDtypeDirectory,
            tensorNames: [
                "model.layers.0.q_proj.lora_a",
                "model.layers.0.q_proj.lora_b",
            ],
            dataType: "I8",
            bytesPerElement: 1
        )
        XCTAssertThrowsError(
            try LoRAAdapterPackageValidator.validate(at: unsupportedDtypeDirectory)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported dtype I8"))
        }

        let incorrectRangeDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: incorrectRangeDirectory) }
        try writeAdapterPackage(
            at: incorrectRangeDirectory,
            tensorNames: [
                "model.layers.0.q_proj.lora_a",
                "model.layers.0.q_proj.lora_b",
            ],
            dataType: "F32",
            bytesPerElement: 2
        )
        XCTAssertThrowsError(
            try LoRAAdapterPackageValidator.validate(at: incorrectRangeDirectory)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("byte range"))
        }
    }

    func testHubMetadataOnlyExposesNativeMLXArtifactsAtTheSameRevision() throws {
        let data = Data(
            #"""
            {
              "id": "example/address-parser",
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "downloads": 42,
              "likes": 5,
              "library_name": "peft",
              "private": false,
              "gated": false,
              "tags": ["base_model:adapter:Qwen/Qwen3-0.6B"],
              "baseModels": {
                "relation": "adapter",
                "models": [{"id": "Qwen/Qwen3-0.6B"}]
              },
              "siblings": [
                {"rfilename": "adapter_config.json"},
                {"rfilename": "adapter_model.safetensors"},
                {"rfilename": "mlx/adapter_config.json"},
                {"rfilename": "mlx/adapters.safetensors"},
                {"rfilename": "checkpoint-10/adapter_config.json"},
                {"rfilename": "checkpoint-10/adapters.safetensors"}
              ]
            }
            """#.utf8
        )
        let adapter = try JSONDecoder().decode(HuggingFaceLoRAAdapter.self, from: data)

        XCTAssertTrue(adapter.declaresAdapterRelationship(to: "Qwen/Qwen3-0.6B"))
        XCTAssertFalse(adapter.declaresAdapterRelationship(to: "Qwen/Qwen3-1.7B"))
        XCTAssertEqual(adapter.artifactVariants.map(\.reference.subfolder), ["mlx", ""])
        XCTAssertEqual(
            adapter.artifactVariants.map(\.format),
            [.nativeMLX, .peft]
        )
        XCTAssertEqual(
            adapter.artifactVariants.first?.reference.revisionSHA,
            "0123456789abcdef0123456789abcdef01234567"
        )
    }

    func testHubMetadataDoesNotExposeGGUFOnlyAdapters() throws {
        let data = Data(
            #"""
            {
              "id": "example/gguf-only-adapter",
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "downloads": 100,
              "likes": 10,
              "private": false,
              "gated": false,
              "tags": [
                "base_model:adapter:Qwen/Qwen3-0.6B",
                "gguf"
              ],
              "siblings": [
                {"rfilename": "adapter_config.json"},
                {"rfilename": "adapter.gguf"},
                {"rfilename": "adapter_model.GGUF"},
                {"rfilename": "mlx/adapter_config.json"},
                {"rfilename": "mlx/adapters.gguf"}
              ]
            }
            """#.utf8
        )
        let adapter = try JSONDecoder().decode(HuggingFaceLoRAAdapter.self, from: data)

        XCTAssertTrue(adapter.declaresAdapterRelationship(to: "Qwen/Qwen3-0.6B"))
        XCTAssertTrue(adapter.artifactVariants.isEmpty)
        XCTAssertTrue(
            LoRAAdapterListSnapshot(
                installed: [],
                remoteAdapters: [adapter],
                activeReference: nil
            ).available.isEmpty
        )
    }

    func testSupportedRepositoryIgnoresAdditionalGGUFArtifacts() throws {
        let adapter = try hubAdapter(
            id: "example/mixed-adapter",
            sha: "0123456789abcdef0123456789abcdef01234567",
            downloads: 100,
            additionalFiles: ["adapter.gguf", "quantized/adapter-Q8_0.gguf"]
        )

        XCTAssertEqual(adapter.artifactVariants.count, 1)
        let variant = try XCTUnwrap(adapter.artifactVariants.first)
        XCTAssertEqual(variant.format, .nativeMLX)
        XCTAssertEqual(variant.weightsPath, "adapters.safetensors")
    }

    func testArtifactVariantRejectsUnsupportedWeightContainers() {
        let reference = HubLoRAAdapterReference(
            repoID: "example/gguf-adapter",
            revisionSHA: "0123456789abcdef0123456789abcdef01234567"
        )

        XCTAssertNil(
            LoRAAdapterArtifactVariant(
                reference: reference,
                configPath: "adapter_config.json",
                weightsPath: "adapter.gguf",
                format: .nativeMLX
            )
        )
        XCTAssertNotNil(
            LoRAAdapterArtifactVariant(
                reference: reference,
                configPath: "adapter_config.json",
                weightsPath: "adapters.safetensors",
                format: .nativeMLX
            )
        )
    }

    func testHubArtifactSizeRequiresAndSumsBothPinnedFiles() throws {
        let data = Data(
            #"""
            [
              {"type":"file","path":"mlx/adapter_config.json","size":1142},
              {"type":"file","path":"mlx/adapters.safetensors","size":23093000}
            ]
            """#.utf8
        )
        let expectedPaths = [
            "mlx/adapter_config.json",
            "mlx/adapters.safetensors",
        ]

        XCTAssertEqual(
            try HuggingFaceLoRAAdapterClient.combinedArtifactSize(
                from: data,
                expectedPaths: expectedPaths
            ),
            23_094_142
        )
        XCTAssertThrowsError(
            try HuggingFaceLoRAAdapterClient.combinedArtifactSize(
                from: Data(
                    #"""
                    [{"type":"file","path":"mlx/adapter_config.json","size":1142}]
                    """#.utf8
                ),
                expectedPaths: expectedPaths
            )
        )
    }

    func testAdapterListSnapshotKeepsSectionsExclusiveAndIdentityStable() throws {
        let baseModelID = "Qwen/Qwen2.5-Coder-7B-Instruct"
        let oldReference = HubLoRAAdapterReference(
            repoID: "example/coder-adapter",
            revisionSHA: "1111111111111111111111111111111111111111",
            subfolder: "mlx"
        )
        let newReference = HubLoRAAdapterReference(
            repoID: oldReference.repoID,
            revisionSHA: "2222222222222222222222222222222222222222",
            subfolder: oldReference.subfolder
        )
        let installed = InstalledLoRAAdapter(
            reference: oldReference,
            baseModelID: baseModelID,
            installedAt: Date(timeIntervalSince1970: 1_000),
            sizeBytes: 512,
            rank: 8,
            tensorCount: 2
        )
        let installedRepoFromHub = try hubAdapter(
            id: newReference.repoID,
            sha: newReference.revisionSHA,
            downloads: 100,
            subfolder: newReference.subfolder
        )
        let availableRepo = try hubAdapter(
            id: "example/other-adapter",
            sha: "3333333333333333333333333333333333333333",
            downloads: 50
        )

        let snapshot = LoRAAdapterListSnapshot(
            installed: [installed],
            remoteAdapters: [installedRepoFromHub, availableRepo],
            activeReference: oldReference
        )

        XCTAssertEqual(snapshot.installed.map(\.reference), [oldReference])
        XCTAssertEqual(snapshot.updates.map(\.available.variant.reference), [newReference])
        XCTAssertEqual(snapshot.available.map(\.adapter.id), ["example/other-adapter"])
        XCTAssertTrue(
            Set(snapshot.installed.map(\.reference.slot))
                .isDisjoint(with: Set(snapshot.available.map(\.id)))
        )
        XCTAssertEqual(oldReference.slot, newReference.slot)
        XCTAssertNotEqual(oldReference.id, newReference.id)
    }

    func testAdapterListSnapshotDeduplicatesAndSortsDeterministically() throws {
        let reference = HubLoRAAdapterReference(
            repoID: "example/installed",
            revisionSHA: "1111111111111111111111111111111111111111"
        )
        let older = InstalledLoRAAdapter(
            reference: reference,
            baseModelID: "base/model",
            installedAt: Date(timeIntervalSince1970: 1_000),
            sizeBytes: 1,
            rank: 8,
            tensorCount: 2
        )
        let newerReference = HubLoRAAdapterReference(
            repoID: reference.repoID,
            revisionSHA: "2222222222222222222222222222222222222222"
        )
        let newer = InstalledLoRAAdapter(
            reference: newerReference,
            baseModelID: older.baseModelID,
            installedAt: Date(timeIntervalSince1970: 2_000),
            sizeBytes: 2,
            rank: 16,
            tensorCount: 4
        )
        let lessPopular = try hubAdapter(
            id: "example/less-popular",
            sha: "3333333333333333333333333333333333333333",
            downloads: 10
        )
        let popular = try hubAdapter(
            id: "example/popular",
            sha: "4444444444444444444444444444444444444444",
            downloads: 1_000
        )

        let snapshot = LoRAAdapterListSnapshot(
            installed: [older, newer],
            remoteAdapters: [lessPopular, popular, lessPopular],
            activeReference: nil
        )

        XCTAssertEqual(snapshot.installed.map(\.reference), [newerReference])
        XCTAssertEqual(
            snapshot.available.map(\.adapter.id),
            ["example/popular", "example/less-popular"]
        )
        XCTAssertEqual(Set(snapshot.available.map(\.id)).count, 2)
    }

    func testSettingsPersistActiveAdapterAndOnlyRestartForTheActiveModel() throws {
        let active = HubLoRAAdapterReference(
            repoID: "example/active",
            revisionSHA: "0123456789abcdef0123456789abcdef01234567"
        )
        let unrelated = HubLoRAAdapterReference(
            repoID: "example/unrelated",
            revisionSHA: "1123456789abcdef0123456789abcdef01234567"
        )
        var settings = NativSettings(languageModelID: "Qwen/Qwen3-0.6B")
        settings.setLanguageAdapter(active, for: "Qwen/Qwen3-0.6B")

        let decoded = try PropertyListDecoder().decode(
            NativSettings.self,
            from: PropertyListEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.languageAdapter(for: "Qwen/Qwen3-0.6B"), active)
        let launchArguments = decoded.launchArguments(adapterPath: "/tmp/adapter")
        let adapterFlagIndex = try XCTUnwrap(
            launchArguments.firstIndex(of: "--adapter-path")
        )
        XCTAssertEqual(launchArguments[adapterFlagIndex + 1], "/tmp/adapter")
        XCTAssertFalse(decoded.launchArguments.contains("--adapter-path"))

        var unrelatedChange = settings
        unrelatedChange.setLanguageAdapter(unrelated, for: "Qwen/Qwen3-1.7B")
        XCTAssertTrue(settings.hasSameLaunchConfiguration(as: unrelatedChange))

        var activeChange = settings
        activeChange.setLanguageAdapter(nil, for: "Qwen/Qwen3-0.6B")
        XCTAssertFalse(settings.hasSameLaunchConfiguration(as: activeChange))
    }

    @MainActor
    func testCatalogPersistsLogicalReferenceAndResolvesPinnedSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("catalog.plist")
        let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
        let reference = HubLoRAAdapterReference(
            repoID: "example/address-parser",
            revisionSHA: "0123456789abcdef0123456789abcdef01234567",
            subfolder: "mlx"
        )
        let snapshotURL = LoRAAdapterCache.snapshotURL(
            for: reference,
            cacheRootURL: cacheURL
        )
        try writeAdapterPackage(
            at: snapshotURL,
            tensorNames: ["model.q_proj.lora_a", "model.q_proj.lora_b"]
        )
        let installed = InstalledLoRAAdapter(
            reference: reference,
            baseModelID: "Qwen/Qwen3-0.6B",
            installedAt: Date(timeIntervalSince1970: 1_000),
            sizeBytes: 256,
            rank: 8,
            tensorCount: 2
        )

        let catalog = LoRAAdapterCatalog(storageURL: storageURL, cacheRootURL: cacheURL)
        try catalog.install(installed)
        let reloaded = LoRAAdapterCatalog(storageURL: storageURL, cacheRootURL: cacheURL)

        XCTAssertEqual(reloaded.adapter(for: reference), installed)
        XCTAssertEqual(reloaded.localURL(for: reference), snapshotURL)
        XCTAssertNil(
            reloaded.localURL(
                for: reference,
                baseModelID: "Qwen/Qwen3-1.7B"
            )
        )
    }

    @MainActor
    func testCatalogReplacesAnOlderRevisionOfTheSameAdapterSlot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LoRAAdapterCatalog(
            storageURL: root.appendingPathComponent("catalog.plist"),
            cacheRootURL: root.appendingPathComponent("cache", isDirectory: true)
        )
        let oldReference = HubLoRAAdapterReference(
            repoID: "example/adapter",
            revisionSHA: "1111111111111111111111111111111111111111",
            subfolder: "mlx"
        )
        let newReference = HubLoRAAdapterReference(
            repoID: oldReference.repoID,
            revisionSHA: "2222222222222222222222222222222222222222",
            subfolder: oldReference.subfolder
        )
        for (index, reference) in [oldReference, newReference].enumerated() {
            try catalog.install(
                InstalledLoRAAdapter(
                    reference: reference,
                    baseModelID: "base/model",
                    installedAt: Date(timeIntervalSince1970: Double(index)),
                    sizeBytes: Int64(index + 1),
                    rank: 8,
                    tensorCount: 2
                )
            )
        }

        XCTAssertEqual(catalog.adapters(for: "base/model").count, 1)
        XCTAssertEqual(catalog.adapters(for: "base/model").first?.reference, newReference)
        XCTAssertNil(catalog.adapter(for: oldReference))
        XCTAssertNotNil(catalog.adapter(for: newReference))
    }

    @MainActor
    func testCatalogDeletesOnlyTheSelectedVariant() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("catalog.plist")
        let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
        let revision = "0123456789abcdef0123456789abcdef01234567"
        let selectedReference = HubLoRAAdapterReference(
            repoID: "example/address-parser",
            revisionSHA: revision,
            subfolder: "mlx"
        )
        let siblingReference = HubLoRAAdapterReference(
            repoID: "example/address-parser",
            revisionSHA: revision,
            subfolder: "release"
        )
        for reference in [selectedReference, siblingReference] {
            try writeAdapterPackage(
                at: LoRAAdapterCache.snapshotURL(
                    for: reference,
                    cacheRootURL: cacheURL
                ),
                tensorNames: ["model.q_proj.lora_a", "model.q_proj.lora_b"]
            )
        }

        let catalog = LoRAAdapterCatalog(storageURL: storageURL, cacheRootURL: cacheURL)
        for reference in [selectedReference, siblingReference] {
            try catalog.install(
                InstalledLoRAAdapter(
                    reference: reference,
                    baseModelID: "Qwen/Qwen3-0.6B",
                    installedAt: Date(timeIntervalSince1970: 1_000),
                    sizeBytes: 256,
                    rank: 8,
                    tensorCount: 2
                )
            )
        }

        XCTAssertNotNil(catalog.packageSize(for: selectedReference))
        try catalog.delete(selectedReference)

        XCTAssertNil(catalog.adapter(for: selectedReference))
        XCTAssertNil(catalog.localURL(for: selectedReference))
        XCTAssertNotNil(catalog.localURL(for: siblingReference))
        let reloaded = LoRAAdapterCatalog(storageURL: storageURL, cacheRootURL: cacheURL)
        XCTAssertNil(reloaded.adapter(for: selectedReference))
        XCTAssertNotNil(reloaded.adapter(for: siblingReference))
    }

    @MainActor
    func testCatalogReclaimsUnsharedHuggingFaceBlobs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("catalog.plist")
        let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
        let reference = HubLoRAAdapterReference(
            repoID: "example/address-parser",
            revisionSHA: "0123456789abcdef0123456789abcdef01234567",
            subfolder: "mlx"
        )
        let packageURL = LoRAAdapterCache.snapshotURL(
            for: reference,
            cacheRootURL: cacheURL
        )
        let blobDirectory = cacheURL
            .appendingPathComponent("models--example--address-parser", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: blobDirectory,
            withIntermediateDirectories: true
        )
        let configBlob = blobDirectory.appendingPathComponent("config-blob")
        let weightsBlob = blobDirectory.appendingPathComponent("weights-blob")
        try Data("{}".utf8).write(to: configBlob)
        try Data(repeating: 0, count: 16).write(to: weightsBlob)
        try FileManager.default.createSymbolicLink(
            at: packageURL.appendingPathComponent("adapter_config.json"),
            withDestinationURL: configBlob
        )
        try FileManager.default.createSymbolicLink(
            at: packageURL.appendingPathComponent("adapters.safetensors"),
            withDestinationURL: weightsBlob
        )

        let catalog = LoRAAdapterCatalog(storageURL: storageURL, cacheRootURL: cacheURL)
        try catalog.install(
            InstalledLoRAAdapter(
                reference: reference,
                baseModelID: "Qwen/Qwen3-0.6B",
                installedAt: Date(),
                sizeBytes: 18,
                rank: 8,
                tensorCount: 2
            )
        )
        try catalog.delete(reference)

        XCTAssertFalse(FileManager.default.fileExists(atPath: configBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: weightsBlob.path))
    }

    @MainActor
    func testCatalogUpdateReplacesOldRevisionAndRemovesItsPackageFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("catalog.plist")
        let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
        let oldReference = HubLoRAAdapterReference(
            repoID: "example/updatable",
            revisionSHA: "1111111111111111111111111111111111111111"
        )
        let newReference = HubLoRAAdapterReference(
            repoID: oldReference.repoID,
            revisionSHA: "2222222222222222222222222222222222222222"
        )
        let oldPackageURL = LoRAAdapterCache.snapshotURL(
            for: oldReference,
            cacheRootURL: cacheURL
        )
        let newPackageURL = LoRAAdapterCache.snapshotURL(
            for: newReference,
            cacheRootURL: cacheURL
        )
        try writeAdapterPackage(
            at: oldPackageURL,
            tensorNames: ["model.layers.0.q_proj.lora_a", "model.layers.0.q_proj.lora_b"]
        )
        try writeAdapterPackage(
            at: newPackageURL,
            tensorNames: ["model.layers.0.q_proj.lora_a", "model.layers.0.q_proj.lora_b"]
        )

        let catalog = LoRAAdapterCatalog(storageURL: storageURL, cacheRootURL: cacheURL)
        try catalog.install(
            InstalledLoRAAdapter(
                reference: oldReference,
                baseModelID: "base/model",
                installedAt: Date(timeIntervalSince1970: 1),
                sizeBytes: 1,
                rank: 8,
                tensorCount: 2
            )
        )
        try catalog.install(
            InstalledLoRAAdapter(
                reference: newReference,
                baseModelID: "base/model",
                installedAt: Date(timeIntervalSince1970: 2),
                sizeBytes: 2,
                rank: 8,
                tensorCount: 2
            )
        )

        XCTAssertNil(catalog.adapter(for: oldReference))
        XCTAssertNotNil(catalog.localURL(for: newReference, baseModelID: "base/model"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: oldPackageURL.appendingPathComponent("adapter_config.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: oldPackageURL.appendingPathComponent("adapters.safetensors").path
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func hubAdapter(
        id: String,
        sha: String,
        downloads: Int,
        likes: Int = 0,
        subfolder: String = "",
        additionalFiles: [String] = []
    ) throws -> HuggingFaceLoRAAdapter {
        let prefix = subfolder.isEmpty ? "" : "\(subfolder)/"
        let siblings = [
            "\(prefix)adapter_config.json",
            "\(prefix)adapters.safetensors",
        ] + additionalFiles
        let object: [String: Any] = [
            "id": id,
            "sha": sha,
            "downloads": downloads,
            "likes": likes,
            "private": false,
            "gated": false,
            "siblings": siblings.map { ["rfilename": $0] },
        ]
        return try JSONDecoder().decode(
            HuggingFaceLoRAAdapter.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func writeAdapterPackage(
        at directory: URL,
        tensorNames: [String],
        dataType: String = "F32",
        bytesPerElement: Int = MemoryLayout<Float>.size
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let configuration: [String: Any] = [
            "fine_tune_type": "lora",
            "lora_parameters": [
                "rank": 8,
                "scale": 2.0,
                "dropout": 0.0,
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.sortedKeys]
        ).write(to: directory.appendingPathComponent("adapter_config.json"))

        var header: [String: Any] = ["__metadata__": ["format": "mlx"]]
        var offset = 0
        for name in tensorNames.sorted() {
            let shape = name.hasSuffix(".lora_a") ? [16, 8] : [8, 16]
            let byteCount = shape.reduce(1, *) * bytesPerElement
            header[name] = [
                "dtype": dataType,
                "shape": shape,
                "data_offsets": [offset, offset + byteCount],
            ]
            offset += byteCount
        }
        let headerData = try JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys]
        )
        var headerLength = UInt64(headerData.count).littleEndian
        var weights = withUnsafeBytes(of: &headerLength) { Data($0) }
        weights.append(headerData)
        weights.append(Data(repeating: 0, count: offset))
        try weights.write(to: directory.appendingPathComponent("adapters.safetensors"))
    }

    private func writePEFTAdapterPackage(at directory: URL, rank: Int) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: [
                "peft_type": "LORA",
                "r": rank,
                "lora_alpha": rank * 2,
                "lora_dropout": 0.0,
                "bias": "none",
            ],
            options: [.sortedKeys]
        ).write(to: directory.appendingPathComponent("adapter_config.json"))

        let prefix = "base_model.model.model.layers.0.self_attn.q_proj"
        let header: [String: Any] = [
            "__metadata__": ["format": "pt"],
            "\(prefix).lora_A.weight": [
                "dtype": "F32",
                "shape": [rank, 16],
                "data_offsets": [0, rank * 16 * MemoryLayout<Float>.size],
            ],
            "\(prefix).lora_B.weight": [
                "dtype": "F32",
                "shape": [16, rank],
                "data_offsets": [
                    rank * 16 * MemoryLayout<Float>.size,
                    rank * 32 * MemoryLayout<Float>.size,
                ],
            ],
        ]
        let headerData = try JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys]
        )
        var headerLength = UInt64(headerData.count).littleEndian
        var weights = withUnsafeBytes(of: &headerLength) { Data($0) }
        weights.append(headerData)
        weights.append(
            Data(repeating: 0, count: rank * 32 * MemoryLayout<Float>.size)
        )
        try weights.write(
            to: directory.appendingPathComponent("adapter_model.safetensors")
        )
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
    }
}
