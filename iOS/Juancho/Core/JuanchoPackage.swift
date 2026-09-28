import Foundation
import CryptoKit

enum JuanchoPackage {
    static let magic = Data("JUANCHO1".utf8)

    static func header(_ data: Data) throws -> JuanchoHeader {
        guard data.count > 14, data.prefix(8) == magic, data[8] == 1 else { throw NSError(domain:"Juancho",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid JUANCHO package"]) }
        let n = Int(UInt32(data[10]) | UInt32(data[11])<<8 | UInt32(data[12])<<16 | UInt32(data[13])<<24)
        guard 14+n <= data.count else { throw NSError(domain:"Juancho",code:2,userInfo:[NSLocalizedDescriptionKey:"Malformed header"]) }
        return try JSONDecoder().decode(JuanchoHeader.self, from:data.subdata(in:14..<14+n))
    }

    static func sha256(_ d: Data) -> String {
        SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined()
    }

    static func read(_ data: Data, password: String? = nil) throws -> JuanchoDocument {
        let h = try header(data)
        let n = Int(UInt32(data[10]) | UInt32(data[11])<<8 | UInt32(data[12])<<16 | UInt32(data[13])<<24)
        var payload = data.subdata(in:(14+n)..<data.count)
        if h.passwordProtected {
            guard let password, let s=h.salt, let no=h.nonce, let it=h.kdfIterations,
                  let salt=Data(base64Encoded:s), let nonce=Data(base64Encoded:no) else { throw NSError(domain:"Juancho",code:3,userInfo:[NSLocalizedDescriptionKey:"Password required"]) }
            payload = try JuanchoCrypto.decrypt(payload,password:password,salt:salt,nonce:nonce,aad:Data("JUANCHO1/v1/\(h.projectName)".utf8),iterations:it)
        }
        guard sha256(payload).lowercased() == h.payloadSHA256.lowercased() else { throw NSError(domain:"Juancho",code:4,userInfo:[NSLocalizedDescriptionKey:"Payload hash mismatch"]) }
        // The package archive decoder is intentionally kept separate from filesystem access.
        // This initial build validates the container/header; the full archive decoder belongs in the next package revision.
        throw NSError(domain:"Juancho",code:5,userInfo:[NSLocalizedDescriptionKey:"Package header validated. Archive decoder not yet enabled in this build."]) 
    }
}
