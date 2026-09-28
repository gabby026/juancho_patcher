import Foundation
import CryptoKit

enum JuanchoCryptoError: Error, LocalizedError {
    case missingCryptoMetadata
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .missingCryptoMetadata:
            return "Encrypted package is missing required crypto metadata."
        case .invalidCiphertext:
            return "Encrypted package payload is invalid."
        }
    }
}

enum JuanchoCrypto {
    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        length: Int = 32
    ) -> Data {
        precondition(iterations >= 1)
        precondition(length >= 1)

        var result = Data()
        let blockCount = (length + 31) / 32

        for blockIndex in 1...blockCount {
            var saltAndCounter = salt
            var counter = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &counter) {
                saltAndCounter.append(contentsOf: $0)
            }

            let key = SymmetricKey(data: password)
            var u = Data(HMAC<SHA256>.authenticationCode(
                for: saltAndCounter,
                using: key
            ))
            var t = u

            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(
                        for: u,
                        using: key
                    ))

                    for i in t.indices {
                        t[i] ^= u[i]
                    }
                }
            }

            result.append(t)
        }

        return result.prefix(length)
    }

    static func open(
        ciphertext: Data,
        password: String,
        salt: Data,
        nonce: Data,
        aad: Data,
        iterations: Int
    ) throws -> Data {
        guard nonce.count == 12, ciphertext.count >= 16 else {
            throw JuanchoCryptoError.invalidCiphertext
        }

        let derived = SymmetricKey(
            data: pbkdf2SHA256(
                password: Data(password.utf8),
                salt: salt,
                iterations: iterations,
                length: 32
            )
        )

        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let tagStart = ciphertext.count - 16
            let encrypted = ciphertext.prefix(tagStart)
            let tag = ciphertext.suffix(16)
            let box = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: encrypted,
                tag: tag
            )
            return try AES.GCM.open(
                box,
                using: derived,
                authenticating: aad
            )
        } catch {
            throw error
        }
    }
}
