import Foundation
import SwiftUI
import CryptoKit

@MainActor
final class JuanchoModel: ObservableObject {
    @Published var document: JuanchoDocument?
    @Published var importedData: Data?
    @Published var importedURL: URL?
    @Published var packageURLs: [URL] = []
    @Published var errorMessage: String?
    @Published var passwordPrompt = false
    @Published var password = ""
    @Published var status = "Ready"
    @Published var accessStatus = "Not checked"
    @Published var isBusy = false

    let patchStore = PatchStore()

    private var packagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("JuanchoPackages", isDirectory: true)
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
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
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
            importURL(destination)
            status = "Uploaded \(filename)"
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
        }
    }

    func selectStoredPackage(_ url: URL) {
        importURL(url)
    }

    func importURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let header = try JuanchoPackageCodec.readHeader(data)

            importedURL = url.standardizedFileURL
            importedData = data
            password = ""
            document = nil
            accessStatus = "Not checked"

            if header.passwordProtected {
                passwordPrompt = true
                status = "Password required for \(header.projectName)"
            } else {
                document = try JuanchoPackageCodec.decode(data)
                status = "Imported \(header.projectName) — \(document?.manifest.rules.count ?? 0) files"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlock() {
        guard let data = importedData else { return }
        do {
            document = try JuanchoPackageCodec.decode(data, password: password)
            passwordPrompt = false
            password = ""
            status = "Unlocked \(document?.manifest.rules.count ?? 0) files"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkAccess() {
        guard let doc = document else {
            accessStatus = "Import a .juancho first."
            return
        }

        do {
            let c = try FilesystemTarget.locateApplication(bundleID: doc.header.targetBundleID)
            let base = try FilesystemTarget.destinationURL(container: c, relativePath: doc.header.basePath)
            accessStatus = "Container accessible\n\(c.url.path)\nBase path: \(base.path)"
        } catch {
            accessStatus = error.localizedDescription
        }
    }

    func apply() {
        guard let doc = document, !isBusy else { return }
        isBusy = true
        do {
            status = try patchStore.apply(document: doc)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func unpatch() {
        guard let doc = document, !isBusy else { return }
        isBusy = true
        do {
            status = try patchStore.unpatch(
                projectName: doc.header.projectName,
                bundleID: doc.header.targetBundleID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func verifyInstalled() {
        guard let doc = document else { return }
        do {
            let container = try FilesystemTarget.locateApplication(bundleID: doc.header.targetBundleID)
            var mismatches: [String] = []

            for rule in doc.manifest.rules {
                let url = try FilesystemTarget.destinationURL(container: container, relativePath: rule.relativePath)
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

    private func sha256(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
