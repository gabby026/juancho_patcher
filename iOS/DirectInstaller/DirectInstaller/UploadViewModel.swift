import Combine
import Foundation

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var destinationPath: String {
        didSet {
            UserDefaults.standard.set(destinationPath, forKey: Keys.destinationPath)
            if oldValue != destinationPath {
                destinationSucceeded = false
                destinationStatus = ""
            }
        }
    }

    @Published var sourcePath: String {
        didSet {
            UserDefaults.standard.set(sourcePath, forKey: Keys.sourcePath)
            if oldValue != sourcePath {
                sourceSucceeded = false
                sourceStatus = ""
            }
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var isScanning = false
    @Published private(set) var isCheckingDestination = false
    @Published private(set) var progress = 0.0
    @Published private(set) var totalFiles = 0
    @Published private(set) var processedFiles = 0
    @Published private(set) var successCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var installCompleted = false
    @Published private(set) var logLines: [String] = []
    @Published private(set) var activePatches: [PatchRecord] = []
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published private(set) var destinationStatus = ""
    @Published private(set) var destinationSucceeded = false
    @Published private(set) var sourceStatus = ""
    @Published private(set) var sourceSucceeded = false
    @Published private(set) var isOfficialBuild = true

    private var operationTask: Task<Void, Never>?

    private enum Keys {
        static let destinationPath = "destinationPath"
        static let sourcePath = "sourcePath"
    }

    init() {
        destinationPath = UserDefaults.standard.string(forKey: Keys.destinationPath)
            ?? "/var/mobile/Containers/Data/Application/98A6EB7C-2C40-4D27-B1A0-D28DBEA784E1/Documents/dragon2017/assets"
        sourcePath = UserDefaults.standard.string(forKey: Keys.sourcePath) ?? ""
        isOfficialBuild = Bundle.main.bundleIdentifier == "com.Juancho.Installer"

        Task {
            await refreshPatches()
        }
    }

    var canPatch: Bool {
        !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
            && !isScanning
            && !isCheckingDestination
            && isOfficialBuild
    }

    var progressText: String {
        guard totalFiles > 0 else { return "0 of 0 files" }
        return "\(processedFiles) of \(totalFiles) files"
    }

    var logText: String {
        logLines.joined(separator: "\n")
    }

    func refreshPatches() async {
        activePatches = await PatchManager.shared.listPatches()
    }

    func testSourcePath() async {
        guard !isScanning else { return }

        isScanning = true
        sourceStatus = ""
        defer { isScanning = false }

        do {
            let folderURL = try sourceFolderURL()
            appendLog("Scanning source folder: \(folderURL.path)")

            let files = try await Task.detached(priority: .userInitiated) {
                try FileScanner.scan(folderURL: folderURL)
            }.value

            guard !files.isEmpty else {
                throw InstallError.noSourceFiles(folderURL.path)
            }

            sourceSucceeded = true
            sourceStatus = "Scanned: \(files.count) file(s) found."
            appendLog("Source folder is readable: \(folderURL.path)")
        } catch {
            sourceSucceeded = false
            sourceStatus = error.localizedDescription
            appendLog("Source scan failed: \(error.localizedDescription)")
        }
    }

    func testDestinationPath() async {
        guard !isCheckingDestination else { return }

        isCheckingDestination = true
        destinationStatus = ""
        defer { isCheckingDestination = false }

        do {
            try await PatchManager.shared.checkDestination(destinationPath)

            destinationSucceeded = true
            destinationStatus = "Destination is accessible and writable."
            appendLog("Destination folder is ready: \(destinationPath)")
        } catch {
            destinationSucceeded = false
            destinationStatus = error.localizedDescription
            appendLog("Destination check failed: \(error.localizedDescription)")
        }
    }

    func patchSourcePath() async {
        guard operationTask == nil else { return }

        guard isOfficialBuild else {
            present(InstallError.unofficialBuild)
            return
        }

        let sourceURL: URL
        do {
            sourceURL = try sourceFolderURL()
            _ = try DirectFileInstaller(destinationPath: destinationPath)
        } catch {
            present(error)
            return
        }

        isBusy = true
        installCompleted = false
        progress = 0
        processedFiles = 0
        successCount = 0
        failedCount = 0
        logLines = []

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor in
                    self.isBusy = false
                    self.operationTask = nil
                }
            }

            do {
                self.appendLog("Preparing patch from \(sourceURL.lastPathComponent)…")

                let files = try await Task.detached(priority: .userInitiated) {
                    try FileScanner.scan(folderURL: sourceURL)
                }.value

                self.totalFiles = files.count

                guard !files.isEmpty else {
                    throw InstallError.noSourceFiles(sourceURL.path)
                }

                self.appendLog("Found \(files.count) file(s) to patch.")
                self.appendLog("Destination: \(self.destinationPath)")
                self.appendLog("Original files will be backed up before replacement.")

                let record = try await PatchManager.shared.patch(
                    files: files,
                    sourcePath: sourceURL.path,
                    destinationPath: self.destinationPath,
                    onEvent: { event in
                        await self.handle(event)
                    }
                )

                if Task.isCancelled {
                    self.appendLog("Patch cancelled.")
                    return
                }

                self.successCount = record.fileCount
                self.processedFiles = record.fileCount
                self.progress = 1
                self.installCompleted = true
                self.appendLog(
                    "Patch complete! \(record.fileCount) file(s) replaced and backed up."
                )
                self.activePatches = await PatchManager.shared.listPatches()
            } catch is CancellationError {
                self.appendLog("Patch cancelled.")
            } catch {
                self.present(error)
            }
        }
    }

    func unpatch(_ patch: PatchRecord) async {
        guard operationTask == nil else { return }

        guard isOfficialBuild else {
            present(InstallError.unofficialBuild)
            return
        }

        isBusy = true
        installCompleted = false
        progress = 0
        totalFiles = patch.fileCount
        processedFiles = 0
        successCount = 0
        failedCount = 0
        logLines = []

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor in
                    self.isBusy = false
                    self.operationTask = nil
                }
            }

            do {
                self.appendLog("Unpatching \(patch.fileCount) file(s)…")
                self.appendLog("Restoring: \(patch.destinationPath)")

                try await PatchManager.shared.unpatch(
                    patch,
                    onEvent: { event in
                        await self.handle(event)
                    }
                )

                if Task.isCancelled {
                    self.appendLog("Unpatch cancelled.")
                    return
                }

                self.successCount = patch.fileCount
                self.processedFiles = patch.fileCount
                self.progress = 1
                self.installCompleted = true
                self.appendLog(
                    "Unpatch complete! Original files have been restored."
                )
                self.activePatches = await PatchManager.shared.listPatches()
            } catch is CancellationError {
                self.appendLog("Unpatch cancelled.")
            } catch {
                self.present(error)
            }
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    private func sourceFolderURL() throws -> URL {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw InstallError.invalidSourcePath
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: trimmed,
            isDirectory: &isDirectory
        ) else {
            throw InstallError.sourceNotFound(trimmed)
        }

        guard isDirectory.boolValue else {
            throw InstallError.sourceNotDirectory(trimmed)
        }

        return URL(
            fileURLWithPath: trimmed,
            isDirectory: true
        ).resolvingSymlinksInPath()
    }

    private func handle(_ event: InstallEvent) {
        switch event {
        case .creatingDirectory(let path):
            appendLog("Creating folder: \(path)")

        case let .installing(current, total, path):
            appendLog("Installing [\(current)/\(total)]: \(path)")

        case .installed(let path):
            successCount += 1
            processedFiles += 1
            progress = totalFiles == 0
                ? 0
                : Double(processedFiles) / Double(totalFiles)
            appendLog("Installed [\(processedFiles)/\(totalFiles)]: \(path)")

        case .failed(let path, let reason):
            failedCount += 1
            processedFiles += 1
            progress = totalFiles == 0
                ? 0
                : Double(processedFiles) / Double(totalFiles)
            appendLog(
                "Failed [\(processedFiles)/\(totalFiles)]: \(path) — \(reason)"
            )
        }
    }

    private func handle(_ event: PatchEvent) {
        switch event {
        case let .backingUp(current, total, path):
            appendLog("Backing up [\(current)/\(total)]: \(path)")

        case let .replacing(current, total, path):
            appendLog("Replacing [\(current)/\(total)]: \(path)")

        case .patched(let path):
            successCount += 1
            processedFiles += 1
            progress = totalFiles == 0
                ? 0
                : Double(processedFiles) / Double(totalFiles)
            appendLog("Patched [\(processedFiles)/\(totalFiles)]: \(path)")

        case let .restoring(current, total, path):
            appendLog("Restoring [\(current)/\(total)]: \(path)")

        case .restored(let path):
            successCount += 1
            processedFiles += 1
            progress = totalFiles == 0
                ? 0
                : Double(processedFiles) / Double(totalFiles)
            appendLog("Restored [\(processedFiles)/\(totalFiles)]: \(path)")

        case let .failed(path, reason):
            failedCount += 1
            processedFiles += 1
            progress = totalFiles == 0
                ? 0
                : Double(processedFiles) / Double(totalFiles)
            appendLog(
                "Failed [\(processedFiles)/\(totalFiles)]: \(path) — \(reason)"
            )
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)

        if logLines.count > 2_000 {
            logLines.removeFirst(logLines.count - 2_000)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
        appendLog("Error: \(error.localizedDescription)")
    }
}
