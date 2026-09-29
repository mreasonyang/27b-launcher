import CryptoKit
import Darwin
import Foundation

struct ModelStorageSnapshot: Sendable, Equatable {
    let url: URL
    let byteCount: Int64
    let isAvailable: Bool
    let isRelocated: Bool
    /// Set when the migration succeeded but something still needs the user's
    /// attention (for example the old location could not be removed).
    var notice: ModelStorageMigrationNotice?
}

struct ModelStorageLocationStatus: Sendable, Equatable {
    let url: URL
    let isAvailable: Bool
    let isRelocated: Bool
}

enum ModelStorageError: LocalizedError, AppLocalizableError, Equatable {
    case sourceMissing
    case destinationExists
    case destinationInsideSource
    case destinationReadOnly
    case destinationIsNetworkVolume
    case destinationFileSystemUnsupported(fileSystem: String, largestFileBytes: Int64)
    case destinationContainsIncompleteCopy
    case insufficientDiskSpace(required: Int64, available: Int64)
    case verificationFailed
    case destinationFileCreationFailed
    case systemOutOfSpace
    case systemPermissionDenied
    case systemFileMissing
    case systemFileReadOnly
    /// Catch-all for an unclassifiable system failure. The associated value is the
    /// raw `NSError` text, kept for logs/diagnostics only: it is deliberately
    /// absent from both `localizedDescription(using:)` and `errorDescription`, so
    /// the UI tier can never embed it. See `diagnosticDescription`.
    case systemFileOperationFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "模型存储位置当前不可用"
        case .destinationExists: "所选位置已存在 Bonsai2 Models 文件夹；请选择其他位置"
        case .destinationInsideSource: "新位置不能位于当前模型文件夹内"
        case .destinationReadOnly: "所选位置为只读，无法写入模型文件"
        case .destinationIsNetworkVolume: "所选位置位于网络卷，网络中断会导致迁移失败；请选择本地磁盘"
        case let .destinationFileSystemUnsupported(fileSystem, largestFileBytes):
            "所选位置的 \(fileSystem) 文件系统无法存放 \(largestFileBytes.formatted(.byteCount(style: .file))) 的单个文件；请选择 APFS 或 Mac OS 扩展格式的本地磁盘"
        case .destinationContainsIncompleteCopy:
            "所选位置的 Bonsai2 Models 文件夹内容不完整，请先删除该文件夹或选择其他位置"
        case let .insufficientDiskSpace(required, available):
            "目标磁盘空间不足：需要 \(required.formatted(.byteCount(style: .file)))，可用 \(available.formatted(.byteCount(style: .file)))"
        case .verificationFailed: "迁移后的模型校验失败，已保留原位置"
        case .destinationFileCreationFailed: "无法在目标位置创建模型文件"
        case .systemOutOfSpace:
            FileSystemFailure.Category.outOfSpace.localizationKey
        case .systemPermissionDenied:
            FileSystemFailure.Category.permissionDenied.localizationKey
        case .systemFileMissing:
            FileSystemFailure.Category.missingSource.localizationKey
        case .systemFileReadOnly:
            FileSystemFailure.Category.readOnly.localizationKey
        case .systemFileOperationFailed:
            "模型迁移过程中发生系统错误；请查看日志了解详情。"
        }
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case .sourceMissing:
            preferences.localized("模型存储位置当前不可用")
        case .destinationExists:
            preferences.localized("所选位置已存在 Bonsai2 Models 文件夹；请选择其他位置")
        case .destinationInsideSource:
            preferences.localized("新位置不能位于当前模型文件夹内")
        case .destinationReadOnly:
            preferences.localized("所选位置为只读，无法写入模型文件")
        case .destinationIsNetworkVolume:
            preferences.localized("所选位置位于网络卷，网络中断会导致迁移失败；请选择本地磁盘")
        case let .destinationFileSystemUnsupported(fileSystem, largestFileBytes):
            preferences.localizedFormat(
                "所选位置的 %@ 文件系统无法存放 %@ 的单个文件；请选择 APFS 或 Mac OS 扩展格式的本地磁盘",
                fileSystem,
                largestFileBytes.formatted(.byteCount(style: .file))
            )
        case .destinationContainsIncompleteCopy:
            preferences.localized("所选位置的 Bonsai2 Models 文件夹内容不完整，请先删除该文件夹或选择其他位置")
        case let .insufficientDiskSpace(required, available):
            preferences.localizedFormat(
                "目标磁盘空间不足：需要 %@，可用 %@",
                required.formatted(.byteCount(style: .file)),
                available.formatted(.byteCount(style: .file))
            )
        case .verificationFailed:
            preferences.localized("迁移后的模型校验失败，已保留原位置")
        case .destinationFileCreationFailed:
            preferences.localized("无法在目标位置创建模型文件")
        case .systemOutOfSpace:
            preferences.localized(FileSystemFailure.Category.outOfSpace.localizationKey)
        case .systemPermissionDenied:
            preferences.localized(FileSystemFailure.Category.permissionDenied.localizationKey)
        case .systemFileMissing:
            preferences.localized(FileSystemFailure.Category.missingSource.localizationKey)
        case .systemFileReadOnly:
            preferences.localized(FileSystemFailure.Category.readOnly.localizationKey)
        case .systemFileOperationFailed:
            preferences.localized("模型迁移过程中发生系统错误；请查看日志了解详情。")
        }
    }

    /// The raw underlying system text, when this error wraps one. For logs and
    /// debugging only: it is never localized and never embedded in
    /// `localizedDescription(using:)` or `errorDescription`.
    var diagnosticDescription: String? {
        if case let .systemFileOperationFailed(underlying) = self {
            return underlying
        }
        return nil
    }
}

extension ModelStorageError: CustomStringConvertible {
    /// Developer-facing description used by `String(describing:)` and logging. The
    /// localized UI path is `localizedDescription(using:)`.
    var description: String {
        guard let diagnostic = diagnosticDescription else {
            return errorDescription ?? ""
        }
        return "\(errorDescription ?? "") [underlying: \(diagnostic)]"
    }
}

actor ModelStorageManager {
    private static let chunkSize = 4_194_304
    private static let diskSpaceHeadroom: Int64 = 536_870_912
    private let config: LauncherConfig
    private let artifacts: [InstallationArtifact]
    private let fileManager = FileManager.default
    private let volumeDescriptorProvider: @Sendable (URL) -> ModelStorageDestinationDescriptor?
    private var migrating = false
    private struct CopyJournal: Codable {
        let id: UUID
        let ownerPID: Int32
        let ownerBirth: String
        let staging: String
    }
    private var journalURL: URL { config.supportDirectory.appending(path: "model-copy.json") }

    /// Reclaim only the staging path recorded by this transaction format, after
    /// its process instance has exited. No directory-name scans or old formats.
    func recoverInterruptedCopy() throws {
        guard !migrating, fileManager.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(CopyJournal.self, from: Data(contentsOf: journalURL))
        if ServerProcessDiscovery.birthIdentity(of: journal.ownerPID) == journal.ownerBirth { return }
        let staging = URL(filePath: journal.staging)
        guard staging.lastPathComponent == ".Bonsai2 Models.copy-" + journal.id.uuidString else { throw ModelStorageError.verificationFailed }
        if let info = try ManagedFileSystem.metadata(at: staging) {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw ModelStorageError.verificationFailed }
            try fileManager.removeItem(at: staging)
        }
        try fileManager.removeItem(at: journalURL)
    }


    init(config: LauncherConfig, artifacts: [InstallationArtifact],
         volumeDescriptorProvider: @escaping @Sendable (URL) -> ModelStorageDestinationDescriptor? = ModelStorageDestinationProbe.descriptor(at:)) {
        self.config = config
        self.artifacts = artifacts.filter { $0.component == .model || $0.component == .projector }
        self.volumeDescriptorProvider = volumeDescriptorProvider
    }

    func locationStatus() throws -> ModelStorageLocationStatus {
        let url = try config.configuredModelsDirectory()
        return ModelStorageLocationStatus(url: url,
            isAvailable: try ManagedFileSystem.metadata(at: url) != nil,
            isRelocated: try config.hasCustomModelLocation)
    }

    func snapshot() throws -> ModelStorageSnapshot {
        let location = try locationStatus()
        return ModelStorageSnapshot(url: location.url,
            byteCount: location.isAvailable ? try allocatedSize(of: location.url) : 0,
            isAvailable: location.isAvailable, isRelocated: location.isRelocated,
            notice: try config.retainedModelSource.map { .sourceLocationRetained(byteCount: try allocatedSize(of: $0)) })
    }

    /// Copy and verify first; the single atomic location record is the commit point.
    /// A failure before it leaves the source selected and intact. A failure after it
    /// leaves the verified destination selected and reports the retained source.
    func migrate(to selectedParent: URL,
                 progress: @escaping @Sendable (ModelStorageMigrationProgress) async -> Void = { _ in }) async throws -> ModelStorageSnapshot {
        do { return try await performMigration(to: selectedParent, progress: progress) }
        catch let error as ModelStorageError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            switch FileSystemFailure.category(of: error) {
            case .outOfSpace: throw ModelStorageError.systemOutOfSpace
            case .permissionDenied: throw ModelStorageError.systemPermissionDenied
            case .missingSource: throw ModelStorageError.systemFileMissing
            case .readOnly: throw ModelStorageError.systemFileReadOnly
            case nil: throw ModelStorageError.systemFileOperationFailed(underlying: String(describing: error))
            }
        }
    }

    private func performMigration(to selectedParent: URL,
                 progress: @escaping @Sendable (ModelStorageMigrationProgress) async -> Void = { _ in }) async throws -> ModelStorageSnapshot {
        try recoverInterruptedCopy()
        guard !fileManager.fileExists(atPath: journalURL.path), !migrating else { throw ModelStorageError.destinationExists }
        migrating = true
        defer { migrating = false }
        try Task.checkCancellation()
        let source = try config.configuredModelsDirectory().standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: source.path) else { throw ModelStorageError.sourceMissing }
        let parent = selectedParent.standardizedFileURL.resolvingSymlinksInPath()
        guard parent != source, !parent.path.hasPrefix(source.path + "/") else { throw ModelStorageError.destinationInsideSource }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: "Bonsai2 Models").resolvingSymlinksInPath()
        guard destination != source, !source.path.hasPrefix(destination.path + "/"),
              !destination.path.hasPrefix(source.path + "/") else { throw ModelStorageError.destinationInsideSource }
        guard !artifacts.isEmpty else { throw ModelStorageError.sourceMissing }
        let sourceManifest = try treeManifest(source)
        let sourceFootprint = try footprint(of: source)
        let descriptor = try validateDestinationVolume(parent: parent, footprint: sourceFootprint)
        let adopting = fileManager.fileExists(atPath: destination.path)
        if adopting {
            let existing = try treeManifest(destination)
            guard sameLayout(sourceManifest, existing) else { throw ModelStorageError.destinationExists }
        }
        guard let available = descriptor.availableBytes else { throw ModelStorageError.systemFileOperationFailed(underlying: "Cannot read destination free space") }
        let required = (adopting ? 0 : sourceFootprint.logicalBytes) + Self.diskSpaceHeadroom
        guard available >= required else { throw ModelStorageError.insufficientDiskSpace(required: required, available: available) }
        let copyID = UUID()
        let staging = parent.appending(path: ".Bonsai2 Models.copy-" + copyID.uuidString)
        if !adopting {
            guard let birth = ServerProcessDiscovery.birthIdentity(of: getpid()) else { throw ModelStorageError.verificationFailed }
            let journal = CopyJournal(id: copyID, ownerPID: getpid(), ownerBirth: birth, staging: staging.path)
            try fileManager.createDirectory(at: config.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        }
        var sampler = ModelStorageProgressSampler()
        let total = max(sourceFootprint.logicalBytes + sourceFootprint.artifactBytes, 1)
        // A crash leaves an identifiable copy in the destination folder. It is never
        // auto-deleted by a later instance on the basis of a matching filename.
        do {
            if !adopting {
                try await copyDirectory(from: source, to: staging, totalBytes: sourceFootprint.logicalBytes,
                    overallTotalBytes: total, sampler: &sampler, progress: progress)
            }
            do {
                try await verifyModelFiles(at: adopting ? destination : staging, canonicalRoot: source,
                    copiedBytes: sourceFootprint.logicalBytes, verificationBytes: sourceFootprint.artifactBytes,
                    overallTotalBytes: total, sampler: &sampler, progress: progress)
            } catch is CancellationError { throw CancellationError() }
            catch { throw adopting ? ModelStorageError.destinationContainsIncompleteCopy : error }
            let verificationRoot = adopting ? destination : staging
            let catalogPaths = Set(artifacts.map { "27B/" + $0.destinationURL.lastPathComponent })
            guard sameLayout(sourceManifest, try treeManifest(verificationRoot)) else { throw ModelStorageError.verificationFailed }
            for (relative, entry) in sourceManifest where !entry.directory && !catalogPaths.contains(relative) {
                try Task.checkCancellation()
                guard try FileChecksum().sha256(at: source.appending(path: relative)) == FileChecksum().sha256(at: verificationRoot.appending(path: relative)) else {
                    throw ModelStorageError.verificationFailed
                }
            }
            guard sourceManifest == (try treeManifest(source)) else { throw ModelStorageError.verificationFailed }
            try Task.checkCancellation()
            if !adopting { try fileManager.moveItem(at: staging, to: destination) }
            // Preserve the verified copy if the atomic record cannot be committed.
            try config.setModelsDirectory(destination, retainedSource: source)
            var notice: ModelStorageMigrationNotice?
            do { try fileManager.removeItem(at: source); try config.setModelsDirectory(destination) }
            catch { notice = .sourceLocationRetained(byteCount: try allocatedSize(of: source)) }
            if let update = sampler.update(phase: .switching, stageCompleted: 1, stageTotal: 1,
                overallCompleted: total, overallTotal: total, force: true) { await progress(update) }
            if !adopting { try ManagedFileSystem.removeIfPresent(journalURL) }
            return ModelStorageSnapshot(url: destination, byteCount: try allocatedSize(of: destination),
                isAvailable: true, isRelocated: true, notice: notice)
        } catch {
            let operationError = error
            if !adopting {
                do {
                    try ManagedFileSystem.removeIfPresent(staging)
                    try ManagedFileSystem.removeIfPresent(journalURL)
                } catch {
                    throw ModelStorageError.systemFileOperationFailed(underlying:
                        "\(operationError.localizedDescription); cleanup: \(error.localizedDescription)")
                }
            }
            throw operationError
        }
    }

    private func validateDestinationVolume(
        parent: URL,
        footprint: ModelStorageFootprint
    ) throws -> ModelStorageDestinationDescriptor {
        guard let descriptor = volumeDescriptorProvider(parent) else {
            throw ModelStorageError.systemFileOperationFailed(
                underlying: "destination volume could not be inspected at \(parent.path)"
            )
        }

        if descriptor.isReadOnly {
            throw ModelStorageError.destinationReadOnly
        }
        guard descriptor.isLocal else {
            throw ModelStorageError.destinationIsNetworkVolume
        }
        let cappedFileSize = descriptor.isKnownSizeRestrictedFileSystem
            || !descriptor.supportsFilesAbove4GB
        if cappedFileSize, footprint.largestFileBytes > ModelStorageDestinationProbe.fourGigabyteLimit {
            throw ModelStorageError.destinationFileSystemUnsupported(
                fileSystem: descriptor.fileSystemName,
                largestFileBytes: footprint.largestFileBytes
            )
        }
        return descriptor
    }

    private struct FileHandleBox: @unchecked Sendable {
        let handle: FileHandle
    }

    private func copyDirectory(
        from source: URL,
        to destination: URL,
        totalBytes: Int64,
        overallTotalBytes: Int64,
        sampler: inout ModelStorageProgressSampler,
        progress: @escaping @Sendable (ModelStorageMigrationProgress) async -> Void
    ) async throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var completedBytes: Int64 = 0
        for relativePath in try fileManager.subpathsOfDirectory(atPath: source.path) {
            try Task.checkCancellation()
            let sourceItem = source.appending(path: relativePath)
            let destinationItem = destination.appending(path: relativePath)
            let attributes = try fileManager.attributesOfItem(atPath: sourceItem.path)
            let type = attributes[.type] as? FileAttributeType

            if type == .typeDirectory {
                try fileManager.createDirectory(
                    at: destinationItem,
                    withIntermediateDirectories: true
                )
                continue
            }
            guard type == .typeRegular else { throw ModelStorageError.verificationFailed }

            try fileManager.createDirectory(
                at: destinationItem.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: destinationItem.path, contents: nil) else {
                throw ModelStorageError.destinationFileCreationFailed
            }

            let expectedBytes = try ManagedFileSystem.requiredFileSize(at: sourceItem)
            let sourceHandle = try FileHandle(forReadingFrom: sourceItem)
            let destinationHandle = try FileHandle(forWritingTo: destinationItem)
            defer {
                try? sourceHandle.close()
                try? destinationHandle.close()
            }

            let sHandle = FileHandleBox(handle: sourceHandle)
            let dHandle = FileHandleBox(handle: destinationHandle)
            var fileBytes: Int64 = 0

            while true {
                try Task.checkCancellation()
                let chunk = try await Self.transferChunk(from: sHandle, to: dHandle)
                try Task.checkCancellation()
                guard let chunk, !chunk.isEmpty else { break }

                fileBytes += Int64(chunk.count)
                completedBytes += Int64(chunk.count)
                if let update = sampler.update(
                    phase: .copying,
                    stageCompleted: completedBytes,
                    stageTotal: totalBytes,
                    overallCompleted: completedBytes,
                    overallTotal: overallTotalBytes
                ) {
                    await progress(update)
                }
            }

            try destinationHandle.synchronize()
            try destinationHandle.close()
            try sourceHandle.close()

            if fileBytes != expectedBytes {
                throw ModelStorageError.verificationFailed
            }

            if let permissions = attributes[.posixPermissions] {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: destinationItem.path
                )
            }
        }

        if let update = sampler.update(
            phase: .copying,
            stageCompleted: totalBytes,
            stageTotal: totalBytes,
            overallCompleted: totalBytes,
            overallTotal: overallTotalBytes,
            force: true
        ) {
            await progress(update)
        }
    }

    /// Reads one chunk and writes it out. A plain (cancellable, non-detached) task
    /// per chunk keeps the blocking file I/O off the cooperative pool call site while
    /// avoiding ~2,000 detached tasks for a 7.9 GB model.
    private nonisolated static func transferChunk(
        from source: FileHandleBox,
        to destination: FileHandleBox
    ) async throws -> Data? {
        try await Task {
            let data = try source.handle.read(upToCount: chunkSize)
            if let data, !data.isEmpty {
                try destination.handle.write(contentsOf: data)
            }
            return data
        }.value
    }

    private nonisolated static func readChunk(from handle: FileHandleBox) async throws -> Data? {
        try await Task {
            try handle.handle.read(upToCount: chunkSize)
        }.value
    }

    // MARK: - Verification

    private func verifyModelFiles(
        at root: URL,
        canonicalRoot: URL,
        copiedBytes: Int64,
        verificationBytes: Int64,
        overallTotalBytes: Int64,
        sampler: inout ModelStorageProgressSampler,
        progress: @escaping @Sendable (ModelStorageMigrationProgress) async -> Void
    ) async throws {
        var verifiedBytes: Int64 = 0
        if let update = sampler.update(
            phase: .verifying,
            stageCompleted: 0,
            stageTotal: verificationBytes,
            overallCompleted: copiedBytes,
            overallTotal: overallTotalBytes,
            force: true
        ) {
            await progress(update)
        }

        for artifact in artifacts {
            try Task.checkCancellation()
            let relativePath = "27B/" + artifact.destinationURL.lastPathComponent
            let candidate = root.appending(path: relativePath)
            guard try fileSize(at: candidate) == artifact.expectedByteCount else {
                throw ModelStorageError.verificationFailed
            }
            let handle = try FileHandle(forReadingFrom: candidate)
            defer { try? handle.close() }
            var hasher = SHA256()

            let box = FileHandleBox(handle: handle)

            while true {
                try Task.checkCancellation()
                let data = try await Self.readChunk(from: box)
                guard let data, !data.isEmpty else { break }

                hasher.update(data: data)
                verifiedBytes += Int64(data.count)
                if let update = sampler.update(
                    phase: .verifying,
                    stageCompleted: verifiedBytes,
                    stageTotal: verificationBytes,
                    overallCompleted: copiedBytes + verifiedBytes,
                    overallTotal: overallTotalBytes
                ) {
                    await progress(update)
                }
            }
            let actualChecksum = hasher.finalize().reduce(into: "") { result, byte in
                if byte < 16 { result.append("0") }
                result.append(String(byte, radix: 16))
            }
            guard actualChecksum == artifact.expectedSHA256 else {
                throw ModelStorageError.verificationFailed
            }
        }

        if let update = sampler.update(
            phase: .verifying,
            stageCompleted: verificationBytes,
            stageTotal: verificationBytes,
            overallCompleted: copiedBytes + verificationBytes,
            overallTotal: overallTotalBytes,
            force: true
        ) {
            await progress(update)
        }
    }

    private struct TreeEntry: Equatable {
        let directory: Bool
        let size: Int64
        let inode: UInt64
        let modified: Date
        let changeSeconds: Int
        let changeNanoseconds: Int
    }

    private func treeManifest(_ root: URL) throws -> [String: TreeEntry] {
        var entries: [String: TreeEntry] = [:]
        for relative in try fileManager.subpathsOfDirectory(atPath: root.path) {
            let attributes = try fileManager.attributesOfItem(atPath: root.appending(path: relative).path)
            guard let kind = attributes[.type] as? FileAttributeType,
                  kind == .typeDirectory || kind == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw ModelStorageError.verificationFailed }
            var metadata = stat()
            guard lstat(root.appending(path: relative).path, &metadata) == 0 else { throw ModelStorageError.verificationFailed }
            entries[relative] = TreeEntry(directory: kind == .typeDirectory,
                size: kind == .typeDirectory ? 0 : size.int64Value, inode: inode.uint64Value, modified: modified,
                changeSeconds: metadata.st_ctimespec.tv_sec, changeNanoseconds: metadata.st_ctimespec.tv_nsec)
        }
        return entries
    }

    private func sameLayout(_ lhs: [String: TreeEntry], _ rhs: [String: TreeEntry]) -> Bool {
        guard lhs.keys.sorted() == rhs.keys.sorted() else { return false }
        return lhs.allSatisfy { path, entry in
            rhs[path]?.directory == entry.directory && rhs[path]?.size == entry.size
        }
    }

    // MARK: - Sizing

    private struct ModelStorageFootprint {
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var largestFileBytes: Int64 = 0
        var artifactBytes: Int64 = 0
    }

    private func footprint(of root: URL) throws -> ModelStorageFootprint {
        var result = ModelStorageFootprint()
        let root = root.resolvingSymlinksInPath()
        let artifactPaths = Set(artifacts.map { "27B/" + $0.destinationURL.lastPathComponent })
        for relative in try fileManager.subpathsOfDirectory(atPath: root.path) {
            let item = root.appending(path: relative)
            guard let info = try ManagedFileSystem.metadata(at: item) else { throw ModelStorageError.sourceMissing }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            guard info.st_mode & S_IFMT == S_IFREG else { throw ModelStorageError.verificationFailed }
            let logical = try ManagedFileSystem.requiredFileSize(at: item)
            result.logicalBytes += logical
            result.allocatedBytes += try ManagedFileSystem.allocatedBytes(at: item)
            result.largestFileBytes = max(result.largestFileBytes, logical)
            if artifactPaths.contains(relative) { result.artifactBytes += logical }
        }
        return result
    }

    private func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func fileSize(at url: URL) throws -> Int64? { try ManagedFileSystem.fileSize(at: url) }
    private func allocatedSize(of root: URL) throws -> Int64 { try ManagedFileSystem.allocatedBytes(at: root) }
}
