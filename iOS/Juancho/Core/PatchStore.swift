import Foundation
import CryptoKit
import Security

enum PatchBackupTokenStore {
    private static let service = "com.juancho.patchmanager.private"
    private static let account = "cloud-token"

    private static var fallbackURL: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Juancho", isDirectory: true)
            .appendingPathComponent(account)
    }

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return (try? String(contentsOf: fallbackURL, encoding: .utf8)) ?? ""
    }

    static func save(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else {
            try? FileManager.default.removeItem(at: fallbackURL)
            return
        }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackURL)
            return
        }
        let dir = fallbackURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: fallbackURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fallbackURL.path
        )
    }
}

actor PatchBackupCloud {
    private let baseURL = URL(string: "https://juancho-toolkit-fresh.casipitgab69.workers.dev")!

    func upload(data: Data, key: String, token: String) async throws {
        try await request(method: "PUT", key: key, token: token, body: data)
    }

    func upload(fileURL: URL, key: String, token: String) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/storage/backup"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "X-Juancho-App-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Juancho Patcher iOS", forHTTPHeaderField: "User-Agent")

        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber {
            request.setValue(size.stringValue, forHTTPHeaderField: "Content-Length")
        }

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "Juancho", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Cloud backup upload failed (HTTP \(code))."
            ])
        }
    }

    func download(key: String, token: String) async throws -> Data {
        let (data, response) = try await requestData(method: "GET", key: key, token: token, body: nil)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "Juancho", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Cloud backup download failed (HTTP \(code))."
            ])
        }
        return data
    }

    func delete(key: String, token: String) async throws {
        try await request(method: "DELETE", key: key, token: token, body: nil)
    }

    private func request(method: String, key: String, token: String, body: Data?) async throws {
        let (_, response) = try await requestData(method: method, key: key, token: token, body: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NSError(domain: "Juancho", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Cloud backup request failed (HTTP \(code))."
            ])
        }
    }

    private func requestData(method: String, key: String, token: String, body: Data?) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/storage/backup"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Juancho-App-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Juancho Patcher iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        return try await URLSession.shared.data(for: request)
    }
}

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

    func apply(
        document: JuanchoDocument,
        sourceFileName: String?,
        destinationOverride: String?,
        cloudToken: String,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> String {
        onProgress?(0.02, "Patch in process: locating target application.")
        let container = try FilesystemTarget.locateApplication(bundleID: document.header.targetBundleID)
        let projectKey = "\(document.header.projectName)|\(document.header.targetBundleID)"
        if activeRecords[projectKey] != nil {
            throw patchError(100, "This patch is already applied.")
        }

        var recordEntries: [PatchRecord.Entry] = []
        var completed: [(dest: URL, backupPath: URL?, added: Bool)] = []

        do {
            var usedPayloads = Set<String>()
            let totalRules = max(document.manifest.rules.count, 1)

            for (index, rule) in document.manifest.rules.enumerated() {
                let ruleStart = Double(index) / Double(totalRules)
                let ruleEnd = Double(index + 1) / Double(totalRules)
                onProgress?(0.05 + (ruleStart * 0.85), "Preparing target: \(rule.relativePath)")

                let replacement = try replacementData(for: rule, document: document, usedPayloads: &usedPayloads)
                let dest = try FilesystemTarget.destinationURL(
                    container: container,
                    relativePath: rule.relativePath,
                    packageBasePath: document.header.basePath,
                    destinationOverride: destinationOverride
                )

                let fm = FileManager.default
                let existed = fm.fileExists(atPath: dest.path)
                var backupPath: URL?

                if existed {
                    onProgress?(
                        0.05 + (ruleStart * 0.85) + ((ruleEnd - ruleStart) * 0.20),
                        "Creating local backup: \(rule.relativePath)"
                    )
                    // Local-first backup: a direct file copy avoids loading the whole
                    // original into memory and avoids waiting for Cloudflare before
                    // the actual replacement can begin.
                    backupPath = try saveBackupCopy(
                        projectKey: projectKey,
                        destination: dest
                    )

                    onProgress?(
                        0.05 + (ruleStart * 0.85) + ((ruleEnd - ruleStart) * 0.35),
                        "Local backup ready: \(rule.relativePath)"
                    )
                }

                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                completed.append((dest, backupPath, !existed))
                try replacement.write(to: dest, options: .atomic)
                onProgress?(
                    0.05 + (ruleStart * 0.85) + ((ruleEnd - ruleStart) * 0.65),
                    "Replacement written: \(rule.relativePath)"
                )

                // Hash the already-loaded replacement bytes rather than reading the
                // newly written file back from disk.
                guard sha256(replacement) == rule.sha256 else {
                    throw patchError(102, "Hash verification failed after writing \(rule.relativePath).")
                }

                onProgress?(
                    0.05 + (ruleStart * 0.85) + ((ruleEnd - ruleStart) * 0.90),
                    "Patch verified locally: \(rule.relativePath)"
                )
                recordEntries.append(.init(
                    destination: rule.relativePath,
                    backupPath: backupPath?.path,
                    backupStorageKey: nil,
                    addedByPatch: !existed,
                    expectedSHA256: rule.sha256
                ))
            }
        } catch {
            let fm = FileManager.default
            for item in completed.reversed() {
                if let backupPath = item.backupPath {
                    try? fm.removeItem(at: item.dest)
                    try? fm.copyItem(at: backupPath, to: item.dest)
                } else if item.added {
                    try? fm.removeItem(at: item.dest)
                }
            }
            throw error
        }

        let record = PatchRecord(
            packageName: document.header.projectName,
            bundleID: document.header.targetBundleID,
            appliedAt: Date(),
            sourceFileName: sourceFileName,
            packageBasePath: document.header.basePath,
            destinationRoot: destinationOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? destinationOverride : nil,
            entries: recordEntries
        )

        activeRecords[projectKey] = record
        save()

        onProgress?(1.0, "Patch process succeeded locally: \(recordEntries.count) file(s). Original files are stored only in the local restore backup.")

        return "Patched \(recordEntries.count) files."
    }

    func unpatch(
        projectName: String,
        bundleID: String,
        cloudToken: String,
        forceRestoreModifiedFiles: Bool = true,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> String {
        onProgress?(0.02, "Restore in process: validating the patched files.")
        let projectKey = "\(projectName)|\(bundleID)"
        guard let record = activeRecords[projectKey] else {
            throw patchError(103, "No patch record exists for this project.")
        }
        return try await unpatchRecord(
            projectKey: projectKey,
            record: record,
            cloudToken: cloudToken,
            forceRestoreModifiedFiles: forceRestoreModifiedFiles,
            onProgress: onProgress
        )
    }

    func unpatch(
        sourceFileName: String,
        cloudToken: String,
        forceRestoreModifiedFiles: Bool = true,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> String {
        guard let match = activeRecords.first(where: {
            $0.value.sourceFileName?.caseInsensitiveCompare(sourceFileName) == .orderedSame
        }) else {
            throw patchError(103, "No active patch record exists for \(sourceFileName).")
        }
        return try await unpatchRecord(
            projectKey: match.key,
            record: match.value,
            cloudToken: cloudToken,
            forceRestoreModifiedFiles: forceRestoreModifiedFiles,
            onProgress: onProgress
        )
    }

    private func unpatchRecord(
        projectKey: String,
        record: PatchRecord,
        cloudToken: String,
        forceRestoreModifiedFiles: Bool,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> String {
        let container = try FilesystemTarget.locateApplication(bundleID: record.bundleID)
        let fm = FileManager.default
        let totalEntries = max(record.entries.count, 1)

        // Preflight before changing anything. Cloud backups are downloaded once and
        // retained for the restore pass. A normal unpatch stays conservative, while
        // the toolkit can explicitly request a full restore when the target changed
        // after patching.
        var modifiedDestinations: [String] = []
        var missingDestinations: [String] = []

        for (index, entry) in record.entries.enumerated() {
            let scanProgress = 0.05 + (Double(index) / Double(totalEntries)) * 0.15
            let preflightProgress = 0.20 + (Double(index) / Double(totalEntries)) * 0.25
            onProgress?(scanProgress, "Checking current target: \(entry.destination)")
            let dest = try FilesystemTarget.destinationURL(
                container: container,
                relativePath: entry.destination,
                packageBasePath: record.packageBasePath,
                destinationOverride: record.destinationRoot
            )

            if entry.addedByPatch {
                if fm.fileExists(atPath: dest.path) && !forceRestoreModifiedFiles {
                    let current = try Data(contentsOf: dest)
                    if sha256(current) != entry.expectedSHA256 {
                        modifiedDestinations.append(entry.destination)
                        throw patchError(104, "Refusing to remove modified file: \(entry.destination)")
                    }
                }
                continue
            }

            guard entry.backupStorageKey != nil || entry.backupPath != nil else {
                throw patchError(105, "Missing backup for \(entry.destination)")
            }

            let localBackupExists: Bool
            if let path = entry.backupPath {
                localBackupExists = fm.fileExists(atPath: path)
            } else {
                localBackupExists = false
            }

            if fm.fileExists(atPath: dest.path) {
                if !forceRestoreModifiedFiles {
                    let current = try Data(contentsOf: dest)
                    if sha256(current) != entry.expectedSHA256 {
                        modifiedDestinations.append(entry.destination)
                        throw patchError(104, "Refusing to overwrite modified file: \(entry.destination)")
                    }
                }
            } else {
                missingDestinations.append(entry.destination)
                if !forceRestoreModifiedFiles {
                    throw patchError(106, "Patched file is missing: \(entry.destination)")
                }
            }

            if localBackupExists {
                onProgress?(preflightProgress, "Local restore backup ready: \(entry.destination)")
            } else if entry.backupStorageKey != nil {
                throw patchError(107, "Legacy cloud-only backup found for \(entry.destination). This build no longer creates cloud backups; reapply the patch once to create a local restore backup.")
            } else {
                throw patchError(107, "Local restore backup is missing for \(entry.destination)")
            }
        }

        if forceRestoreModifiedFiles && (!modifiedDestinations.isEmpty || !missingDestinations.isEmpty) {
            onProgress?(0.45, "Restore preflight succeeded. \(modifiedDestinations.count) modified and \(missingDestinations.count) missing file(s) will be reconciled.")
        } else {
            onProgress?(0.45, "Restore preflight succeeded using local backups where available.") 
        }
        var restored = 0
        var restoreWarnings = 0
        do {
            for (index, entry) in record.entries.reversed().enumerated() {
                let restoreProgress = 0.50 + (Double(index) / Double(totalEntries)) * 0.38
                onProgress?(restoreProgress, "Restoring default file: \(entry.destination)")
                let dest = try FilesystemTarget.destinationURL(
                    container: container,
                    relativePath: entry.destination,
                    packageBasePath: record.packageBasePath,
                    destinationOverride: record.destinationRoot
                )

                if let path = entry.backupPath,
                   fm.fileExists(atPath: path) {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.removeItemIfExists(at: dest)
                    try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
                    restored += 1
                    onProgress?(min(0.88, restoreProgress + 0.07), "Restore succeeded from local backup: \(entry.destination)")
                } else if entry.addedByPatch, fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                    restored += 1
                    if modifiedDestinations.contains(entry.destination) {
                        restoreWarnings += 1
                    }
                    onProgress?(min(0.88, restoreProgress + 0.07), "Restore succeeded: removed added file \(entry.destination)")
                }
            }

            // Do not make cleanup part of the restore critical path.
            // The restored files are already in place, so report success first and
            // let local/cloud backup cleanup happen asynchronously.
        } catch {
            throw error
        }

        activeRecords.removeValue(forKey: projectKey)
        save()

        if forceRestoreModifiedFiles && (!modifiedDestinations.isEmpty || !missingDestinations.isEmpty) {
            onProgress?(
                0.96,
                "Restore reconciliation complete: \(modifiedDestinations.count) modified, \(missingDestinations.count) missing, \(restoreWarnings) modified added file(s) removed."
            )
        }

        let cleanupEntries = record.entries
        Task.detached(priority: .utility) {
            for entry in cleanupEntries {
                if let path = entry.backupPath {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                }
            }
        }

        onProgress?(1.0, "Restore process succeeded: \(restored) file(s) restored.")
        return forceRestoreModifiedFiles && !modifiedDestinations.isEmpty
            ? "Unpatched \(restored) files and restored saved backups (\(modifiedDestinations.count) target(s) had changed)."
            : "Unpatched \(restored) files and scheduled backup cleanup."
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

        let destination = rule.relativePath
            .replacingOccurrences(of: "\\", with: "/")

        let prefix = base.isEmpty ? "" : base + "/"
        let expected = destination.hasPrefix(prefix)
            ? String(destination.dropFirst(prefix.count))
            : destination

        let exact = document.files.filter {
            $0.path.replacingOccurrences(of: "\\", with: "/") == expected
        }

        if let unique = exact.first {
            guard !usedPayloads.contains(unique.path) else {
                throw patchError(108, "Payload is referenced more than once: \(unique.path)")
            }
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

    private func saveBackupCopy(
        projectKey: String,
        destination: URL
    ) throws -> URL {
        let safe = Data(projectKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")

        let dir = root.appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let url = dir.appendingPathComponent(
            sha256(Data(destination.path.utf8)) + ".bak"
        )

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        // Keep only the original file in the app's local Application Support.
        // It is never uploaded or sent to the patch-download service.
        try FileManager.default.copyItem(at: destination, to: url)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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
        guard
            let data = try? Data(contentsOf: url),
            let records = try? JSONDecoder().decode(
                [String: PatchRecord].self,
                from: data
            )
        else { return }

        activeRecords = records
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func patchError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "Juancho",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}


private extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}
