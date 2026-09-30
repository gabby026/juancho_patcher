import Foundation
import SwiftUI
import UIKit
import CryptoKit

@MainActor
final class JuanchoModel: ObservableObject {
    @Published var document: JuanchoDocument?
    @Published var importedData: Data?
    @Published var importedURL: URL?
    @Published var packageURLs: [URL] = []
    @Published var packagePath = ""
    @Published private(set) var packageHeader: JuanchoPackageHeader?
    @Published var errorMessage: String?
    @Published var passwordPrompt = false
    @Published var password = ""
    @Published var status = "Ready"
    @Published var accessStatus = "Not checked"
    @Published var isBusy = false
    @Published var destinationOverride = UserDefaults.standard.string(forKey: "juanchoDestinationOverride") ?? ""
    @Published var privateStorageToken = PatchBackupTokenStore.load()
    @Published var transientImportedPackage = false

    private var patchRequestedWhileLocked = false

    let patchStore = PatchStore()
    private let shareHandoffType = "com.juancho.juancho-package"

    private var packagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("JuanchoPackages", isDirectory: true)
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == "juancho" else { return }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        if url.host == "unpatch" {
            if let filename = items.first(where: { $0.name == "filename" })?.value,
               !filename.isEmpty {
                unpatch(sourceFileName: filename)
            } else if let project = items.first(where: { $0.name == "project" })?.value,
                      let bundle = items.first(where: { $0.name == "bundle" })?.value {
                unpatch(projectName: project, bundleID: bundle)
            } else {
                errorMessage = "No patch identifier was supplied."
            }
            return
        }

        guard url.host == "import" else { return }

        let ticket = items.first(where: { $0.name == "ticket" })?.value
        let destination = items.first(where: { $0.name == "destination" })?.value ?? ""
        let filename = items.first(where: { $0.name == "filename" })?.value ?? "skin-file.juancho"

        if let ticket, !ticket.isEmpty {
            destinationOverride = destination
            if !destination.isEmpty {
                UserDefaults.standard.set(destination, forKey: "juanchoDestinationOverride")
            }
            Task { [weak self] in
                await self?.receivePrivateHandoff(ticket: ticket, fileName: filename)
            }
            return
        }

        guard let data = UIPasteboard.general.data(forPasteboardType: shareHandoffType) else {
            errorMessage = "No package was received from the Share Sheet."
            return
        }
        receiveLegacyPasteboard(data)
    }

    private func receiveLegacyPasteboard(_ data: Data) {
        do {
            let header = try JuanchoPackageCodec.readHeader(data)
            try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)

            let safeName = header.projectName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = (safeName.isEmpty ? "JuanchoPackage" : safeName) + ".juancho"
            let destination = packagesDirectory.appendingPathComponent(filename, isDirectory: false)

            try data.write(to: destination, options: .atomic)
            loadPackages()
            packagePath = destination.path
            importURL(destination, transient: false)
            status = "Saved to Juancho — \(filename)"
        } catch {
            errorMessage = "Could not save the shared package: \(error.localizedDescription)"
        }
    }

    private func receivePrivateHandoff(ticket: String, fileName: String) async {
        do {
            var components = URLComponents(string: "https://juancho-toolkit-fresh.casipitgab69.workers.dev/api/storage/handoff-download")!
            components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue("Juancho Patcher iOS", forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            let (downloaded, response) = try await URLSession.shared.download(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw NSError(domain: "Juancho", code: code, userInfo: [
                    NSLocalizedDescriptionKey: "Private skin download failed (HTTP \(code))."
                ])
            }

            try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
            let safe = fileName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            let finalName = safe.lowercased().hasSuffix(".juancho") ? safe : safe + ".juancho"
            let destination = packagesDirectory.appendingPathComponent(finalName, isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloaded, to: destination)

            packagePath = destination.path
            importURL(destination, transient: true)
            status = "Private package downloaded — patching automatically…"
            apply()
        } catch {
            errorMessage = "Private skin download failed: \(error.localizedDescription)"
            status = "Private download failed"
        }
    }

    func loadPackages() {
        do {
            try FileManager.default.createDirectory(
                at: packagesDirectory,
                withIntermediateDirectories: true
            )

            packageURLs = try FileManager.default.contentsOfDirectory(
                at: packagesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "juancho" }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
        } catch {
            errorMessage = "Could not load uploaded packages: \(error.localizedDescription)"
        }
    }

    func uploadURL(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(
                at: packagesDirectory,
                withIntermediateDirectories: true
            )

            let filename = url.lastPathComponent
            guard filename.lowercased().hasSuffix(".juancho") else {
                throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                    NSLocalizedDescriptionKey: "Please choose a .juancho package."
                ])
            }

            let destination = packagesDirectory.appendingPathComponent(filename, isDirectory: false)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.copyItem(at: url, to: destination)
            loadPackages()
            packagePath = destination.path
            importURL(destination)
            status = "Uploaded \(filename)"
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
        }
    }

    func selectStoredPackage(_ url: URL) {
        packagePath = url.path
        importURL(url)
    }

    func loadPackageFromPath() {
        let trimmed = packagePath.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let url = try resolveJuanchoURL(from: trimmed)
            packagePath = url.path
            importURL(url)
        } catch {
            errorMessage = error.localizedDescription
            status = "Package path error"
        }
    }

    func importURL(_ url: URL, transient: Bool = false) {
        do {
            let data = try Data(contentsOf: url)
            let header = try JuanchoPackageCodec.readHeader(data)

            importedURL = url.standardizedFileURL
            transientImportedPackage = transient
            importedData = data
            packageHeader = header
            password = ""
            document = nil
            accessStatus = "Not checked"
            patchRequestedWhileLocked = false

            if header.passwordProtected {
                status = "Package loaded — password required to patch"
            } else {
                document = try JuanchoPackageCodec.decode(data)
                status = "Package ready — \(document?.manifest.rules.count ?? 0) files"
            }
        } catch {
            importedURL = nil
            importedData = nil
            packageHeader = nil
            document = nil
            patchRequestedWhileLocked = false
            errorMessage = error.localizedDescription
        }
    }

    /// Patch is the operation that unlocks a protected package.
    /// Unprotected packages patch immediately.
    func apply() {
        guard !isBusy else { return }

        if document == nil {
            guard let data = importedData else {
                errorMessage = "Load a .juancho package first."
                return
            }

            do {
                let header = try JuanchoPackageCodec.readHeader(data)
                if header.passwordProtected {
                    patchRequestedWhileLocked = true
                    password = ""
                    passwordPrompt = true
                    status = "Enter package password to patch"
                    return
                }
                document = try JuanchoPackageCodec.decode(data)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        guard let doc = document else {
            errorMessage = "The .juancho package could not be decoded."
            return
        }

        isBusy = true
        let token = privateStorageToken
        let override = destinationOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = importedURL?.lastPathComponent

        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.patchStore.apply(
                    document: doc,
                    sourceFileName: source,
                    destinationOverride: override.isEmpty ? nil : override,
                    cloudToken: token
                )
                self.status = message
                self.isBusy = false
                self.cleanupTransientPackage()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isBusy = false
            }
        }
    }

    func unlockForPatch() {
        guard patchRequestedWhileLocked else {
            errorMessage = "No patch operation is waiting for a password."
            return
        }

        guard let data = importedData else {
            errorMessage = "The package is no longer loaded."
            patchRequestedWhileLocked = false
            return
        }

        do {
            document = try JuanchoPackageCodec.decode(data, password: password)
            password = ""
            passwordPrompt = false
            patchRequestedWhileLocked = false
            status = "Password accepted — patching…"
            apply()
        } catch {
            errorMessage = error.localizedDescription
            if importedData != nil, packageHeader?.passwordProtected == true {
                passwordPrompt = true
                patchRequestedWhileLocked = true
            }
        }
    }

    func cancelPasswordPrompt() {
        passwordPrompt = false
        password = ""
        patchRequestedWhileLocked = false
    }

    func unpatch() {
        guard !isBusy else { return }
        if let doc = document {
            unpatch(projectName: doc.header.projectName, bundleID: doc.header.targetBundleID)
        } else if let filename = importedURL?.lastPathComponent {
            unpatch(sourceFileName: filename)
        } else {
            errorMessage = "Load a .juancho package or use Injects."
        }
    }

    func unpatch(sourceFileName: String) {
        isBusy = true
        let token = privateStorageToken
        Task { [weak self] in
            guard let self else { return }
            do {
                self.status = try await self.patchStore.unpatch(sourceFileName: sourceFileName, cloudToken: token)
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    func unpatch(projectName: String, bundleID: String) {
        isBusy = true
        let token = privateStorageToken
        Task { [weak self] in
            guard let self else { return }
            do {
                self.status = try await self.patchStore.unpatch(projectName: projectName, bundleID: bundleID, cloudToken: token)
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    func setDestinationOverride(_ value: String) {
        destinationOverride = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(destinationOverride, forKey: "juanchoDestinationOverride")
    }

    func setPrivateStorageToken(_ value: String) {
        privateStorageToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try? PatchBackupTokenStore.save(privateStorageToken)
    }

    private func cleanupTransientPackage() {
        guard transientImportedPackage, let url = importedURL else { return }
        try? FileManager.default.removeItem(at: url)
        transientImportedPackage = false
        importedURL = nil
        importedData = nil
        document = nil
    }

    func verifyInstalled() {
        guard let doc = document else {
            errorMessage = packageHeader?.passwordProtected == true
                ? "Enter the package password by pressing Patch first."
                : "Load a .juancho package first."
            return
        }

        do {
            let container = try FilesystemTarget.locateApplication(
                bundleID: doc.header.targetBundleID
            )
            var mismatches: [String] = []

            for rule in doc.manifest.rules {
                let url = try FilesystemTarget.destinationURL(
                    container: container,
                    relativePath: rule.relativePath,
                    packageBasePath: doc.header.basePath,
                    destinationOverride: destinationOverride.isEmpty ? nil : destinationOverride
                )

                guard FileManager.default.fileExists(atPath: url.path) else {
                    mismatches.append("Missing: \(rule.relativePath)")
                    continue
                }

                let data = try Data(contentsOf: url)
                if sha256(data) != rule.sha256 {
                    mismatches.append("Changed: \(rule.relativePath)")
                }
            }

            status = mismatches.isEmpty
                ? "All \(doc.manifest.rules.count) installed files match."
                : "\(mismatches.count) installed files do not match."

            if !mismatches.isEmpty {
                errorMessage = mismatches.prefix(5).joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkAccess() {
        guard let doc = document else {
            accessStatus = packageHeader?.passwordProtected == true
                ? "Package is password protected. Press Patch and enter the password first."
                : "Load a .juancho package first."
            return
        }

        do {
            let c = try FilesystemTarget.locateApplication(
                bundleID: doc.header.targetBundleID
            )
            let base = try FilesystemTarget.destinationURL(
                container: c,
                relativePath: doc.header.basePath,
                packageBasePath: "",
                destinationOverride: destinationOverride.isEmpty ? nil : destinationOverride
            )
            accessStatus = "Container accessible\n\(c.url.path)\nBase path: \(base.path)"
        } catch {
            accessStatus = error.localizedDescription
        }
    }

    private func resolveJuanchoURL(from path: String) throws -> URL {
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw NSError(
                domain: "Juancho",
                code: 200,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Enter an absolute path beginning with /."
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
                        "Path does not exist: \(input.path)"
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
                        "No .juancho package was found in: \(input.path)"
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

    private func sha256(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
