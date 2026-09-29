import Foundation
import Compression

enum CompressionError: Error, LocalizedError {
    case failed
    var errorDescription: String? { "Payload compression/decompression failed." }
}

enum ZlibHelper {
    static func compress(_ data: Data) throws -> Data {
        if data.isEmpty { return data }
        let source = [UInt8](data)
        var capacity = max(source.count / 2 + 1024, 4096)
        while capacity <= 256 * 1024 * 1024 {
            var destination = [UInt8](repeating: 0, count: capacity)
            let count = source.withUnsafeBytes { src in
                destination.withUnsafeMutableBytes { dst in
                    compression_encode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, source.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if count > 0 { return Data(destination.prefix(count)) }
            capacity *= 2
        }
        throw CompressionError.failed
    }

    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty { return data }
        let source = [UInt8](data)
        var capacity = max(expectedSize, 1024)
        while capacity <= 512 * 1024 * 1024 {
            var destination = [UInt8](repeating: 0, count: capacity)
            let decoded = source.withUnsafeBytes { src in
                destination.withUnsafeMutableBytes { dst in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, source.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0 { return Data(destination.prefix(decoded)) }
            capacity *= 2
        }
        throw CompressionError.failed
    }
}
