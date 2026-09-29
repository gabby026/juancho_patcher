import Foundation

struct LocalFile: Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
}

enum InstallEvent: Sendable {
    case creatingDirectory(String)
    case installing(current: Int, total: Int, path: String)
    case installed(String)
    case failed(String, String)
}

struct InstallResult: Sendable {
    var succeeded = 0
    var failed = 0
}

enum InstallError: LocalizedError {
    case invalidSourcePath
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case cannotReadSource(String)
    case sourceReadFailed(path: String, reason: String)
    case noSourceFiles(String)
    case destinationNotFound(String)
    case destinationNotDirectory(String)
    case destinationCreateFailed(String, String)
    case copyFailed(path: String, reason: String)
    case unofficialBuild
    case emptyDestination

    var errorDescription: String? {
        switch self {
        case .invalidSourcePath:
            return "Enter an absolute source path beginning with /."
        case .sourceNotFound(let path):
            return "Source folder was not found: \(path)"
        case .sourceNotDirectory(let path):
            return "Source path is not a folder: \(path)"
        case .cannotReadSource(let path):
            return "The app cannot read \(path). Install this IPA with the required filesystem access."
        case let .sourceReadFailed(path, reason):
            return "The app could not scan \(path): \(reason)"
        case .noSourceFiles(let path):
            return "No regular files were found in \(path)."
        case .destinationNotFound(let path):
            return "Destination folder was not found: \(path)"
        case .destinationNotDirectory(let path):
            return "Destination path is not a folder: \(path)"
        case let .destinationCreateFailed(path, reason):
            return "Could not create destination folder \(path): \(reason)"
        case let .copyFailed(path, reason):
            return "Could not install \(path): \(reason)"
        case .unofficialBuild:
            return "This is not an official Juancho Installer build."
        case .emptyDestination:
            return "Enter a destination folder path."
        }
    }
}

enum FileScanner {
    static func scan(folderURL: URL) throws -> [LocalFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var firstEnumerationError: Error?

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                if firstEnumerationError == nil { firstEnumerationError = error }
                return true
            }
        ) else {
            throw InstallError.cannotReadSource(folderURL.path)
        }

        let rootPath = folderURL.standardizedFileURL.path
        var files: [LocalFile] = []

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: keys)
            } catch {
                if firstEnumerationError == nil { firstEnumerationError = error }
                continue
            }

            guard values.isRegularFile == true else { continue }

            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath) else { continue }

            var relative = String(fullPath.dropFirst(rootPath.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            files.append(
                LocalFile(
                    url: fileURL,
                    relativePath: relative.replacingOccurrences(of: "\\", with: "/"),
                    size: Int64(values.fileSize ?? 0)
                )
            )
        }

        if files.isEmpty, let firstEnumerationError {
            throw InstallError.sourceReadFailed(
                path: folderURL.path,
                reason: firstEnumerationError.localizedDescription
            )
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}


struct PatchFileRecord: Codable, Sendable {
    let relativePath: String
    let existedBefore: Bool
}

struct PatchRecord: Codable, Identifiable, Sendable {
    let id: String
    let createdAt: Date
    let sourcePath: String
    let destinationPath: String
    let files: [PatchFileRecord]

    var fileCount: Int { files.count }
}

enum PatchEvent: Sendable {
    case backingUp(current: Int, total: Int, path: String)
    case replacing(current: Int, total: Int, path: String)
    case patched(path: String)
    case restoring(current: Int, total: Int, path: String)
    case restored(path: String)
    case failed(path: String, reason: String)
}

enum PatchError: LocalizedError {
    case overlappingPatch(String)
    case backupFailed(path: String, reason: String)
    case patchFailed(path: String, reason: String)
    case patchRollbackFailed(path: String, reason: String)
    case manifestFailed(String)
    case patchNotFound(String)
    case restoreFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .overlappingPatch(let path):
            return "That file is already part of another active patch: \(path). Unpatch the existing patch first."
        case let .backupFailed(path, reason):
            return "Could not back up \(path): \(reason)"
        case let .patchFailed(path, reason):
            return "Could not replace \(path): \(reason)"
        case let .patchRollbackFailed(path, reason):
            return "Patch failed and rollback also failed for \(path): \(reason)"
        case .manifestFailed(let reason):
            return "Could not save the patch record: \(reason)"
        case .patchNotFound(let id):
            return "Patch record was not found: \(id)"
        case let .restoreFailed(path, reason):
            return "Could not restore \(path): \(reason)"
        }
    }
}

actor PatchManager {
    static let shared = PatchManager()

    private let fileManager = FileManager.default
    private let patchesRoot: URL

    init() {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        patchesRoot = support.appendingPathComponent(
            "JuanchoInstaller/Patches",
            isDirectory: true
        )

        try? fileManager.createDirectory(
            at: patchesRoot,
            withIntermediateDirectories: true
        )
    }

    func listPatches() -> [PatchRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: patchesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return urls.compactMap { url in
            let manifest = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? decoder.decode(PatchRecord.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func checkDestination(_ path: String) throws {
        _ = try validatedDestinationURL(path)
    }

    func patch(
        files: [LocalFile],
        sourcePath: String,
        destinationPath: String,
        onEvent: @Sendable (PatchEvent) async -> Void
    ) async throws -> PatchRecord {
        let destinationRoot = try validatedDestinationURL(destinationPath)
        let active = listPatches()

        let activePaths = Set(
            active.flatMap { patch in
                patch.files.map { patch.destinationPath + "/" + $0.relativePath }
            }
        )

        for file in files {
            let absolute = destinationRoot
                .appendingPathComponent(file.relativePath)
                .standardizedFileURL
                .path

            if activePaths.contains(absolute) {
                throw PatchError.overlappingPatch(file.relativePath)
            }
        }

        let id = UUID().uuidString
        let patchDirectory = patchesRoot.appendingPathComponent(id, isDirectory: true)
        let backupRoot = patchDirectory.appendingPathComponent("backup", isDirectory: true)

        try fileManager.createDirectory(
            at: backupRoot,
            withIntermediateDirectories: true
        )

        var records: [PatchFileRecord] = []
        var changedDestinations: [(url: URL, existedBefore: Bool, backup: URL?)] = []

        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()

                let destination = destinationRoot
                    .appendingPathComponent(file.relativePath)
                    .standardizedFileURL

                let parent = destination.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )

                let existed = fileManager.fileExists(atPath: destination.path)
                var backupURL: URL?

                if existed {
                    let backup = backupRoot
                        .appendingPathComponent(file.relativePath)
                        .standardizedFileURL

                    let backupParent = backup.deletingLastPathComponent()
                    try fileManager.createDirectory(
                        at: backupParent,
                        withIntermediateDirectories: true
                    )

                    await onEvent(
                        .backingUp(
                            current: index + 1,
                            total: files.count,
                            path: file.relativePath
                        )
                    )

                    do {
                        try fileManager.copyItem(at: destination, to: backup)
                    } catch {
                        throw PatchError.backupFailed(
                            path: file.relativePath,
                            reason: error.localizedDescription
                        )
                    }

                    backupURL = backup
                }

                await onEvent(
                    .replacing(
                        current: index + 1,
                        total: files.count,
                        path: file.relativePath
                    )
                )

                if existed {
                    try fileManager.removeItem(at: destination)
                }

                do {
                    try fileManager.copyItem(at: file.url, to: destination)
                } catch {
                    throw PatchError.patchFailed(
                        path: file.relativePath,
                        reason: error.localizedDescription
                    )
                }

                records.append(
                    PatchFileRecord(
                        relativePath: file.relativePath,
                        existedBefore: existed
                    )
                )

                changedDestinations.append(
                    (
                        url: destination,
                        existedBefore: existed,
                        backup: backupURL
                    )
                )

                await onEvent(.patched(path: file.relativePath))
            }

            let record = PatchRecord(
                id: id,
                createdAt: Date(),
                sourcePath: sourcePath,
                destinationPath: destinationRoot.path,
                files: records
            )

            try save(record)
            return record
        } catch {
            for changed in changedDestinations.reversed() {
                do {
                    if fileManager.fileExists(atPath: changed.url.path) {
                        try fileManager.removeItem(at: changed.url)
                    }

                    if changed.existedBefore, let backup = changed.backup {
                        try fileManager.copyItem(at: backup, to: changed.url)
                    }
                } catch {
                    throw PatchError.patchRollbackFailed(
                        path: changed.url.path,
                        reason: error.localizedDescription
                    )
                }
            }

            try? fileManager.removeItem(at: patchDirectory)
            throw error
        }
    }

    func unpatch(
        _ patch: PatchRecord,
        onEvent: @Sendable (PatchEvent) async -> Void
    ) async throws {
        let patchDirectory = patchesRoot.appendingPathComponent(patch.id, isDirectory: true)
        let backupRoot = patchDirectory.appendingPathComponent("backup", isDirectory: true)
        let destinationRoot = URL(
            fileURLWithPath: patch.destinationPath,
            isDirectory: true
        ).resolvingSymlinksInPath()

        for (index, file) in patch.files.enumerated().reversed() {
            try Task.checkCancellation()

            let destination = destinationRoot
                .appendingPathComponent(file.relativePath)
                .standardizedFileURL

            await onEvent(
                .restoring(
                    current: patch.files.count - index,
                    total: patch.files.count,
                    path: file.relativePath
                )
            )

            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }

                if file.existedBefore {
                    let backup = backupRoot
                        .appendingPathComponent(file.relativePath)
                        .standardizedFileURL

                    guard fileManager.fileExists(atPath: backup.path) else {
                        throw PatchError.restoreFailed(
                            path: file.relativePath,
                            reason: "Backup file is missing."
                        )
                    }

                    let parent = destination.deletingLastPathComponent()
                    try fileManager.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: backup, to: destination)
                }

                await onEvent(.restored(path: file.relativePath))
            } catch let error as PatchError {
                throw error
            } catch {
                throw PatchError.restoreFailed(
                    path: file.relativePath,
                    reason: error.localizedDescription
                )
            }
        }

        try fileManager.removeItem(at: patchDirectory)
    }

    private func validatedDestinationURL(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw InstallError.emptyDestination
        }

        let url = URL(
            fileURLWithPath: trimmed,
            isDirectory: true
        ).resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InstallError.destinationNotDirectory(url.path)
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            } catch {
                throw InstallError.destinationCreateFailed(
                    url.path,
                    error.localizedDescription
                )
            }
        }

        // Verify actual write access before patching. A directory can exist
        // while the process still lacks permission to modify its contents.
        let probe = url.appendingPathComponent(".juancho_write_test_\\(UUID().uuidString)")
        do {
            try Data("JUANCHO_WRITE_TEST".utf8).write(to: probe, options: [.atomic])
            try fileManager.removeItem(at: probe)
        } catch {
            try? fileManager.removeItem(at: probe)
            throw InstallError.destinationCreateFailed(
                url.path,
                "The folder exists, but this app cannot write to it: \\(error.localizedDescription)"
            )
        }

        return url
    }

    private func save(_ record: PatchRecord) throws {
        let directory = patchesRoot.appendingPathComponent(
            record.id,
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(record)
            try data.write(
                to: directory.appendingPathComponent("manifest.json"),
                options: [.atomic]
            )
        } catch {
            throw PatchError.manifestFailed(error.localizedDescription)
        }
    }
}

actor DirectFileInstaller {
    private let destinationURL: URL

    init(destinationPath: String) throws {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw InstallError.emptyDestination
        }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true).resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InstallError.destinationNotDirectory(url.path)
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            } catch {
                throw InstallError.destinationCreateFailed(
                    url.path,
                    error.localizedDescription
                )
            }
        }

        destinationURL = url
    }

    func install(
        files: [LocalFile],
        onEvent: @Sendable (InstallEvent) async -> Void
    ) async -> InstallResult {
        var result = InstallResult()
        let fileManager = FileManager.default

        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }

            do {
                try Task.checkCancellation()

                let destination = destinationURL
                    .appendingPathComponent(file.relativePath, isDirectory: false)

                let parent = destination.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    await onEvent(.creatingDirectory(parent.path))
                    try fileManager.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                }

                await onEvent(
                    .installing(
                        current: index + 1,
                        total: files.count,
                        path: file.relativePath
                    )
                )

                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }

                do {
                    try fileManager.copyItem(at: file.url, to: destination)
                } catch {
                    throw InstallError.copyFailed(
                        path: file.relativePath,
                        reason: error.localizedDescription
                    )
                }

                result.succeeded += 1
                await onEvent(
                    .installed(
                        "\(file.relativePath) → \(destination.path)"
                    )
                )
            } catch is CancellationError {
                break
            } catch {
                result.failed += 1
                await onEvent(
                    .failed(file.relativePath, error.localizedDescription)
                )
            }
        }

        return result
    }
}
