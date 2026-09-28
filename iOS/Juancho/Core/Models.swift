import Foundation

struct JuanchoHeader: Codable {
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

struct JuanchoRule: Codable, Identifiable {
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

struct JuanchoManifest: Codable {
    let formatVersion: Int
    let projectName: String
    let bundleIdentifiers: [String]
    let directories: [String]
    let rules: [JuanchoRule]
}

struct JuanchoFile {
    let path: String
    let data: Data
}

struct JuanchoDocument {
    let header: JuanchoHeader
    let manifest: JuanchoManifest
    let files: [JuanchoFile]
}
