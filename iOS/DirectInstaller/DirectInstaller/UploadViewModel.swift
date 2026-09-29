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
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published private(set) var destinationStatus = ""
    @Published private(set) var destinationSucceeded = false
    @Published private(set) var sourceStatus = ""
    @Published private(set) var sourceSucceeded = false
    @Published private(set) var isOfficialBuild = true

    private var installTask: Task<Void, Never>?

    private enum Keys {
        static let destinationPath = "destinationPath"
        static let sourcePath = "sourcePath"
    }

    init() {
        destinationPath = UserDefaults.standard.string(forKey: Keys.destinationPath)
            ?? "/var/mobile/Containers/Data/Application/98A6EB7C-2C40-4D27-B1A0-D28DBEA784E1/Documents/dragon2017/assets"
        sourcePath = UserDefaults.standard.string(forKey: Keys.sourcePath) ?? ""
        isOfficialBuild = Bundle.main.bundleIdentifier == "com.Juancho.Installer"
    }

    var canInstall: Bool {
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
            let installer = try DirectFileInstaller(destinationPath: destinationPath)
            _ = installer

            destinationSucceeded = true
            destinationStatus = "Destination is accessible."
            appendLog("Destination folder is ready: \(destinationPath)")
        } catch {
            destinationSucceeded = false
            destinationStatus = error.localizedDescription
            appendLog("Destination check failed: \(error.localizedDescription)")
        }
    }

    func installSourcePath() async {
        guard installTask == nil else { return }

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

        installTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor in
                    self.isBusy = false
                    self.installTask = nil
                }
            }

            do {
                self.appendLog("Scanning \(sourceURL.lastPathComponent)…")

                let files = try await Task.detached(priority: .userInitiated) {
                    try FileScanner.scan(folderURL: sourceURL)
                }.value

                self.totalFiles = files.count

                guard !files.isEmpty else {
                    throw InstallError.noSourceFiles(sourceURL.path)
                }

                self.appendLog("Found \(files.count) file(s) to install.")
                self.appendLog("Destination: \(self.destinationPath)")
                self.appendLog("Using direct filesystem installation — no WebDAV.")

                let installer = try DirectFileInstaller(
                    destinationPath: self.destinationPath
                )

                let result = await installer.install(
                    files: files,
                    onEvent: { event in
                        await self.handle(event)
                    }
                )

                if Task.isCancelled {
                    self.appendLog("Installation cancelled.")
                    return
                }

                self.successCount = result.succeeded
                self.failedCount = result.failed
                self.processedFiles = result.succeeded + result.failed
                self.progress = self.totalFiles == 0
                    ? 0
                    : Double(self.processedFiles) / Double(self.totalFiles)

                self.installCompleted = result.failed == 0
                self.appendLog(
                    "Done! \(result.succeeded) installed, \(result.failed) failed."
                )
            } catch is CancellationError {
                self.appendLog("Installation cancelled.")
            } catch {
                self.present(error)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
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
