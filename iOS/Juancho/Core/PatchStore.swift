import Foundation
import CryptoKit

@MainActor
final class PatchStore: ObservableObject {
    @Published private(set) var activeRecords: [String: PatchRecord] = [:]
    private let root: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("JuanchoPatches", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func apply(document: JuanchoDocument) throws -> String {
        let container = try FilesystemTarget.locateApplication(bundleID: document.header.targetBundleID)
        let projectKey = "\(document.header.projectName)|\(document.header.targetBundleID)"
        if activeRecords[projectKey] != nil {
            throw patchError(100, "This patch is already applied.")
        }

        var recordEntries: [PatchRecord.Entry] = []
        var completed: [(dest: URL, backup: Data?, added: Bool)] = []

        do {
            var usedPayloads = Set<String>()
            for rule in document.manifest.rules {
                let replacement = try replacementData(for: rule, document: document, usedPayloads: &usedPayloads)
                let dest = try FilesystemTarget.destinationURL(
                    container: container,
                    relativePath: rule.relativePath
                )

                let fm = FileManager.default
                let existed = fm.fileExists(atPath: dest.path)
                var backupPath: URL?

                if existed {
                    let backupData = try Data(contentsOf: dest)
                    backupPath = try saveBackup(projectKey: projectKey, destination: dest, data: backupData)
                }

                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try replacement.write(to: dest, options: .atomic)

                let written = try Data(contentsOf: dest)
                guard sha256(written) == rule.sha256 else {
                    throw patchError(102, "Hash verification failed after writing \(rule.relativePath).")
                }

                completed.append((dest, backupPath.flatMap { try? Data(contentsOf: $0) }, !existed))
                recordEntries.append(
                    .init(
                        destination: rule.relativePath,
                        backupPath: backupPath?.path,
                        addedByPatch: !existed,
                        expectedSHA256: rule.sha256
                    )
                )
            }
        } catch {
            for item in completed.reversed() {
                if let backup = item.backup {
                    try? backup.write(to: item.dest, options: .atomic)
                } else if item.added {
                    try? FileManager.default.removeItem(at: item.dest)
                }
            }
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

    func unpatch(projectName: String, bundleID: String) throws -> String {
        let projectKey = "\(projectName)|\(bundleID)"
        guard let record = activeRecords[projectKey] else {
            throw patchError(103, "No patch record exists for this project.")
        }

        let container = try FilesystemTarget.locateApplication(bundleID: bundleID)
        let fm = FileManager.default
        var restored = 0

        for entry in record.entries.reversed() {
            let dest = try FilesystemTarget.destinationURL(
                container: container,
                relativePath: entry.destination
            )

            if let backupPath = entry.backupPath,
               let backup = try? Data(contentsOf: URL(fileURLWithPath: backupPath)) {
                try backup.write(to: dest, options: .atomic)
                restored += 1
            } else if entry.addedByPatch, fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
                restored += 1
            }
        }

        activeRecords.removeValue(forKey: projectKey)
        save()
        return "Unpatched \(restored) files."
    }

    func state(projectName: String, bundleID: String) -> PatchRecord? {
        activeRecords["\(projectName)|\(bundleID)"]
    }

    private func replacementData(
        for rule: JuanchoRule,
        document: JuanchoDocument,
        usedPayloads: inout Set<String>
    ) throws -> Data {
        let base = document.header.basePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
        let destination = rule.relativePath.replacingOccurrences(of: "\\", with: "/")
        let prefix = base.isEmpty ? "" : base + "/"
        let expected = destination.hasPrefix(prefix)
            ? String(destination.dropFirst(prefix.count))
            : destination

        let exact = document.files.filter {
            $0.path.replacingOccurrences(of: "\\", with: "/") == expected
        }
        if let unique = exact.first {
            usedPayloads.insert(unique.path)
            return unique.data
        }

        let byName = document.files.filter {
            URL(fileURLWithPath: $0.path).lastPathComponent == rule.replacementFilename
        }
        let unusedByName = byName.filter { !usedPayloads.contains($0.path) }

        guard unusedByName.count == 1, let unique = unusedByName.first else {
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

    private func saveBackup(projectKey: String, destination: URL, data: Data) throws -> URL {
        let safe = Data(projectKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let dir = root.appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(sha256(Data(destination.path.utf8)) + ".bak")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    private func save() {
        let url = root.appendingPathComponent("records.json")
        if let data = try? JSONEncoder().encode(activeRecords) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        let url = root.appendingPathComponent("records.json")
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([String: PatchRecord].self, from: data) else { return }
        activeRecords = records
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func patchError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Juancho", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
