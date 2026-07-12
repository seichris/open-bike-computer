import CryptoKit
import Foundation

enum BikeMapStreamFormatError: Error, Equatable {
    case truncated
    case invalidMagic
    case unsupportedVersion
    case unsupportedFlags
    case invalidReserved
    case invalidManifestLength
    case invalidEnvelopeLength
    case invalidFileCount
    case invalidPayloadLength
    case invalidContentLength
    case invalidAlgorithm
    case invalidKeyID
    case invalidSignatureLength
    case nonCanonicalSignature
}

nonisolated enum BikeMapStreamFormat {
    static let fixedHeaderBytes = 32
    static let formatVersion: UInt16 = 1
    static let p256SHA256Algorithm: UInt8 = 1
    static let rawP256SignatureBytes = 64
    static let signatureDomain = Data("open-bike-computer-map-manifest-v1\0".utf8)
    static let maximumManifestBytes = 2 * 1024 * 1024
    static let maximumKeyIDBytes = 64
    static let maximumFileCount: UInt32 = 100_000
    static let maximumPayloadBytes: UInt64 = 512 * 1024 * 1024
    private static let magic = Data("BIKEMAP1".utf8)
    private static let p256Order = Array(Data(hexLiteral: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"))
    private static let p256HalfOrder = Array(Data(hexLiteral: "7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8"))

    struct Header: Equatable {
        let formatVersion: UInt16
        let flags: UInt16
        let manifestBytes: UInt32
        let signatureEnvelopeBytes: UInt16
        let fileCount: UInt32
        let payloadBytes: UInt64

        var totalBytes: UInt64 {
            UInt64(BikeMapStreamFormat.fixedHeaderBytes) +
                UInt64(manifestBytes) +
                UInt64(signatureEnvelopeBytes) +
                payloadBytes
        }
    }

    struct SignatureEnvelope: Equatable {
        let algorithmID: UInt8
        let keyID: String
        let rawSignature: Data
    }

    struct Layout: Equatable {
        let manifestOffset: Int
        let signatureEnvelopeOffset: Int
        let payloadOffset: Int
        let endOffset: Int
    }

    static func parseHeader(_ data: Data) throws -> Header {
        let bytes = Data(data)
        guard bytes.count == fixedHeaderBytes else { throw BikeMapStreamFormatError.truncated }
        guard bytes.prefix(magic.count) == magic else { throw BikeMapStreamFormatError.invalidMagic }
        let header = Header(
            formatVersion: bytes.uint16LE(at: 8),
            flags: bytes.uint16LE(at: 10),
            manifestBytes: bytes.uint32LE(at: 12),
            signatureEnvelopeBytes: bytes.uint16LE(at: 16),
            fileCount: bytes.uint32LE(at: 20),
            payloadBytes: bytes.uint64LE(at: 24)
        )
        guard header.formatVersion == formatVersion else {
            throw BikeMapStreamFormatError.unsupportedVersion
        }
        guard header.flags == 0 else { throw BikeMapStreamFormatError.unsupportedFlags }
        guard bytes.uint16LE(at: 18) == 0 else { throw BikeMapStreamFormatError.invalidReserved }
        guard header.manifestBytes > 0, header.manifestBytes <= maximumManifestBytes else {
            throw BikeMapStreamFormatError.invalidManifestLength
        }
        let maximumEnvelopeBytes = 4 + maximumKeyIDBytes + rawP256SignatureBytes
        guard header.signatureEnvelopeBytes > 4,
              header.signatureEnvelopeBytes <= maximumEnvelopeBytes else {
            throw BikeMapStreamFormatError.invalidEnvelopeLength
        }
        guard header.fileCount > 0, header.fileCount <= maximumFileCount else {
            throw BikeMapStreamFormatError.invalidFileCount
        }
        guard header.payloadBytes > 0, header.payloadBytes <= maximumPayloadBytes else {
            throw BikeMapStreamFormatError.invalidPayloadLength
        }
        return header
    }

    static func parseSignatureEnvelope(_ data: Data) throws -> SignatureEnvelope {
        let bytes = Data(data)
        guard bytes.count >= 4 else { throw BikeMapStreamFormatError.truncated }
        let algorithmID = bytes[0]
        let keyIDBytes = Int(bytes[1])
        let signatureBytes = Int(bytes.uint16LE(at: 2))
        guard algorithmID == p256SHA256Algorithm else {
            throw BikeMapStreamFormatError.invalidAlgorithm
        }
        guard signatureBytes == rawP256SignatureBytes else {
            throw BikeMapStreamFormatError.invalidSignatureLength
        }
        guard bytes.count == 4 + keyIDBytes + signatureBytes else {
            throw BikeMapStreamFormatError.invalidEnvelopeLength
        }
        let rawSignature = Data(bytes.suffix(signatureBytes))
        guard isCanonicalP256Signature(rawSignature) else {
            throw BikeMapStreamFormatError.nonCanonicalSignature
        }
        let keyRange = 4..<(4 + keyIDBytes)
        guard keyIDBytes > 0,
              keyIDBytes <= maximumKeyIDBytes,
              let keyID = String(data: bytes[keyRange], encoding: .ascii),
              keyID.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) ||
                      (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) ||
                      byte == 45 || byte == 46 || byte == 95
              }) else {
            throw BikeMapStreamFormatError.invalidKeyID
        }
        return SignatureEnvelope(
            algorithmID: algorithmID,
            keyID: keyID,
            rawSignature: rawSignature
        )
    }

    static func layout(header: Header, contentBytes: UInt64) throws -> Layout {
        guard contentBytes == header.totalBytes,
              header.totalBytes <= UInt64(Int.max) else {
            throw BikeMapStreamFormatError.invalidContentLength
        }
        let manifestOffset = fixedHeaderBytes
        let envelopeOffset = manifestOffset + Int(header.manifestBytes)
        let payloadOffset = envelopeOffset + Int(header.signatureEnvelopeBytes)
        return Layout(
            manifestOffset: manifestOffset,
            signatureEnvelopeOffset: envelopeOffset,
            payloadOffset: payloadOffset,
            endOffset: Int(header.totalBytes)
        )
    }

    static func verifyP256Signature(
        manifest: Data,
        envelope: SignatureEnvelope,
        publicKeyX963: Data
    ) -> Bool {
        guard envelope.algorithmID == p256SHA256Algorithm,
              isCanonicalP256Signature(envelope.rawSignature),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: envelope.rawSignature) else {
            return false
        }
        var digest = SHA256()
        digest.update(data: signatureDomain)
        digest.update(data: manifest)
        return publicKey.isValidSignature(signature, for: digest.finalize())
    }

    static func manifestReceipt(_ manifest: Data) -> String {
        SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
    }

    static func signedManifestReceipt(manifest: Data, envelope: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: signatureDomain)
        hasher.update(data: manifest)
        hasher.update(data: envelope)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalP256Signature(_ signature: Data) -> Bool {
        guard signature.count == rawP256SignatureBytes else { return false }
        let bytes = Array(signature)
        let r = Array(bytes[0..<32])
        let s = Array(bytes[32..<64])
        return r.contains(where: { $0 != 0 }) &&
            compareBigEndian(r, p256Order) == .orderedAscending &&
            s.contains(where: { $0 != 0 }) &&
            compareBigEndian(s, p256HalfOrder) != .orderedDescending
    }

    private static func compareBigEndian(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

private extension Data {
    nonisolated init(hexLiteral: String) {
        self.init()
        var index = hexLiteral.startIndex
        while index < hexLiteral.endIndex {
            let next = hexLiteral.index(index, offsetBy: 2)
            append(UInt8(hexLiteral[index..<next], radix: 16)!)
            index = next
        }
    }

    nonisolated func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    nonisolated func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    nonisolated func uint64LE(at offset: Int) -> UInt64 {
        UInt64(uint32LE(at: offset)) | (UInt64(uint32LE(at: offset + 4)) << 32)
    }
}
