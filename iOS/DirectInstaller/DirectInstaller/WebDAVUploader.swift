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
