import Combine
import Foundation

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var sourcePath: String {
        didSet {
            UserDefaults.standard.set(sourcePath, forKey: Keys.sourcePath)
            if oldValue != sourcePath {
                clearLoadedPackage()
            }
        }
    }

    @Published private(set) var packageHeader: JuanchoPackageHeader?
    @Published private(set) var document: JuanchoDocument?
    @Published private(set) var activePatches: [PatchRecord] = []
    @Published private(set) var targetStatus: String?
    @Published private(set) var targetReady = false
    @Published private(set) var isBusy = false
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var passwordPrompt = false
    @Published var password = ""
    @Published var passwordError = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isOfficialBuild = true

    private let patchStore = PatchStore()
    private var importedData: Data?
    private var importedURL: URL?
    private var waitingForPassword = false
    private var operationTask: Task<Void, Never>?

    private enum Keys {
        static let sourcePath = "sourcePath"
    }

    init() {
        sourcePath = UserDefaults.standard.string(forKey: Keys.sourcePath) ?? ""
        isOfficialBuild = Bundle.main.bundleIdentifier == "com.Juancho.Installer"
        refreshPatches()
    }

    var canPatch: Bool {
        !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
            && isOfficialBuild
    }

    func loadPackage() {
        do {
            let url = try resolveJuanchoURL()
            let data = try Data(contentsOf: url)
            let header = try JuanchoPackageCodec.readHeader(data)

            importedData = data
            importedURL = url
            packageHeader = header
            password = ""
            passwordError = ""
            waitingForPassword = false
            targetReady = false
            targetStatus = nil
            appendLog("Read package: (url.path)")
            appendLog("Project: (header.projectName)")
            appendLog("Bundle ID: (header.targetBundleID)")
            appendLog("Base path: \(header.basePath.isEmpty ? "/" : header.basePath)")

            if header.passwordProtected {
                document = nil
                appendLog("Package is password protected. Password will be requested only when Patch Files is pressed.")
            } else {
                document = try JuanchoPackageCodec.decode(data)
                appendLog("Package decoded: (document?.manifest.rules.count ?? 0) replacement file(s).")
            }

            checkTarget()
        } catch {
            clearLoadedPackage()
            present(error)
        }
    }

    func patchFiles() {
        guard !isBusy else { return }

        guard isOfficialBuild else {
            present(NSError(domain: "Juancho", code: 403, userInfo: [NSLocalizedDescriptionKey: "This is not an official Juancho Installer build."]))
            return
        }

        do {
            if packageHeader == nil || importedData == nil || importedURL == nil {
                try readPackageForPatch()
            }

            guard let header = packageHeader,
                  let data = importedData else {
                throw JuanchoPackageError.malformedHeader
            }

            if document == nil {
                if header.passwordProtected {
                    waitingForPassword = true
                    password = ""
                    passwordError = ""
                    passwordPrompt = true
                    appendLog("Password required. Waiting for input…")
                    return
                }

                document = try JuanchoPackageCodec.decode(data)
            }

            guard let document else {
                throw JuanchoPackageError.malformedPayload
            }

            beginPatch(document)
        } catch {
            present(error)
        }
    }

    func unlockAndPatch() {
        guard waitingForPassword else {
            passwordPrompt = false
            return
        }

        guard let data = importedData,
              let header = packageHeader,
              header.passwordProtected else {
            passwordError = "The package is no longer loaded."
            waitingForPassword = false
            passwordPrompt = false
            return
        }

        do {
            document = try JuanchoPackageCodec.decode(
                data,
                password: password
            )

            waitingForPassword = false
            passwordPrompt = false
            passwordError = ""
            appendLog("Password accepted. Starting patch…")

            guard let document else {
                throw JuanchoPackageError.malformedPayload
            }

            beginPatch(document)
        } catch {
            passwordError = error.localizedDescription
            waitingForPassword = true
            passwordPrompt = true
            appendLog("Password rejected: (error.localizedDescription)")
        }
    }

    func cancelPasswordPrompt() {
        waitingForPassword = false
        passwordPrompt = false
        password = ""
        passwordError = ""
        appendLog("Patch cancelled at password prompt.")
    }

    func unpatch(_ patch: PatchRecord) async {
        guard operationTask == nil else { return }

        guard isOfficialBuild else {
            present(InstallError.unofficialBuild)
            return
        }

        isBusy = true
        logLines = []
        appendLog("Unpatching (patch.packageName)…")

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isBusy = false
                self.operationTask = nil
                self.refreshPatches()
            }

            do {
                let message = try self.patchStore.unpatch(
                    projectName: patch.packageName,
                    bundleID: patch.bundleID
                )

                self.appendLog(message)
            } catch {
                self.present(error)
            }
        }

        await operationTask?.value
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    private func beginPatch(_ document: JuanchoDocument) {
        guard operationTask == nil else { return }

        isBusy = true
        logLines = []
        appendLog("Patching (document.header.projectName)…")
        appendLog("Target Bundle ID: (document.header.targetBundleID)")
        appendLog("Manifest: (document.manifest.rules.count) replacement file(s)")
        appendLog("Existing files will be backed up before replacement.")

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isBusy = false
                self.operationTask = nil
                self.refreshPatches()
            }

            do {
                let message = try self.patchStore.apply(document: document)
                self.appendLog(message)
                self.appendLog("Patch completed successfully. Backups are saved for Unpatch.")
            } catch {
                self.present(error)
            }
        }
    }

    private func readPackageForPatch() throws {
        let url = try resolveJuanchoURL()
        let data = try Data(contentsOf: url)
        let header = try JuanchoPackageCodec.readHeader(data)

        importedData = data
        importedURL = url
        packageHeader = header
        packageHeader.map { _ in () }
        password = ""
        passwordError = ""
        document = nil

        appendLog("Patch requested. Reading package: (url.path)")
        appendLog("Package: (header.projectName)")
        appendLog("Bundle ID: (header.targetBundleID)")
        appendLog("Password: \(header.passwordProtected ? "required" : "none")")

        if !header.passwordProtected {
            document = try JuanchoPackageCodec.decode(data)
        }

        checkTarget()
    }

    private func checkTarget() {
        guard let header = packageHeader else {
            targetStatus = nil
            targetReady = false
            return
        }

        do {
            let container = try FilesystemTarget.locateApplication(
                bundleID: header.targetBundleID
            )

            let base = try FilesystemTarget.destinationURL(
                container: container,
                relativePath: header.basePath
            )

            targetReady = true
            targetStatus = "Target found. Base path: (base.path)"
            appendLog("Target application found: (container.url.path)")
        } catch {
            targetReady = false
            targetStatus = error.localizedDescription
            appendLog("Target check: (error.localizedDescription)")
        }
    }

    private func refreshPatches() {
        activePatches = patchStore.activeRecords.values.sorted {
            $0.appliedAt > $1.appliedAt
        }
    }

    private func resolveJuanchoURL() throws -> URL {
        let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            throw NSError(
                domain: "Juancho",
                code: 200,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Enter an absolute path beginning with /."
                ]
            )
        }

        let input = URL(fileURLWithPath: trimmed).standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: input.path,
            isDirectory: &isDirectory
        ) else {
            throw NSError(
                domain: "Juancho",
                code: 201,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Path does not exist: (input.path)"
                ]
            )
        }

        if !isDirectory.boolValue {
            guard input.pathExtension.lowercased() == "juancho" else {
                throw NSError(
                    domain: "Juancho",
                    code: 202,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Selected file is not a .juancho package."
                    ]
                )
            }

            return input
        }

        let candidates = try FileManager.default.contentsOfDirectory(
            at: input,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension.lowercased() == "juancho" else {
                return false
            }

            return (try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true
        }
        .sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare(
                $1.lastPathComponent
            ) == .orderedAscending
        }

        guard !candidates.isEmpty else {
            throw NSError(
                domain: "Juancho",
                code: 203,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No .juancho package was found in: (input.path)"
                ]
            )
        }

        guard candidates.count == 1, let only = candidates.first else {
            let names = candidates.prefix(8)
                .map(\.lastPathComponent)
                .joined(separator: "\n")

            throw NSError(
                domain: "Juancho",
                code: 204,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Multiple .juancho packages were found. Enter the exact package path.\n\n\(names)"
                ]
            )
        }

        return only
    }

    private func clearLoadedPackage() {
        packageHeader = nil
        document = nil
        importedData = nil
        importedURL = nil
        targetStatus = nil
        targetReady = false
        passwordPrompt = false
        password = ""
        passwordError = ""
        waitingForPassword = false
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
        appendLog("Error: (error.localizedDescription)")
    }
}
