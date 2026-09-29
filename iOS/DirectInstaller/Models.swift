import Foundation

struct JuanchoPackageHeader: Codable, Sendable {
    let formatVersion: Int
    let projectName: String
    let targetBundleID: String
    let basePath: String
    let passwordProtected: Bool
    let compression: String
    let payloadEncoding: String
    let payloadUncompressedSize: Int
    let payloadCompressedSize: Int
    let payloadSHA256: String
    let createdAt: String
    let kdf: String?
    let kdfIterations: Int?
    let salt: String?
    let nonce: String?
    let aad: String?
}

struct JuanchoRule: Codable, Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    let operation: String
    let containerKind: String
    let bundleID: String
    let relativePath: String
    let replacementFilename: String
    let size: Int
    let sha256: String
    let canRemove: Bool
}

struct JuanchoManifest: Codable, Sendable {
    let formatVersion: Int
    let projectName: String
    let bundleIdentifiers: [String]
    let directories: [String]
    let rules: [JuanchoRule]
}

struct JuanchoFile: Hashable, Sendable {
    let path: String
    let data: Data
}

struct JuanchoDocument: Sendable {
    let header: JuanchoPackageHeader
    let manifest: JuanchoManifest
    let files: [JuanchoFile]
}

struct PatchRecord: Codable, Sendable {
    var id: String { "(packageName)|(bundleID)" }

    var packageName: String
    var bundleID: String
    var appliedAt: Date
    var entries: [Entry]

    struct Entry: Codable, Sendable {
        var destination: String
        var backupPath: String?
        var addedByPatch: Bool
        var expectedSHA256: String
        var sourcePath: String?

        enum CodingKeys: String, CodingKey {
            case destination
            case backupPath
            case addedByPatch
            case expectedSHA256
            case sourcePath
        }

        init(
            destination: String,
            backupPath: String?,
            addedByPatch: Bool,
            expectedSHA256: String,
            sourcePath: String? = nil
        ) {
            self.destination = destination
            self.backupPath = backupPath
            self.addedByPatch = addedByPatch
            self.expectedSHA256 = expectedSHA256
            self.sourcePath = sourcePath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            destination = try container.decode(String.self, forKey: .destination)
            backupPath = try container.decodeIfPresent(String.self, forKey: .backupPath)
            addedByPatch = try container.decode(Bool.self, forKey: .addedByPatch)
            expectedSHA256 = try container.decode(String.self, forKey: .expectedSHA256)
            sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        }
    }
}
