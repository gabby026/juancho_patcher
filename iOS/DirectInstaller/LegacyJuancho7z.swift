import Foundation
import CryptoKit
import PLzmaSDK

enum LegacyJuanchoError: Error, LocalizedError {
    case notA7z
    case passwordRequired
    case unsafeEntry(String)
    case noFiles
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notA7z:
            return "The selected .juancho is not a supported JUANCHO or 7-Zip package."
        case .passwordRequired:
            return "This 7-Zip .juancho package requires a password."
        case .unsafeEntry(let path):
            return "Unsafe archive path: \(path)"
        case .noFiles:
            return "The .juancho archive contains no regular files."
        case .extractionFailed(let reason):
            return "Could not extract the 7-Zip .juancho package: \(reason)"
        }
    }
}

enum LegacyJuanchoCodec {
    static let magic = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])
    static let defaultBundleID = "com.mobile.legends"
    static let defaultBasePath = "Documents/dragon2017/assets"

    static func isLegacy7z(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    static func syntheticHeader(
        packageURL: URL,
        passwordProtected: Bool
    ) -> JuanchoPackageHeader {
        let name = packageURL.deletingPathExtension().lastPathComponent
        let safeName = name.isEmpty ? "Juancho 7-Zip Package" : name

        return JuanchoPackageHeader(
            formatVersion: 0,
            projectName: safeName,
            targetBundleID: defaultBundleID,
            basePath: defaultBasePath,
            passwordProtected: passwordProtected,
            compression: "7z/LZMA2",
            payloadEncoding: "legacy-7z",
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
    }

    static func decode(
        packageURL: URL,
        password: String? = nil
    ) throws -> JuanchoDocument {
        let marker = try Data(contentsOf: packageURL, options: [.mappedIfSafe])
        guard isLegacy7z(marker) else {
            throw LegacyJuanchoError.notA7z
        }

        let archivePath = try Path(packageURL.path)
        let input = try InStream(path: archivePath)
        let decoder = try Decoder(
            stream: input,
            fileType: .sevenZ,
            delegate: nil
        )

        try decoder.setPassword(password)

        do {
            guard try decoder.open() else {
                throw LegacyJuanchoError.extractionFailed(
                    "7-Zip decoder could not open the archive."
                )
            }
        } catch {
            if password == nil || password?.isEmpty == true {
                throw LegacyJuanchoError.passwordRequired
            }
            throw error
        }

        let count = try decoder.count()
        guard count > 0 else {
            throw LegacyJuanchoError.noFiles
        }

        var entryPaths: [String] = []
        entryPaths.reserveCapacity(Int(count))

        for index in 0..<count {
            let item = try decoder.item(at: index)
            let rawPath = try item.path().description
            let normalized = normalizeArchivePath(rawPath)

            guard !normalized.isEmpty,
                  !normalized.hasPrefix("/"),
                  !normalized.split(separator: "/").contains(".."),
                  !normalized.contains(":") else {
                throw LegacyJuanchoError.unsafeEntry(rawPath)
            }

            guard !item.isDir else {
                continue
            }

            entryPaths.append(normalized)
        }

        guard !entryPaths.isEmpty else {
            throw LegacyJuanchoError.noFiles
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Juancho7z-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        do {
            guard try decoder.extract(
                to: Path(temporaryRoot.path),
                itemsFullPath: true
            ) else {
                throw LegacyJuanchoError.extractionFailed(
                    "The 7-Zip decoder reported an unsuccessful extraction."
                )
            }
        } catch let error as LegacyJuanchoError {
            throw error
        } catch {
            throw LegacyJuanchoError.extractionFailed(
                error.localizedDescription
            )
        }

        var files: [JuanchoFile] = []
        var rules: [JuanchoRule] = []
        var seenDestinations = Set<String>()

        for archivePath in entryPaths {
            let extracted = temporaryRoot
                .appendingPathComponent(
                    archivePath,
                    isDirectory: false
                )
                .standardizedFileURL

            guard extracted.path.hasPrefix(
                temporaryRoot.standardizedFileURL.path + "/"
            ) else {
                throw LegacyJuanchoError.unsafeEntry(archivePath)
            }

            guard FileManager.default.fileExists(atPath: extracted.path) else {
                continue
            }

            let data = try Data(contentsOf: extracted, options: [.mappedIfSafe])
            let destination = destinationPath(forArchivePath: archivePath)

            guard seenDestinations.insert(destination).inserted else {
                throw LegacyJuanchoError.extractionFailed(
                    "Duplicate destination generated for \(destination)."
                )
            }

            let filename = URL(fileURLWithPath: destination).lastPathComponent

            files.append(
                JuanchoFile(
                    path: destination.replacingOccurrences(
                        of: "\\",
                        with: "/"
                    ),
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
            throw LegacyJuanchoError.noFiles
        }

        let header = syntheticHeader(
            packageURL: packageURL,
            passwordProtected: !(password ?? "").isEmpty
        )

        let manifest = JuanchoManifest(
            formatVersion: 0,
            projectName: header.projectName,
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

    private static func destinationPath(forArchivePath path: String) -> String {
        var normalized = normalizeArchivePath(path)

        let lower = normalized.lowercased()
        let knownRoots = [
            "documents/dragon2017/assets/",
            "dragon2017/assets/",
            "assets/"
        ]

        for root in knownRoots {
            if lower.hasPrefix(root) {
                let offset = root.count
                normalized = String(normalized.dropFirst(offset))
                return defaultBasePath + "/" + normalized
            }
        }

        if let slash = normalized.firstIndex(of: "/") {
            let first = String(normalized[..<slash]).lowercased()
            let knownWrappers = Set([
                "documents",
                "dragon2017",
                "assets"
            ])

            if knownWrappers.contains(first) {
                return defaultBasePath + "/" + normalized
                    .replacingOccurrences(
                        of: "documents/dragon2017/assets/",
                        with: "",
                        options: [.caseInsensitive]
                    )
                    .replacingOccurrences(
                        of: "dragon2017/assets/",
                        with: "",
                        options: [.caseInsensitive]
                    )
                    .replacingOccurrences(
                        of: "assets/",
                        with: "",
                        options: [.caseInsensitive]
                    )
            }
        }

        // JuanchoTool historically compresses a selected file/folder directly.
        // For MLBB legacy packages, treat each archive item as relative to the
        // application's Documents/dragon2017/assets directory.
        return defaultBasePath + "/" + normalized
    }

    private static func normalizeArchivePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
