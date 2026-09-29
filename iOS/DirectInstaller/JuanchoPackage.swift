import Foundation
import CryptoKit

enum JuanchoPackageError: Error, LocalizedError {
    case badMagic, unsupportedVersion, malformedHeader, malformedPayload
    case unsafePath, duplicateDestination, hashMismatch, archiveMismatch
    case passwordRequired, encryptedFlagMismatch

    var errorDescription: String? {
        switch self {
        case .badMagic: return "Not a JUANCHO package."
        case .unsupportedVersion: return "Unsupported JUANCHO package version."
        case .malformedHeader: return "Malformed package header."
        case .malformedPayload: return "Malformed package payload."
        case .unsafePath: return "Unsafe or absolute path in manifest."
        case .duplicateDestination: return "Duplicate destination in manifest."
        case .hashMismatch: return "A replacement file hash does not match its manifest entry."
        case .archiveMismatch: return "The archive does not match the manifest."
        case .passwordRequired: return "This package requires a password."
        case .encryptedFlagMismatch: return "Package encryption flag and metadata disagree."
        }
    }
}

enum JuanchoPackageCodec {
    static let magic = Data("JUANCHO1".utf8)
    static let maxPayloadBytes = 1_500_000_000

    static func readHeader(_ data: Data) throws -> JuanchoPackageHeader {
        guard data.count > 14, data.prefix(8) == magic else { throw JuanchoPackageError.badMagic }
        guard data[8] == 1 else { throw JuanchoPackageError.unsupportedVersion }
        let headerLength = Int(readUInt32LE(data, 10))
        let start = 14
        let end = start + headerLength
        guard headerLength > 0, end <= data.count, headerLength <= 1_000_000 else {
            throw JuanchoPackageError.malformedHeader
        }
        return try JSONDecoder().decode(JuanchoPackageHeader.self, from: data.subdata(in: start..<end))
    }

    static func decode(_ data: Data, password: String? = nil) throws -> JuanchoDocument {
        let header = try readHeader(data)
        let encryptedFlag = data[9] & 1 != 0
        guard encryptedFlag == header.passwordProtected else {
            throw JuanchoPackageError.encryptedFlagMismatch
        }

        let headerLength = Int(readUInt32LE(data, 10))
        let payloadStart = 14 + headerLength
        guard payloadStart <= data.count else { throw JuanchoPackageError.malformedHeader }

        var payload = Data(data[payloadStart..<data.count])
        guard payload.count <= maxPayloadBytes else { throw JuanchoPackageError.malformedPayload }

        if encryptedFlag {
            guard let password, !password.isEmpty else { throw JuanchoPackageError.passwordRequired }
            guard let saltB64 = header.salt,
                  let nonceB64 = header.nonce,
                  let iterations = header.kdfIterations,
                  let salt = Data(base64Encoded: saltB64),
                  let nonce = Data(base64Encoded: nonceB64),
                  iterations >= 1 else {
                throw JuanchoCryptoError.missingCryptoMetadata
            }

            let aadString = "JUANCHO1/v1/\(header.projectName)"
            payload = try JuanchoCrypto.open(
                ciphertext: payload,
                password: password,
                salt: salt,
                nonce: nonce,
                aad: Data(aadString.utf8),
                iterations: iterations
            )
        }

        let digest = sha256(payload)
        guard digest.caseInsensitiveCompare(header.payloadSHA256) == .orderedSame else {
            throw JuanchoPackageError.malformedPayload
        }

        guard header.payloadUncompressedSize > 0,
              header.payloadUncompressedSize <= maxPayloadBytes else {
            throw JuanchoPackageError.malformedPayload
        }

        let plain = try ZlibHelper.decompress(payload, expectedSize: header.payloadUncompressedSize)
        guard plain.count == header.payloadUncompressedSize, plain.count >= 4 else {
            throw JuanchoPackageError.malformedPayload
        }

        let manifestLength = Int(readUInt32LE(plain, 0))
        guard manifestLength > 0, 4 + manifestLength <= plain.count else {
            throw JuanchoPackageError.malformedPayload
        }

        let manifestData = plain.subdata(in: 4..<(4 + manifestLength))
        let manifest = try JSONDecoder().decode(JuanchoManifest.self, from: manifestData)
        try validate(manifest, header: header)

        let archiveData = plain.subdata(in: (4 + manifestLength)..<plain.count)
        let files = try decodeArchive(archiveData)

        guard files.count == manifest.rules.count else {
            throw JuanchoPackageError.archiveMismatch
        }

        var matched = Set<String>()
        for file in files {
            guard let rule = ruleForArchiveFile(file.path, basePath: header.basePath, rules: manifest.rules),
                  matched.insert(rule.relativePath).inserted,
                  sha256(file.data).caseInsensitiveCompare(rule.sha256) == .orderedSame,
                  file.data.count == rule.size else {
                throw JuanchoPackageError.hashMismatch
            }
        }

        guard matched.count == manifest.rules.count else {
            throw JuanchoPackageError.archiveMismatch
        }

        return JuanchoDocument(header: header, manifest: manifest, files: files)
    }

    private static func ruleForArchiveFile(
        _ archivePath: String,
        basePath: String,
        rules: [JuanchoRule]
    ) -> JuanchoRule? {
        let normalizedArchive = normalized(archivePath)
        let base = normalized(basePath)
        let prefix = base.isEmpty ? "" : base + "/"

        return rules.first { rule in
            let normalizedDestination = normalized(rule.relativePath)
            let candidate = normalizedDestination.hasPrefix(prefix)
                ? String(normalizedDestination.dropFirst(prefix.count))
                : normalizedDestination
            return candidate == normalizedArchive
        }
    }

    private static func validate(
        _ manifest: JuanchoManifest,
        header: JuanchoPackageHeader
    ) throws {
        var destinations = Set<String>()
        guard !manifest.projectName.isEmpty,
              manifest.projectName == header.projectName,
              manifest.bundleIdentifiers.contains(header.targetBundleID),
              manifest.bundleIdentifiers.allSatisfy(isValidBundleID) else {
            throw JuanchoPackageError.malformedPayload
        }

        for rule in manifest.rules {
            guard rule.operation == "replace",
                  isValidBundleID(rule.bundleID),
                  rule.bundleID == header.targetBundleID,
                  rule.size >= 0 else {
                throw JuanchoPackageError.malformedPayload
            }

            let path = normalized(rule.relativePath)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  !path.contains(":") else {
                throw JuanchoPackageError.unsafePath
            }

            guard destinations.insert(path).inserted else {
                throw JuanchoPackageError.duplicateDestination
            }
        }
    }

    private static func isValidBundleID(_ id: String) -> Bool {
        let pieces = id.split(separator: ".")
        guard pieces.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return pieces.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    private static func normalized(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func decodeArchive(_ data: Data) throws -> [JuanchoFile] {
        guard data.count >= 11,
              data.prefix(7) == Data("JNPAYL1".utf8) else {
            throw JuanchoPackageError.malformedPayload
        }

        var cursor = 7
        let count = Int(readUInt32LE(data, cursor))
        cursor += 4
        guard count >= 1, count <= 100_000 else {
            throw JuanchoPackageError.malformedPayload
        }

        var result: [JuanchoFile] = []
        result.reserveCapacity(count)
        var seen = Set<String>()

        for _ in 0..<count {
            guard cursor + 12 <= data.count else {
                throw JuanchoPackageError.malformedPayload
            }

            let pathLength = Int(readUInt32LE(data, cursor))
            cursor += 4
            let dataLength64 = readUInt64LE(data, cursor)
            cursor += 8
            guard dataLength64 <= UInt64(Int.max) else {
                throw JuanchoPackageError.malformedPayload
            }
            let dataLength = Int(dataLength64)

            guard pathLength > 0,
                  cursor + pathLength <= data.count,
                  cursor + pathLength + dataLength <= data.count else {
                throw JuanchoPackageError.malformedPayload
            }

            let rawPath = data.subdata(in: cursor..<(cursor + pathLength))
            cursor += pathLength
            let path = String(data: rawPath, encoding: .utf8).map(normalized) ?? ""
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  !path.contains(":"),
                  seen.insert(path).inserted else {
                throw JuanchoPackageError.unsafePath
            }

            let bytes = data.subdata(in: cursor..<(cursor + dataLength))
            cursor += dataLength
            result.append(JuanchoFile(path: path, data: bytes))
        }

        guard cursor == data.count else {
            throw JuanchoPackageError.archiveMismatch
        }

        return result
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << UInt64(8 * i)
        }
        return value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
