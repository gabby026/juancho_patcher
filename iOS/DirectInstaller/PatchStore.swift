import Foundation
import CryptoKit

@MainActor
final class PatchStore: ObservableObject {
    @Published private(set) var activeRecords: [String: PatchRecord] = [:]

    // Persistent within the installer app sandbox, but completely separate
    // from the target game's files. These backups are removed after a
    // successful Unpatch.
    private let root: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        root = base
            .appendingPathComponent("JuanchoInstaller", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)

        try? fm.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        load()
    }

    func apply(
        document: JuanchoDocument,
        onProgress: @escaping (_ processed: Int, _ total: Int, _ path: String) -> Void
    ) async throws -> String {
        let container = try FilesystemTarget.locateApplication(
            bundleID: document.header.targetBundleID
        )

        let projectKey =
            "\(document.header.projectName)|\(document.header.targetBundleID)"

        if activeRecords[projectKey] != nil {
            throw patchError(100, "This patch is already applied.")
        }

        let total = document.manifest.rules.count
        var recordEntries: [PatchRecord.Entry] = []
        var completed: [(dest: URL, backupData: Data?, added: Bool)] = []

        do {
            var usedPayloads = Set<String>()

            for (index, rule) in document.manifest.rules.enumerated() {
                try Task.checkCancellation()

                let displayPath = sourceDisplayPath(
                    for: rule,
                    document: document
                )

                onProgress(index, total, displayPath)
                await Task.yield()

                let replacement = try replacementData(
                    for: rule,
                    document: document,
                    usedPayloads: &usedPayloads
                )

                try Task.checkCancellation()

                let dest = try FilesystemTarget.destinationURL(
                    container: container,
                    relativePath: rule.relativePath
                )

                let fm = FileManager.default
                let existed = fm.fileExists(atPath: dest.path)

                // Every existing file gets a private backup before replacement.
                let backupData = existed
                    ? try Data(contentsOf: dest)
                    : nil

                let backupPath = try backupData.map {
                    try saveBackup(
                        projectKey: projectKey,
                        destination: dest,
                        data: $0
                    )
                }

                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                completed.append(
                    (
                        dest,
                        backupData,
                        !existed
                    )
                )

                try replacement.write(
                    to: dest,
                    options: .atomic
                )

                // Verify the exact bytes we wrote.
                let written = try Data(contentsOf: dest)
                guard sha256(written) == rule.sha256 else {
                    throw patchError(
                        102,
                        "Hash verification failed after writing \(displayPath)."
                    )
                }

                recordEntries.append(
                    .init(
                        destination: rule.relativePath,
                        backupPath: backupPath?.path,
                        addedByPatch: !existed,
                        expectedSHA256: rule.sha256,
                        sourcePath: displayPath
                    )
                )

                onProgress(index + 1, total, displayPath)
                await Task.yield()
            }
        } catch {
            // Roll back anything already written during this Inject.
            let fm = FileManager.default

            for item in completed.reversed() {
                if let backup = item.backupData {
                    try? backup.write(
                        to: item.dest,
                        options: .atomic
                    )
                } else if item.added {
                    try? fm.removeItem(at: item.dest)
                }
            }

            // No partial patch should remain registered.
            cleanupBackupDirectory(projectKey: projectKey)

            throw error
        }

        let record = PatchRecord(
            packageName: document.header.projectName,
            bundleID: document.header.targetBundleID,
            appliedAt: Date(),
            entries: recordEntries
        )

        activeRecords[projectKey] = record
        save()

        return "Patched \(recordEntries.count) files."
    }

    func unpatch(
        projectName: String,
        bundleID: String,
        onProgress: @escaping (_ processed: Int, _ total: Int, _ path: String) -> Void
    ) async throws -> String {
        let projectKey = "\(projectName)|\(bundleID)"

        guard let record = activeRecords[projectKey] else {
            throw patchError(
                103,
                "No patch record exists for this project."
            )
        }

        let container = try FilesystemTarget.locateApplication(
            bundleID: bundleID
        )

        let fm = FileManager.default
        let total = record.entries.count

        // Validate that every required backup exists before changing anything.
        // The current target hash is deliberately NOT checked here:
        // the saved pre-patch backup is authoritative for restoration.
        for (index, entry) in record.entries.enumerated() {
            try Task.checkCancellation()

            let displayPath = entry.sourcePath
                ?? sourceDisplayPathFromDestination(entry.destination)

            onProgress(
                index,
                total,
                "Preparing \(displayPath)"
            )
            await Task.yield()

            if entry.addedByPatch {
                // This file did not exist before Inject, so it has no backup.
                // It will simply be removed during the restore pass.
                continue
            }

            guard let backupPath = entry.backupPath else {
                throw patchError(
                    105,
                    "Missing backup for \(displayPath)"
                )
            }

            guard fm.fileExists(atPath: backupPath) else {
                throw patchError(
                    107,
                    "Backup is missing for \(displayPath)"
                )
            }
        }

        var restored = 0

        for entry in record.entries.reversed() {
            try Task.checkCancellation()

            let displayPath = entry.sourcePath
                ?? sourceDisplayPathFromDestination(entry.destination)

            let dest = try FilesystemTarget.destinationURL(
                container: container,
                relativePath: entry.destination
            )

            onProgress(
                restored,
                total,
                displayPath
            )
            await Task.yield()

            if let backupPath = entry.backupPath {
                // Restore the original file regardless of what is currently
                // sitting at the target path.
                let backup = try Data(
                    contentsOf: URL(fileURLWithPath: backupPath)
                )

                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                try backup.write(
                    to: dest,
                    options: .atomic
                )

                restored += 1
            } else if entry.addedByPatch {
                // Newly introduced patch file: remove it completely.
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }

                restored += 1
            }

            onProgress(
                restored,
                total,
                displayPath
            )
            await Task.yield()
        }

        // Remove patch metadata and all private backups after a successful
        // restore/remove pass.
        activeRecords.removeValue(forKey: projectKey)
        save()
        cleanupBackupDirectory(projectKey: projectKey)

        return "Unpatched \(restored) files."
    }

    private func replacementData(
        for rule: JuanchoRule,
        document: JuanchoDocument,
        usedPayloads: inout Set<String>
    ) throws -> Data {
        let base = normalized(document.header.basePath)
        let destination = normalized(rule.relativePath)

        let prefix = base.isEmpty ? "" : base + "/"

        let expected = destination.hasPrefix(prefix)
            ? String(destination.dropFirst(prefix.count))
            : destination

        let exact = document.files.filter {
            normalized($0.path) == expected
        }

        if let unique = exact.first {
            guard !usedPayloads.contains(unique.path) else {
                throw patchError(
                    108,
                    "Payload is referenced more than once: \(unique.path)"
                )
            }

            usedPayloads.insert(unique.path)
            return unique.data
        }

        let byName = document.files.filter {
            URL(fileURLWithPath: $0.path).lastPathComponent
                == rule.replacementFilename
        }

        let unusedByName = byName.filter {
            !usedPayloads.contains($0.path)
        }

        guard unusedByName.count == 1,
              let unique = unusedByName.first else {
            throw patchError(
                101,
                unusedByName.isEmpty
                    ? "Missing replacement payload: \(rule.replacementFilename)"
                    : "Ambiguous replacement payload: \(rule.replacementFilename)"
            )
        }

        usedPayloads.insert(unique.path)
        return unique.data
    }

    private func sourceDisplayPath(
        for rule: JuanchoRule,
        document: JuanchoDocument
    ) -> String {
        let base = normalized(document.header.basePath)
        let destination = normalized(rule.relativePath)
        let prefix = base.isEmpty ? "" : base + "/"

        let expected = destination.hasPrefix(prefix)
            ? String(destination.dropFirst(prefix.count))
            : destination

        if let exact = document.files.first(where: {
            normalized($0.path) == expected
        }) {
            return displaySourcePath(
                exact.path,
                base: base
            )
        }

        if let byName = document.files.first(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent
                == rule.replacementFilename
        }) {
            return displaySourcePath(
                byName.path,
                base: base
            )
        }

        return rule.replacementFilename
    }

    private func sourceDisplayPathFromDestination(
        _ destination: String
    ) -> String {
        let value = normalized(destination)
        let defaultBase = normalized("Documents/dragon2017/assets")
        let prefix = defaultBase + "/"

        if value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }

        return URL(fileURLWithPath: value).lastPathComponent
    }

    private func displaySourcePath(
        _ value: String,
        base: String
    ) -> String {
        let path = normalized(value)

        if !base.isEmpty, path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }

        let defaultBase = normalized("Documents/dragon2017/assets")
        if path.hasPrefix(defaultBase + "/") {
            return String(path.dropFirst(defaultBase.count + 1))
        }

        return path
    }

    private func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func saveBackup(
        projectKey: String,
        destination: URL,
        data: Data
    ) throws -> URL {
        let safeProject = Data(projectKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")

        let dir = root.appendingPathComponent(
            safeProject,
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let url = dir.appendingPathComponent(
            sha256(Data(destination.path.utf8)) + ".bak"
        )

        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(
                to: url,
                options: .atomic
            )
        }

        return url
    }

    private func cleanupBackupDirectory(projectKey: String) {
        let safeProject = Data(projectKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")

        let dir = root.appendingPathComponent(
            safeProject,
            isDirectory: true
        )

        try? FileManager.default.removeItem(at: dir)
    }

    private func save() {
        let url = root.appendingPathComponent("records.json")

        if let data = try? JSONEncoder().encode(activeRecords) {
            try? data.write(
                to: url,
                options: .atomic
            )
        }
    }

    private func load() {
        let url = root.appendingPathComponent("records.json")

        guard
            let data = try? Data(contentsOf: url),
            let records = try? JSONDecoder().decode(
                [String: PatchRecord].self,
                from: data
            )
        else {
            return
        }

        activeRecords = records
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func patchError(
        _ code: Int,
        _ message: String
    ) -> NSError {
        NSError(
            domain: "Juancho",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }
}
