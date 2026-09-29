import Combine
import CryptoKit
import Foundation

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var sourcePath: String {
        didSet {
            UserDefaults.standard.set(sourcePath, forKey: Keys.sourcePath)
            if oldValue != sourcePath {
                resetLoadedState()
            }
        }
    }

    @Published private(set) var activePatches: [PatchRecord] = []
    @Published private(set) var document: JuanchoDocument?
    @Published private(set) var isBusy = false
    @Published private(set) var operationTitle = ""
    @Published private(set) var currentFile = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var processedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var passwordPrompt = false
    @Published var password = ""
    @Published var passwordError = ""
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

    var canInject: Bool {
        !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
            && isOfficialBuild
    }

    func inject() {
        guard operationTask == nil, !isBusy else { return }

        guard isOfficialBuild else {
            present(
                NSError(
                    domain: "Juancho",
                    code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "This is not an official Juancho Installer build."
                    ]
                )
            )
            return
        }

        let requestedPath = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPath.isEmpty else { return }

        beginOperation(title: "Injecting")

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isBusy = false
                self.operationTask = nil
                self.currentFile = ""
                self.refreshPatches()
            }

            do {
                self.currentFile = "Preparing source…"

                let input = try await Task.detached(priority: .userInitiated) {
                    try SourceResolver.resolve(path: requestedPath)
                }.value

                let document: JuanchoDocument

                switch input {
                case .folder(let folderURL):
                    self.currentFile = "Reading \(folderURL.lastPathComponent)…"

                    document = try await Task.detached(priority: .userInitiated) {
                        try PlainFolderBuilder.document(folderURL: folderURL)
                    }.value

                case .package(let packageURL):
                    self.currentFile = "Reading \(packageURL.lastPathComponent)…"

                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: packageURL, options: [.mappedIfSafe])
                    }.value

                    self.importedURL = packageURL
                    self.importedData = data
                    self.password = ""
                    self.passwordError = ""
                    self.waitingForPassword = false

                    if LegacyJuanchoCodec.isLegacy7z(data) {
                        do {
                            document = try await Task.detached(priority: .userInitiated) {
                                try LegacyJuanchoCodec.decode(packageURL: packageURL)
                            }.value
                        } catch let error as LegacyJuanchoError {
                            guard case .passwordRequired = error else {
                                throw error
                            }

                            self.waitingForPassword = true
                            self.passwordPrompt = true
                            self.isBusy = false
                            return
                        }
                    } else {
                        let header = try JuanchoPackageCodec.readHeader(data)

                        if header.passwordProtected {
                            self.waitingForPassword = true
                            self.passwordPrompt = true
                            self.isBusy = false
                            return
                        }

                        document = try await Task.detached(priority: .userInitiated) {
                            try JuanchoPackageCodec.decode(data)
                        }.value
                    }
                }

                self.document = document
                try await performPatch(document)
            } catch is CancellationError {
                return
            } catch {
                self.present(error)
            }
        }
    }

    func unlockAndInject() {
        guard waitingForPassword,
              let url = importedURL,
              let data = importedData
        else {
            passwordPrompt = false
            waitingForPassword = false
            return
        }

        let suppliedPassword = password
        passwordError = ""
        passwordPrompt = false
        beginOperation(title: "Injecting")

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isBusy = false
                self.operationTask = nil
                self.currentFile = ""
                self.refreshPatches()
            }

            let document: JuanchoDocument

            do {
                self.currentFile = "Unlocking package…"

                if LegacyJuanchoCodec.isLegacy7z(data) {
                    document = try await Task.detached(priority: .userInitiated) {
                        try LegacyJuanchoCodec.decode(
                            packageURL: url,
                            password: suppliedPassword
                        )
                    }.value
                } else {
                    document = try await Task.detached(priority: .userInitiated) {
                        try JuanchoPackageCodec.decode(
                            data,
                            password: suppliedPassword
                        )
                    }.value
                }
            } catch {
                self.passwordError = error.localizedDescription
                self.waitingForPassword = true
                self.passwordPrompt = true
                return
            }

            self.waitingForPassword = false
            self.password = ""
            self.document = document

            do {
                try await performPatch(document)
            } catch is CancellationError {
                return
            } catch {
                self.present(error)
            }
        }
    }

    func cancelPasswordPrompt() {
        waitingForPassword = false
        passwordPrompt = false
        password = ""
        passwordError = ""
        importedData = nil
        importedURL = nil
    }

    func unpatch(_ patch: PatchRecord) {
        guard operationTask == nil, !isBusy else { return }

        guard isOfficialBuild else {
            present(
                NSError(
                    domain: "Juancho",
                    code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "This is not an official Juancho Installer build."
                    ]
                )
            )
            return
        }

        beginOperation(title: "Unpatching")
        totalFiles = patch.entries.count
        currentFile = "Checking \(patch.packageName)…"

        operationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isBusy = false
                self.operationTask = nil
                self.currentFile = ""
                self.refreshPatches()
            }

            do {
                _ = try await self.patchStore.unpatch(
                    projectName: patch.packageName,
                    bundleID: patch.bundleID,
                    onProgress: { processed, total, path in
                        self.processedFiles = processed
                        self.totalFiles = total
                        self.progress = total == 0 ? 1 : Double(processed) / Double(total)
                        self.currentFile = path
                    }
                )

                self.progress = 1
                self.processedFiles = self.totalFiles
                self.currentFile = "Done"
            } catch is CancellationError {
                return
            } catch {
                self.present(error)
            }
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    private func performPatch(_ document: JuanchoDocument) async throws {
        beginOperation(title: "Injecting")
        totalFiles = document.manifest.rules.count
        currentFile = totalFiles == 0
            ? "No files"
            : "Preparing \(totalFiles) files…"

        _ = try await patchStore.apply(
            document: document,
            onProgress: { processed, total, path in
                self.processedFiles = processed
                self.totalFiles = total
                self.progress = total == 0 ? 1 : Double(processed) / Double(total)
                self.currentFile = path
            }
        )

        progress = 1
        processedFiles = totalFiles
        currentFile = "Done"
    }

    private func beginOperation(title: String) {
        isBusy = true
        operationTitle = title
        currentFile = ""
        progress = 0
        processedFiles = 0
        totalFiles = 0
    }

    private func refreshPatches() {
        activePatches = patchStore.activeRecords.values.sorted {
            $0.appliedAt > $1.appliedAt
        }
    }

    private func resetLoadedState() {
        document = nil
        importedData = nil
        importedURL = nil
        passwordPrompt = false
        password = ""
        passwordError = ""
        waitingForPassword = false
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }

}

private enum SourceInput: Sendable {
    case package(URL)
    case folder(URL)
}

private enum SourceResolver {
    static func resolve(path: String) throws -> SourceInput {
        guard path.hasPrefix("/") else {
            throw NSError(
                domain: "Juancho",
                code: 200,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Enter an absolute source path."
                ]
            )
        }

        let input = URL(fileURLWithPath: path).standardizedFileURL
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
                        "Source path does not exist."
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
                            "Select a .juancho file or a source folder."
                    ]
                )
            }

            return .package(input)
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

        if candidates.count == 1, let only = candidates.first {
            return .package(only)
        }

        if candidates.count > 1 {
            throw NSError(
                domain: "Juancho",
                code: 204,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "More than one .juancho package was found in the selected folder."
                ]
            )
        }

        return .folder(input)
    }
}

private enum PlainFolderBuilder {
    static let defaultBundleID = LegacyJuanchoCodec.defaultBundleID
    static let defaultBasePath = LegacyJuanchoCodec.defaultBasePath

    static func document(folderURL: URL) throws -> JuanchoDocument {
        let sourceRoot = folderURL.resolvingSymlinksInPath().standardizedFileURL
        let sourcePath = sourceRoot.path
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"

        var files: [JuanchoFile] = []
        var rules: [JuanchoRule] = []

        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(
                domain: "Juancho",
                code: 205,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to read the source folder."
                ]
            )
        }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )

            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }

            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(prefix) else {
                continue
            }

            let relative = String(resolved.path.dropFirst(prefix.count))
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            guard !relative.isEmpty,
                  !relative.split(separator: "/").contains(".."),
                  !relative.contains(":") else {
                throw NSError(
                    domain: "Juancho",
                    code: 206,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unsafe source file path: \(relative)"
                    ]
                )
            }

            let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
            let destination = defaultBasePath + "/" + relative
            let filename = URL(fileURLWithPath: relative).lastPathComponent

            files.append(
                JuanchoFile(
                    path: relative,
                    data: data
                )
            )

            rules.append(
                JuanchoRule(
                    operation: "replace",
                    containerKind: "application",
                    bundleID: defaultBundleID,
                    relativePath: destination,
                    replacementFilename: filename,
                    size: data.count,
                    sha256: sha256(data),
                    canRemove: true
                )
            )
        }

        guard !files.isEmpty else {
            throw NSError(
                domain: "Juancho",
                code: 207,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The source folder contains no files."
                ]
            )
        }

        let name = sourceRoot.lastPathComponent.isEmpty
            ? "Folder Patch"
            : sourceRoot.lastPathComponent

        let header = JuanchoPackageHeader(
            formatVersion: 0,
            projectName: name,
            targetBundleID: defaultBundleID,
            basePath: defaultBasePath,
            passwordProtected: false,
            compression: "folder",
            payloadEncoding: "filesystem",
            payloadUncompressedSize: 0,
            payloadCompressedSize: 0,
            payloadSHA256: "",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            kdf: nil,
            kdfIterations: nil,
            salt: nil,
            nonce: nil,
            aad: nil
        )

        let manifest = JuanchoManifest(
            formatVersion: 0,
            projectName: name,
            bundleIdentifiers: [defaultBundleID],
            directories: [],
            rules: rules
        )

        return JuanchoDocument(
            header: header,
            manifest: manifest,
            files: files
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
