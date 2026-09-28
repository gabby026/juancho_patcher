import Foundation
import CryptoKit

enum JuanchoCrypto {
    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
        var out = Data()
        let blocks = (length + 31) / 32
        for n in 1...blocks {
            var sb = salt
            var be = UInt32(n).bigEndian
            withUnsafeBytes(of: &be) { sb.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: sb, using: SymmetricKey(data: password)))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: SymmetricKey(data: password)))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            out.append(t)
        }
        return out.prefix(length)
    }

    static func decrypt(_ data: Data, password: String, salt: Data, nonce: Data, aad: Data, iterations: Int) throws -> Data {
        guard data.count >= 16 else { throw NSError(domain:"Juancho", code:1, userInfo:[NSLocalizedDescriptionKey:"Invalid encrypted payload"]) }
        let key = SymmetricKey(data: pbkdf2SHA256(password: Data(password.utf8), salt: salt, iterations: iterations))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}
