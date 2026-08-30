import Combine
import CoreFoundation
import Foundation
import NativServerKit

struct HubLoRAAdapterReference: Codable, Hashable, Identifiable, Sendable {
    let repoID: String
    let revisionSHA: String
    let subfolder: String

    var id: String {
        "\(repoID)@\(revisionSHA)#\(subfolder)"
    }

    var displayName: String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }

    var slot: LoRAAdapterSlot {
        LoRAAdapterSlot(repoID: repoID, subfolder: subfolder)
    }

    init(repoID: String, revisionSHA: String, subfolder: String = "") {
        self.repoID = repoID
        self.revisionSHA = Self.safePathComponent(revisionSHA)
        self.subfolder = Self.normalizedSubfolder(subfolder)
    }

    private enum CodingKeys: String, CodingKey {
        case repoID, revisionSHA, subfolder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            repoID: try container.decode(String.self, forKey: .repoID),
            revisionSHA: try container.decode(String.self, forKey: .revisionSHA),
            subfolder: try container.decodeIfPresent(String.self, forKey: .subfolder) ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repoID, forKey: .repoID)
        try container.encode(revisionSHA, forKey: .revisionSHA)
        try container.encode(subfolder, forKey: .subfolder)
    }

    private static func normalizedSubfolder(_ value: String) -> String {
        value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .map { $0 == "." || $0 == ".." ? "_" : $0 }
            .joined(separator: "/")
    }

    private static func safePathComponent(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value != ".",
              value != ".."
        else {
            return "invalid-revision"
        }
        return value
    }
}

/// Stable identity for one installable adapter package. Revisions are deliberately
/// excluded: a newer Hub commit updates the same row instead of creating a duplicate.
struct LoRAAdapterSlot: Hashable, Identifiable, Sendable {
    let repoID: String
    let subfolder: String

    var id: String { "\(repoID)#\(subfolder)" }
}

struct InstalledLoRAAdapter: Codable, Equatable, Identifiable, Sendable {
    let reference: HubLoRAAdapterReference
    let baseModelID: String
    let installedAt: Date
    let sizeBytes: Int64
    let rank: Int
    let tensorCount: Int

    var id: String { reference.id }
    var displayName: String { reference.displayName }
}

enum LoRAAdapterCompatibilityError: LocalizedError, Equatable {
    case missingConfiguration
    case missingWeights
    case invalidConfiguration(String)
    case invalidSafeTensors(String)
    case unsupportedTensor(String)
    case incompletePair(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "The adapter does not contain adapter_config.json."
        case .missingWeights:
            "The adapter does not contain the weights file required by its configuration."
        case .invalidConfiguration(let detail):
            "The adapter configuration is invalid: \(detail)"
        case .invalidSafeTensors(let detail):
            "The adapter weights are invalid: \(detail)"
        case .unsupportedTensor(let name):
            "The adapter contains unsupported non-LoRA tensor \(name)."
        case .incompletePair(let name):
            "The adapter contains an incomplete LoRA A/B pair for \(name)."
        }
    }
}

struct LoRAAdapterValidationSummary: Equatable, Sendable {
    let rank: Int
    let tensorCount: Int
    let sizeBytes: Int64
}

enum LoRAAdapterPackageFormat: Equatable, Sendable {
    case nativeMLX
    case peft

    var weightsFileName: String {
        switch self {
        case .nativeMLX: "adapters.safetensors"
        case .peft: "adapter_model.safetensors"
        }
    }
}

enum LoRAAdapterPackageValidator {
    private static let maximumConfigBytes = 1 * 1_024 * 1_024
    private static let maximumSafeTensorsHeaderBytes = 16 * 1_024 * 1_024

    static func validate(at directory: URL) throws -> LoRAAdapterValidationSummary {
        let configURL = directory.appendingPathComponent("adapter_config.json")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw LoRAAdapterCompatibilityError.missingConfiguration
        }
        let configuration = try adapterConfiguration(at: configURL)
        let weightsURL = directory.appendingPathComponent(
            configuration.format.weightsFileName
        )
        guard fileManager.fileExists(atPath: weightsURL.path) else {
            throw LoRAAdapterCompatibilityError.missingWeights
        }

        let tensors = try safeTensors(at: weightsURL)
        guard !tensors.isEmpty else {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors("no tensors were found")
        }

        let tensorByName = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0) })
        for tensor in tensors {
            let name = tensor.name
            guard let tensorIdentity = tensorIdentity(
                for: name,
                format: configuration.format
            ) else {
                throw LoRAAdapterCompatibilityError.unsupportedTensor(name)
            }
            guard tensorByName[tensorIdentity.pairedName] != nil else {
                throw LoRAAdapterCompatibilityError.incompletePair(name)
            }
            guard tensor.shape.count == 2 else {
                throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                    "tensor \(name) must be a matrix"
                )
            }
            let rankDimension: Int
            switch (configuration.format, tensorIdentity.role) {
            case (.nativeMLX, .a): rankDimension = tensor.shape[1]
            case (.nativeMLX, .b): rankDimension = tensor.shape[0]
            case (.peft, .a): rankDimension = tensor.shape[0]
            case (.peft, .b): rankDimension = tensor.shape[1]
            }
            guard rankDimension == configuration.rank else {
                throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                    "tensor \(name) does not match configured rank \(configuration.rank)"
                )
            }
        }

        let configAttributes = try fileManager.attributesOfItem(
            atPath: configURL.resolvingSymlinksInPath().path
        )
        let weightsAttributes = try fileManager.attributesOfItem(
            atPath: weightsURL.resolvingSymlinksInPath().path
        )
        let configSize = (configAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let weightsSize = (weightsAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let (sizeBytes, sizeOverflowed) = configSize.addingReportingOverflow(weightsSize)
        guard !sizeOverflowed else {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                "the combined adapter package size is too large"
            )
        }
        return LoRAAdapterValidationSummary(
            rank: configuration.rank,
            tensorCount: tensors.count,
            sizeBytes: sizeBytes
        )
    }

    static func weightsURL(at directory: URL) -> URL? {
        let configURL = directory.appendingPathComponent("adapter_config.json")
        guard let configuration = try? adapterConfiguration(at: configURL) else {
            return nil
        }
        let weightsURL = directory.appendingPathComponent(
            configuration.format.weightsFileName
        )
        return FileManager.default.fileExists(atPath: weightsURL.path)
            ? weightsURL
            : nil
    }

    private static func adapterConfiguration(
        at url: URL
    ) throws -> (rank: Int, format: LoRAAdapterPackageFormat) {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.resolvingSymlinksInPath().path
        )
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maximumConfigBytes else {
            throw LoRAAdapterCompatibilityError.invalidConfiguration(
                "the file is empty or unexpectedly large"
            )
        }

        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoRAAdapterCompatibilityError.invalidConfiguration(
                "the root value must be a JSON object"
            )
        }
        let peftType = object["peft_type"] as? String
        let isPEFT = peftType != nil || object["r"] != nil
        if isPEFT {
            guard peftType?.uppercased() == "LORA" || peftType == nil else {
                throw LoRAAdapterCompatibilityError.invalidConfiguration(
                    "PEFT type \(peftType ?? "unknown") is not supported"
                )
            }
            guard object["use_dora"] as? Bool != true else {
                throw LoRAAdapterCompatibilityError.invalidConfiguration(
                    "PEFT DoRA adapters are not supported"
                )
            }
        } else {
            let fineTuneType = object["fine_tune_type"] as? String ?? "lora"
            guard fineTuneType == "lora" else {
                throw LoRAAdapterCompatibilityError.invalidConfiguration(
                    "fine_tune_type \(fineTuneType) is not supported"
                )
            }
        }

        let parameters = object["lora_parameters"] as? [String: Any]
        let rank = isPEFT
            ? integer(object["r"])
            : (integer(parameters?["rank"]) ?? integer(object["rank"]))
        guard let rank, rank > 0 else {
            throw LoRAAdapterCompatibilityError.invalidConfiguration(
                "a positive integer LoRA rank is required"
            )
        }
        return (rank, isPEFT ? .peft : .nativeMLX)
    }

    private enum TensorRole {
        case a
        case b
    }

    private static func tensorIdentity(
        for name: String,
        format: LoRAAdapterPackageFormat
    ) -> (role: TensorRole, pairedName: String)? {
        let suffixes: (a: String, b: String)
        switch format {
        case .nativeMLX:
            suffixes = (".lora_a", ".lora_b")
        case .peft:
            suffixes = (".lora_A.weight", ".lora_B.weight")
        }
        if name.hasSuffix(suffixes.a) {
            return (
                .a,
                String(name.dropLast(suffixes.a.count)) + suffixes.b
            )
        }
        if name.hasSuffix(suffixes.b) {
            return (
                .b,
                String(name.dropLast(suffixes.b.count)) + suffixes.a
            )
        }
        return nil
    }

    private struct SafeTensorDescriptor {
        let name: String
        let shape: [Int]
        let startOffset: Int
        let endOffset: Int
    }

    private static func safeTensors(at url: URL) throws -> [SafeTensorDescriptor] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let lengthData = try handle.read(upToCount: 8), lengthData.count == 8 else {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors("missing header length")
        }
        let headerLength = lengthData.enumerated().reduce(UInt64(0)) { result, entry in
            result | (UInt64(entry.element) << UInt64(entry.offset * 8))
        }
        guard headerLength > 0,
              headerLength <= UInt64(maximumSafeTensorsHeaderBytes),
              headerLength <= UInt64(Int.max)
        else {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                "the header length is invalid"
            )
        }
        guard let headerData = try handle.read(upToCount: Int(headerLength)),
              headerData.count == Int(headerLength),
              let header = try JSONSerialization.jsonObject(with: headerData)
                as? [String: Any]
        else {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                "the header is missing or malformed"
            )
        }

        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: url.resolvingSymlinksInPath().path
        )
        let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
        let payloadSize = fileSize - 8 - Int(headerLength)
        guard payloadSize >= 0 else {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                "the declared header exceeds the file size"
            )
        }

        let tensors = try header.keys
            .filter { $0 != "__metadata__" }
            .sorted()
            .map { name -> SafeTensorDescriptor in
                guard let metadata = header[name] as? [String: Any],
                      let shapeValues = metadata["shape"] as? [Any],
                      let offsetValues = metadata["data_offsets"] as? [Any],
                      offsetValues.count == 2,
                      let startOffset = integer(offsetValues[0]),
                      let endOffset = integer(offsetValues[1]),
                      startOffset >= 0,
                      endOffset >= startOffset,
                      endOffset <= payloadSize,
                      let dataType = metadata["dtype"] as? String,
                      !dataType.isEmpty
                else {
                    throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                        "tensor \(name) has malformed metadata"
                    )
                }
                let shape = try shapeValues.map { value -> Int in
                    guard let dimension = integer(value), dimension > 0 else {
                        throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                            "tensor \(name) has an invalid shape"
                        )
                    }
                    return dimension
                }
                let bytesPerElement: Int
                switch dataType.uppercased() {
                case "F16", "BF16": bytesPerElement = 2
                case "F32": bytesPerElement = 4
                default:
                    throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                        "tensor \(name) uses unsupported dtype \(dataType)"
                    )
                }
                var elementCount = 1
                for dimension in shape {
                    let (nextCount, overflowed) = elementCount
                        .multipliedReportingOverflow(by: dimension)
                    guard !overflowed else {
                        throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                            "tensor \(name) is too large"
                        )
                    }
                    elementCount = nextCount
                }
                let (expectedByteCount, byteCountOverflowed) = elementCount
                    .multipliedReportingOverflow(by: bytesPerElement)
                guard !byteCountOverflowed,
                      endOffset - startOffset == expectedByteCount
                else {
                    throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                        "tensor \(name) byte range does not match its shape and dtype"
                    )
                }
                return SafeTensorDescriptor(
                    name: name,
                    shape: shape,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
            }

        let sortedRanges = tensors.sorted { $0.startOffset < $1.startOffset }
        if let first = sortedRanges.first,
           first.startOffset != 0 {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                "tensor data does not begin at the start of the payload"
            )
        }
        for (previous, current) in zip(sortedRanges, sortedRanges.dropFirst()) {
            guard previous.endOffset == current.startOffset else {
                throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                    "tensor data ranges overlap or contain gaps"
                )
            }
        }
        if let last = sortedRanges.last,
           last.endOffset != payloadSize {
            throw LoRAAdapterCompatibilityError.invalidSafeTensors(
                "tensor data does not cover the complete payload"
            )
        }
        return tensors
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max)
        else {
            return nil
        }
        return number.intValue
    }
}

/// Runs the same package-level compatibility rules used by the Python runtime.
/// The Swift validator above handles untrusted SafeTensors metadata without
/// importing tensor data; this second pass is the canonical feature-policy check.
enum LoRAAdapterRuntimePackageValidator {
    static func validate(at directory: URL) throws {
        let distributionURL = try Nativ.distributionURL()
        let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw HuggingFaceHubError.pythonUnavailable
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            "-I",
            "-m",
            "nativ_adapter_loader",
            "validate-package",
            directory.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = distributionURL
            .appendingPathComponent("python")
            .path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoRAAdapterCompatibilityError.invalidConfiguration(
                detail.isEmpty
                    ? "the bundled runtime rejected this package"
                    : detail
            )
        }
    }
}

enum LoRAAdapterCache {
    static var defaultRootURL: URL {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("HuggingFaceAdapters", isDirectory: true)
    }

    static func snapshotURL(
        for reference: HubLoRAAdapterReference,
        cacheRootURL: URL = defaultRootURL
    ) -> URL {
        let repositoryDirectory = "models--" + reference.repoID
            .replacingOccurrences(of: "/", with: "--")
        var url = cacheRootURL
            .appendingPathComponent(repositoryDirectory, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(reference.revisionSHA, isDirectory: true)
        if !reference.subfolder.isEmpty {
            url = url.appendingPathComponent(reference.subfolder, isDirectory: true)
        }
        return url
    }
}

@MainActor
final class LoRAAdapterCatalog: ObservableObject {
    static let shared = LoRAAdapterCatalog()

    @Published private(set) var adapters: [InstalledLoRAAdapter]

    private let storageURL: URL
    private let cacheRootURL: URL

    private struct StagedPackage {
        let directory: URL
        let files: [(source: URL, staged: URL)]
        let blobURLs: [URL]
    }

    init(
        storageURL: URL = LoRAAdapterCatalog.defaultStorageURL,
        cacheRootURL: URL = LoRAAdapterCache.defaultRootURL
    ) {
        self.storageURL = storageURL
        self.cacheRootURL = cacheRootURL
        self.adapters = Self.load(from: storageURL)
    }

    func adapters(for baseModelID: String) -> [InstalledLoRAAdapter] {
        adapters
            .filter { $0.baseModelID == baseModelID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func adapter(for reference: HubLoRAAdapterReference) -> InstalledLoRAAdapter? {
        adapters.first { $0.reference == reference }
    }

    func contains(_ reference: HubLoRAAdapterReference) -> Bool {
        adapter(for: reference) != nil
    }

    func localURL(
        for reference: HubLoRAAdapterReference,
        baseModelID: String? = nil
    ) -> URL? {
        guard let installedAdapter = adapter(for: reference),
              baseModelID == nil || installedAdapter.baseModelID == baseModelID
        else {
            return nil
        }
        let url = LoRAAdapterCache.snapshotURL(for: reference, cacheRootURL: cacheRootURL)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("adapter_config.json").path
        ), LoRAAdapterPackageValidator.weightsURL(at: url) != nil else {
            return nil
        }
        return url
    }

    func packageSize(for reference: HubLoRAAdapterReference) -> Int64? {
        guard let packageURL = localURL(for: reference) else { return nil }
        let fileManager = FileManager.default
        guard let weightsURL = LoRAAdapterPackageValidator.weightsURL(at: packageURL) else {
            return nil
        }
        let fileURLs = [
            packageURL.appendingPathComponent("adapter_config.json"),
            weightsURL,
        ]
        return fileURLs.reduce(into: Int64(0)) { total, fileURL in
            guard total >= 0,
                  let attributes = try? fileManager.attributesOfItem(
                      atPath: fileURL.resolvingSymlinksInPath().path
                  ),
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else {
                total = -1
                return
            }
            let (next, overflowed) = total.addingReportingOverflow(size)
            total = overflowed ? -1 : next
        }
        .nonnegative
    }

    func install(_ adapter: InstalledLoRAAdapter) throws {
        let replacedAdapter = adapters.first {
            $0.baseModelID == adapter.baseModelID
                && $0.reference.slot == adapter.reference.slot
                && $0.reference != adapter.reference
        }
        var next = adapters.filter {
            !($0.baseModelID == adapter.baseModelID
                && $0.reference.slot == adapter.reference.slot)
        }
        next.append(adapter)

        let stagedPackage = try replacedAdapter.map {
            try stagePackageFiles(for: $0.reference)
        }
        do {
            try save(next)
            adapters = next
            if let stagedPackage {
                commit(stagedPackage)
            }
        } catch {
            if let stagedPackage {
                restore(stagedPackage)
            }
            throw error
        }
    }

    /// Removes one installed variant without disturbing other variants that may share
    /// the same Hugging Face snapshot. Files are staged first so a catalog write
    /// failure can be rolled back without leaving a partially deleted installation.
    func delete(_ reference: HubLoRAAdapterReference) throws {
        let next = adapters.filter { $0.reference != reference }
        guard next.count != adapters.count else { return }

        let stagedPackage = try stagePackageFiles(for: reference)
        do {
            try save(next)
            adapters = next
            commit(stagedPackage)
        } catch {
            restore(stagedPackage)
            throw error
        }
    }

    private func stagePackageFiles(
        for reference: HubLoRAAdapterReference
    ) throws -> StagedPackage {
        let packageURL = LoRAAdapterCache.snapshotURL(
            for: reference,
            cacheRootURL: cacheRootURL
        )
        let sourceURLs = [
            packageURL.appendingPathComponent("adapter_config.json"),
            packageURL.appendingPathComponent("adapters.safetensors"),
            packageURL.appendingPathComponent("adapter_model.safetensors"),
        ]
        let stagingURL = cacheRootURL
            .appendingPathComponent(".deleting", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var stagedFiles: [(source: URL, staged: URL)] = []
        var referencedBlobURLs: [URL] = []

        do {
            try FileManager.default.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: true
            )
            for sourceURL in sourceURLs
            where FileManager.default.fileExists(atPath: sourceURL.path) {
                if let blobURL = cachedBlobURL(for: sourceURL) {
                    referencedBlobURLs.append(blobURL)
                }
                let stagedURL = stagingURL.appendingPathComponent(
                    sourceURL.lastPathComponent
                )
                try FileManager.default.moveItem(at: sourceURL, to: stagedURL)
                stagedFiles.append((sourceURL, stagedURL))
            }
            return StagedPackage(
                directory: stagingURL,
                files: stagedFiles,
                blobURLs: referencedBlobURLs
            )
        } catch {
            let partialPackage = StagedPackage(
                directory: stagingURL,
                files: stagedFiles,
                blobURLs: referencedBlobURLs
            )
            restore(partialPackage)
            throw error
        }
    }

    private func restore(_ stagedPackage: StagedPackage) {
        for file in stagedPackage.files.reversed()
        where FileManager.default.fileExists(atPath: file.staged.path) {
            try? FileManager.default.createDirectory(
                at: file.source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.moveItem(at: file.staged, to: file.source)
        }
        try? FileManager.default.removeItem(at: stagedPackage.directory)
    }

    private func commit(_ stagedPackage: StagedPackage) {
        try? FileManager.default.removeItem(at: stagedPackage.directory)
        for directory in Set(
            stagedPackage.files.map { $0.source.deletingLastPathComponent() }
        ) {
            removeEmptySnapshotDirectories(startingAt: directory)
        }
        reclaimUnreferencedBlobs(stagedPackage.blobURLs)
    }

    private func removeEmptySnapshotDirectories(startingAt directory: URL) {
        let fileManager = FileManager.default
        let cacheRootPath = cacheRootURL.standardizedFileURL.path + "/"
        var candidate = directory.standardizedFileURL
        while candidate.path.hasPrefix(cacheRootPath),
              candidate.lastPathComponent != "snapshots" {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil
            ), contents.isEmpty else { return }
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                return
            }
            candidate.deleteLastPathComponent()
        }
    }

    private func cachedBlobURL(for fileURL: URL) -> URL? {
        let resourceValues = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard resourceValues?.isSymbolicLink == true else {
            return nil
        }
        let blobURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = cacheRootURL.standardizedFileURL.path + "/"
        guard blobURL.path.hasPrefix(rootPath) else { return nil }
        return blobURL
    }

    private func reclaimUnreferencedBlobs(_ blobURLs: [URL]) {
        let candidates = Set(blobURLs.map(\.standardizedFileURL))
        guard !candidates.isEmpty else { return }

        var referenced = Set<URL>()
        if let enumerator = FileManager.default.enumerator(
            at: cacheRootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.isSymbolicLinkKey]
                )
                guard resourceValues?.isSymbolicLink == true else {
                    continue
                }
                let resolvedURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
                if candidates.contains(resolvedURL) {
                    referenced.insert(resolvedURL)
                }
            }
        }

        for blobURL in candidates.subtracting(referenced) {
            try? FileManager.default.removeItem(at: blobURL)
        }
    }

    private func save(_ adapters: [InstalledLoRAAdapter]) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(adapters).write(to: storageURL, options: .atomic)
    }

    private static func load(from url: URL) -> [InstalledLoRAAdapter] {
        guard let data = try? Data(contentsOf: url),
              let adapters = try? PropertyListDecoder().decode(
                [InstalledLoRAAdapter].self,
                from: data
              )
        else {
            return []
        }
        return adapters
    }

    nonisolated static var defaultStorageURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("LoRAAdapters.plist")
    }
}

private extension Int64 {
    var nonnegative: Int64? { self >= 0 ? self : nil }
}

struct NativAdapterValidationResponse: Decodable, Equatable, Sendable {
    let adapterPath: String
    let matchedTensors: Int
    let expectedTensors: Int
    let namespaceMapping: String

    enum CodingKeys: String, CodingKey {
        case adapterPath = "adapter_path"
        case matchedTensors = "matched_tensors"
        case expectedTensors = "expected_tensors"
        case namespaceMapping = "namespace_mapping"
    }
}

struct NativModelLoadResponse: Decodable, Equatable, Sendable {
    let status: String
    let model: String?
    let adapter: String?
    let adapterValidation: NativAdapterValidationResponse?

    enum CodingKeys: String, CodingKey {
        case status, model, adapter
        case adapterValidation = "adapter_validation"
    }
}

enum NativModelLoadClientError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Nativ server returned an invalid model-load response."
        case .requestFailed(let message):
            message
        }
    }
}

struct NativModelLoadClient: Sendable {
    let baseURL: URL
    var apiKey: String?

    func load(modelID: String, adapterPath: String?) async throws -> NativModelLoadResponse {
        let endpoint = baseURL.appendingPathComponent("v1/models/load")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        let payload: [String: Any] = [
            "model": modelID,
            "adapter_path": adapterPath ?? NSNull(),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NativModelLoadClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw NativModelLoadClientError.requestFailed(
                NativServerErrorMessage.endpointFailure(
                    endpoint: "/v1/models/load",
                    statusCode: response.statusCode,
                    responseBody: body
                )
            )
        }
        return try JSONDecoder().decode(NativModelLoadResponse.self, from: data)
    }
}
