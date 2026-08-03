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
    case invalidArtifactMetadata(String)
    case invalidManifest(String)
    case unknownKeyID(String)
    case invalidSignature
    case fileHashMismatch(String)
    case artifactHashMismatch
}

extension BikeMapStreamFormatError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .truncated: "Map stream is truncated."
        case .invalidMagic: "Map stream has an invalid header."
        case .unsupportedVersion: "Map stream version is not supported."
        case .unsupportedFlags: "Map stream flags are not supported."
        case .invalidReserved: "Map stream reserved header fields are invalid."
        case .invalidManifestLength: "Map stream manifest length is invalid."
        case .invalidEnvelopeLength: "Map stream signature envelope length is invalid."
        case .invalidFileCount: "Map stream file count is invalid."
        case .invalidPayloadLength: "Map stream payload length is invalid."
        case .invalidContentLength: "Map stream content length is invalid."
        case .invalidAlgorithm: "Map stream signature algorithm is not supported."
        case .invalidKeyID: "Map stream signing key ID is invalid."
        case .invalidSignatureLength: "Map stream signature length is invalid."
        case .nonCanonicalSignature: "Map stream signature is not canonical."
        case .invalidArtifactMetadata(let reason): "Map artifact metadata is invalid: \(reason)."
        case .invalidManifest(let reason): "Map stream manifest is invalid: \(reason)."
        case .unknownKeyID(let keyID): "Map stream signing key is not trusted: \(keyID)."
        case .invalidSignature: "Map stream signature is invalid."
        case .fileHashMismatch(let path): "Map stream file hash does not match: \(path)."
        case .artifactHashMismatch: "Map artifact hash does not match."
        }
    }
}

nonisolated struct BikeMapStreamTrustStore: Equatable {
    private let publicKeysByID: [String: Data]

    init(publicKeysByID: [String: Data]) {
        self.publicKeysByID = publicKeysByID
    }

    func contains(keyID: String) -> Bool {
        publicKeyX963(for: keyID) != nil
    }

    func publicKeyX963(for keyID: String) -> Data? {
        guard keyID.range(
            of: "^[A-Za-z0-9._-]{1,64}$",
            options: .regularExpression
        ) != nil,
        let value = publicKeysByID[keyID],
        (try? P256.Signing.PublicKey(x963Representation: value)) != nil else {
            return nil
        }
        return value
    }

    func capability(for keyID: String) -> String? {
        guard let publicKey = publicKeyX963(for: keyID) else { return nil }
        let fingerprint = SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(keyID)=\(fingerprint)"
    }

    var capabilityHeaderValue: String? {
        let capabilities = publicKeysByID.keys.sorted().compactMap(capability(for:))
        return capabilities.isEmpty ? nil : capabilities.joined(separator: ",")
    }

    var isEmpty: Bool { publicKeysByID.isEmpty }

}

nonisolated struct VerifiedBikeMapArtifact: Equatable {
    let url: URL
    let mapID: String
    let displayName: String?
    let bytes: Int64
    let sha256: String
    let manifestReceipt: String
    let signedManifestReceipt: String
    let signatureKeyID: String
    let signatureKeySHA256: String
    let producerBuildSHA256: String
    let producerImageDigest: String
    let requiredIosBuild: String?
    let requiredIosGitSHA: String?
    let requiredIosBuildSHA256: String?
    let requiredFirmwareVersion: String?
    let requiredFirmwareBuild: UInt32?
    let requiredFirmwareGitSHA: String?
    let fileCount: Int
    let payloadBytes: Int64

    fileprivate init(
        url: URL,
        mapID: String,
        displayName: String?,
        bytes: Int64,
        sha256: String,
        manifestReceipt: String,
        signedManifestReceipt: String,
        signatureKeyID: String,
        signatureKeySHA256: String,
        producerBuildSHA256: String,
        producerImageDigest: String,
        requiredIosBuild: String?,
        requiredIosGitSHA: String?,
        requiredIosBuildSHA256: String?,
        requiredFirmwareVersion: String?,
        requiredFirmwareBuild: UInt32?,
        requiredFirmwareGitSHA: String?,
        fileCount: Int,
        payloadBytes: Int64
    ) {
        self.url = url
        self.mapID = mapID
        self.displayName = displayName
        self.bytes = bytes
        self.sha256 = sha256
        self.manifestReceipt = manifestReceipt
        self.signedManifestReceipt = signedManifestReceipt
        self.signatureKeyID = signatureKeyID
        self.signatureKeySHA256 = signatureKeySHA256
        self.producerBuildSHA256 = producerBuildSHA256
        self.producerImageDigest = producerImageDigest
        self.requiredIosBuild = requiredIosBuild
        self.requiredIosGitSHA = requiredIosGitSHA
        self.requiredIosBuildSHA256 = requiredIosBuildSHA256
        self.requiredFirmwareVersion = requiredFirmwareVersion
        self.requiredFirmwareBuild = requiredFirmwareBuild
        self.requiredFirmwareGitSHA = requiredFirmwareGitSHA
        self.fileCount = fileCount
        self.payloadBytes = payloadBytes
    }
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
    static let maximumArtifactBytes: Int64 =
        Int64(fixedHeaderBytes + maximumManifestBytes + 4 + maximumKeyIDBytes + rawP256SignatureBytes) +
        Int64(maximumPayloadBytes)
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

nonisolated enum BikeMapStreamArtifactValidator {
    private static let mediaType = "application/vnd.openbikecomputer.map-stream"
    private static let renderer = "esp32-fmb"
    private static let maximumMapIDBytes = 64
    private static let maximumPathComponentBytes = 64
    private static let maximumRelativePathBytes = 202
    private static let maximumBlockBytes = 2 * 1024 * 1024
    private static let maximumFontAssetBytes = 16 * 1024 * 1024
    private static let ioChunkBytes = 64 * 1024
    private static let lowercaseSHA256Pattern = "^[0-9a-f]{64}$"
    private static let safeMapIDPattern = "^[A-Za-z0-9._-]+$"
    private static let mapPathPattern =
        "^VECTMAP/[A-Za-z0-9._-]+/(?:[A-Za-z0-9+._-]+/[A-Za-z0-9+._-]+\\.fm[bp]|assets/street-labels\\.fma)$"

    struct Manifest: Decodable {
        struct Producer: Decodable {
            let buildSha256: String
            let imageDigest: String
        }

        struct Target: Decodable {
            let renderer: String
            let formatVersion: Int
            let labelProfileVersion: Int?
            let labelLanguages: [String]?
            let internationalFallback: String?
        }

        struct File: Decodable {
            let path: String
            let bytes: Int64
            let sha256: String
        }

        let schemaVersion: Int
        let mapId: String
        let displayName: String?
        let producer: Producer
        let target: Target
        let files: [File]
    }

    static func validate(
        url: URL,
        artifact: OfflineMapArtifact,
        expectedMapID: String,
        trustStore: BikeMapStreamTrustStore
    ) throws -> VerifiedBikeMapArtifact {
        guard artifact.isBikeMapStream else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("unexpected artifact format")
        }
        guard artifact.mediaType == mediaType else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("unexpected media type")
        }
        guard artifact.bytes > 0 else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("byte count is missing")
        }
        guard isLowercaseSHA256(artifact.sha256) else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("artifact SHA-256 is invalid")
        }
        guard let expectedManifestReceipt = artifact.manifestReceipt,
              isLowercaseSHA256(expectedManifestReceipt) else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("manifest receipt is invalid")
        }
        guard let expectedSignedReceipt = artifact.signedManifestReceipt,
              isLowercaseSHA256(expectedSignedReceipt) else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("signed manifest receipt is invalid")
        }
        guard let expectedKeyID = artifact.signatureKeyId, !expectedKeyID.isEmpty else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("signing key ID is missing")
        }
        guard let expectedKeySHA256 = artifact.signatureKeySha256,
              isLowercaseSHA256(expectedKeySHA256) else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "signing key fingerprint is invalid"
            )
        }
        guard let producerBuildSHA256 = artifact.producerBuildSha256,
              isLowercaseSHA256(producerBuildSHA256) else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "producer build identity is invalid"
            )
        }
        guard let producerImageDigest = artifact.producerImageDigest,
              producerImageDigest.range(
                  of: "^sha256:[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "producer image identity is invalid"
            )
        }
        guard let iosBuild = artifact.requiredIosBuild,
              iosBuild.range(
                  of: "^[0-9]{1,18}(?:\\.[0-9]{1,18}){0,2}$",
                  options: .regularExpression
              ) != nil,
              let iosGitSHA = artifact.requiredIosGitSha,
              iosGitSHA.range(
                  of: "^[0-9a-f]{40}$",
                  options: .regularExpression
              ) != nil,
              let iosBuildSHA256 = artifact.requiredIosBuildSha256,
              isLowercaseSHA256(iosBuildSHA256) else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "required app identity is incomplete"
            )
        }
        let firmwareRequirements = (
            artifact.requiredFirmwareVersion,
            artifact.requiredFirmwareBuild,
            artifact.requiredFirmwareGitSha
        )
        let hasAnyFirmwareRequirement = firmwareRequirements.0 != nil ||
            firmwareRequirements.1 != nil || firmwareRequirements.2 != nil
        if hasAnyFirmwareRequirement {
            guard let version = firmwareRequirements.0, !version.isEmpty,
                  let build = firmwareRequirements.1, build > 0,
                  let gitSHA = firmwareRequirements.2,
                  gitSHA.range(
                      of: "^[0-9a-f]{40}$",
                      options: .regularExpression
                  ) != nil else {
                throw BikeMapStreamFormatError.invalidArtifactMetadata(
                    "required client/device identity is incomplete"
                )
            }
        }
        guard trustStore.capability(for: expectedKeyID) ==
                "\(expectedKeyID)=\(expectedKeySHA256)" else {
            throw BikeMapStreamFormatError.unknownKeyID(expectedKeyID)
        }
        let expectedObjectKey =
            "maps/\(expectedMapID)/\(OfflineMapArtifact.bikeMapStreamFormat)/" +
            "\(expectedKeyID)/\(expectedKeySHA256)/" +
            "\(producerBuildSHA256)/" +
            "\(producerImageDigest.dropFirst(7))/\(expectedSignedReceipt).bmap"
        guard artifact.filename == "\(expectedMapID).bmap",
              artifact.objectKey == expectedObjectKey else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "filename or object identity does not match"
            )
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize,
              Int64(fileSize) == artifact.bytes else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("local file size does not match")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var artifactHasher = SHA256()
        var consumedBytes: Int64 = 0

        func readExactly(_ count: Int) throws -> Data {
            guard count >= 0 else { throw BikeMapStreamFormatError.truncated }
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                if Task.isCancelled { throw CancellationError() }
                let requested = min(ioChunkBytes, count - result.count)
                let chunk = try handle.read(upToCount: requested) ?? Data()
                guard !chunk.isEmpty else { throw BikeMapStreamFormatError.truncated }
                result.append(chunk)
                artifactHasher.update(data: chunk)
                consumedBytes += Int64(chunk.count)
            }
            return result
        }

        let headerData = try readExactly(BikeMapStreamFormat.fixedHeaderBytes)
        let header = try BikeMapStreamFormat.parseHeader(headerData)
        _ = try BikeMapStreamFormat.layout(
            header: header,
            contentBytes: UInt64(artifact.bytes)
        )
        let manifestData = try readExactly(Int(header.manifestBytes))
        let envelopeData = try readExactly(Int(header.signatureEnvelopeBytes))
        let envelope = try BikeMapStreamFormat.parseSignatureEnvelope(envelopeData)

        guard envelope.keyID == expectedKeyID else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("signing key ID does not match")
        }
        guard BikeMapStreamFormat.manifestReceipt(manifestData) == expectedManifestReceipt else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("manifest receipt does not match")
        }
        guard BikeMapStreamFormat.signedManifestReceipt(
            manifest: manifestData,
            envelope: envelopeData
        ) == expectedSignedReceipt else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("signed manifest receipt does not match")
        }
        guard let publicKey = trustStore.publicKeyX963(for: envelope.keyID) else {
            throw BikeMapStreamFormatError.unknownKeyID(envelope.keyID)
        }
        guard BikeMapStreamFormat.verifyP256Signature(
            manifest: manifestData,
            envelope: envelope,
            publicKeyX963: publicKey
        ) else {
            throw BikeMapStreamFormatError.invalidSignature
        }

        let manifest = try decodeAndValidateManifest(
            manifestData,
            expectedMapID: expectedMapID,
            header: header
        )
        guard manifest.producer.buildSha256 == producerBuildSHA256,
              manifest.producer.imageDigest == producerImageDigest else {
            throw BikeMapStreamFormatError.invalidManifest(
                "producer identity does not match artifact metadata"
            )
        }
        for file in manifest.files {
            var fileHasher = SHA256()
            var remaining = file.bytes
            var filePrefix = Data()
            while remaining > 0 {
                let chunkBytes = Int(min(Int64(ioChunkBytes), remaining))
                let chunk = try readExactly(chunkBytes)
                if filePrefix.count < 4 {
                    filePrefix.append(chunk.prefix(4 - filePrefix.count))
                }
                fileHasher.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            guard hex(fileHasher.finalize()) == file.sha256 else {
                throw BikeMapStreamFormatError.fileHashMismatch(file.path)
            }
            try validateFileHeader(
                filePrefix,
                path: file.path,
                rendererFormatVersion: manifest.target.formatVersion
            )
        }
        guard consumedBytes == artifact.bytes else {
            throw BikeMapStreamFormatError.invalidContentLength
        }
        guard try handle.read(upToCount: 1)?.isEmpty != false else {
            throw BikeMapStreamFormatError.invalidContentLength
        }
        guard hex(artifactHasher.finalize()) == artifact.sha256 else {
            throw BikeMapStreamFormatError.artifactHashMismatch
        }

        return VerifiedBikeMapArtifact(
            url: url,
            mapID: manifest.mapId,
            displayName: manifest.displayName,
            bytes: artifact.bytes,
            sha256: artifact.sha256,
            manifestReceipt: expectedManifestReceipt,
            signedManifestReceipt: expectedSignedReceipt,
            signatureKeyID: expectedKeyID,
            signatureKeySHA256: expectedKeySHA256,
            producerBuildSHA256: producerBuildSHA256,
            producerImageDigest: producerImageDigest,
            requiredIosBuild: artifact.requiredIosBuild,
            requiredIosGitSHA: artifact.requiredIosGitSha,
            requiredIosBuildSHA256: artifact.requiredIosBuildSha256,
            requiredFirmwareVersion: artifact.requiredFirmwareVersion,
            requiredFirmwareBuild: artifact.requiredFirmwareBuild,
            requiredFirmwareGitSHA: artifact.requiredFirmwareGitSha,
            fileCount: manifest.files.count,
            payloadBytes: Int64(header.payloadBytes)
        )
    }

    static func decodeAndValidateManifest(
        _ data: Data,
        expectedMapID: String,
        header: BikeMapStreamFormat.Header
    ) throws -> Manifest {
        do {
            try CanonicalMapManifestJSON.validate(data)
        } catch let error as BikeMapStreamFormatError {
            throw error
        } catch {
            throw BikeMapStreamFormatError.invalidManifest("JSON cannot be decoded")
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw BikeMapStreamFormatError.invalidManifest("required fields are malformed")
        }
        guard manifest.schemaVersion == 1 else {
            throw BikeMapStreamFormatError.invalidManifest("schema version is unsupported")
        }
        guard isSafeMapID(manifest.mapId), manifest.mapId == expectedMapID else {
            throw BikeMapStreamFormatError.invalidManifest("map ID does not match")
        }
        guard manifest.target.renderer == renderer,
              manifest.target.formatVersion == 1 || manifest.target.formatVersion == 2 else {
            throw BikeMapStreamFormatError.invalidManifest("renderer target is unsupported")
        }
        guard !manifest.files.isEmpty,
              manifest.files.count == Int(header.fileCount) else {
            throw BikeMapStreamFormatError.invalidManifest("file count does not match")
        }

        var payloadBytes: Int64 = 0
        var fontAssetCount = 0
        var legacyTextBlockCount = 0
        var previousPath: String?
        for file in manifest.files {
            guard isSafeMapPath(file.path, mapID: manifest.mapId) else {
                throw BikeMapStreamFormatError.invalidManifest("map file path is unsafe")
            }
            guard previousPath.map({ $0 < file.path }) ?? true else {
                throw BikeMapStreamFormatError.invalidManifest("map file paths are not unique and sorted")
            }
            previousPath = file.path
            let isFontAsset = file.path ==
                "VECTMAP/\(manifest.mapId)/assets/street-labels.fma"
            guard file.bytes > 0,
                  file.bytes <= Int64(isFontAsset ? maximumFontAssetBytes : maximumBlockBytes) else {
                throw BikeMapStreamFormatError.invalidManifest("map file size is invalid")
            }
            if isFontAsset { fontAssetCount += 1 }
            if file.path.hasSuffix(".fmp") { legacyTextBlockCount += 1 }
            let (sum, overflow) = payloadBytes.addingReportingOverflow(file.bytes)
            guard !overflow, sum <= Int64(BikeMapStreamFormat.maximumPayloadBytes) else {
                throw BikeMapStreamFormatError.invalidManifest("payload size overflows limits")
            }
            payloadBytes = sum
            guard isLowercaseSHA256(file.sha256) else {
                throw BikeMapStreamFormatError.invalidManifest("map file SHA-256 is invalid")
            }
        }
        if manifest.target.formatVersion == 2 {
            guard fontAssetCount == 1, legacyTextBlockCount == 0,
                  manifest.target.labelProfileVersion == 1,
                  let languages = manifest.target.labelLanguages,
                  languages.count <= 3,
                  Set(languages).count == languages.count,
                  languages.allSatisfy(isCanonicalLanguageTag),
                  let fallback = manifest.target.internationalFallback,
                  isCanonicalLanguageTag(fallback) else {
                throw BikeMapStreamFormatError.invalidManifest(
                    "renderer target 2 label metadata is invalid"
                )
            }
        } else if fontAssetCount != 0 ||
                    manifest.target.labelProfileVersion != nil ||
                    manifest.target.labelLanguages != nil ||
                    manifest.target.internationalFallback != nil {
            throw BikeMapStreamFormatError.invalidManifest(
                "renderer target 1 contains label data"
            )
        }
        guard UInt64(payloadBytes) == header.payloadBytes else {
            throw BikeMapStreamFormatError.invalidManifest("payload size does not match")
        }
        return manifest
    }

    private static func isSafeMapID(_ value: String) -> Bool {
        value != "." && value != ".." &&
            value.data(using: .ascii).map { $0.count <= maximumMapIDBytes } == true &&
            value.range(of: safeMapIDPattern, options: .regularExpression) != nil
    }

    private static func isSafeMapPath(_ value: String, mapID: String) -> Bool {
        guard let bytes = value.data(using: .ascii),
              bytes.count <= maximumRelativePathBytes,
              value.hasPrefix("VECTMAP/\(mapID)/"),
              value.range(of: mapPathPattern, options: .regularExpression) != nil else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 4 && components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." &&
                $0.utf8.count <= maximumPathComponentBytes
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.range(of: lowercaseSHA256Pattern, options: .regularExpression) != nil
    }

    static func validateFileHeader(
        _ prefix: Data,
        path: String,
        rendererFormatVersion: Int
    ) throws {
        if path.hasSuffix(".fmb") {
            guard prefix.count == 4,
                  prefix.prefix(3) == Data("FMB".utf8) else {
                throw BikeMapStreamFormatError.invalidManifest(
                    "binary map block header does not match its target"
                )
            }
            let expectedVersions: Set<UInt8> =
                rendererFormatVersion == 2 ? [3] : [1, 2]
            guard expectedVersions.contains(prefix[3]) else {
                throw BikeMapStreamFormatError.invalidManifest(
                    "binary map block version does not match its target"
                )
            }
        } else if path.hasSuffix(".fma") && prefix != Data("FMA1".utf8) {
            throw BikeMapStreamFormatError.invalidManifest(
                "street-label font asset header is invalid"
            )
        }
    }

    private static func isCanonicalLanguageTag(_ value: String) -> Bool {
        guard let ascii = value.data(using: .ascii),
              !ascii.isEmpty, ascii.count <= 35 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
              (2...8).contains(parts[0].count),
              parts[0].allSatisfy({ $0.isASCII && $0.isLowercase }) else {
            return false
        }
        for part in parts.dropFirst() {
            guard (1...8).contains(part.count),
                  part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                return false
            }
            if part.count == 4 && part.allSatisfy(\.isLetter) {
                guard part.first?.isUppercase == true,
                      part.dropFirst().allSatisfy(\.isLowercase) else { return false }
            } else if part.count == 2 && part.allSatisfy(\.isLetter) {
                guard part.allSatisfy(\.isUppercase) else { return false }
            } else if part.contains(where: \.isLetter) &&
                        !part.allSatisfy({ !$0.isLetter || $0.isLowercase }) {
                return false
            }
        }
        return true
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private enum CanonicalMapManifestJSON {
    private static let maximumNestingDepth = 64

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
            throw BikeMapStreamFormatError.invalidManifest("JSON is not valid UTF-8")
        }
        var parser = Parser(bytes: Array(data))
        try parser.parseValue(depth: 0)
        guard parser.index == parser.bytes.count else {
            throw BikeMapStreamFormatError.invalidManifest("JSON has trailing or whitespace bytes")
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseValue(depth: Int) throws {
            guard depth <= maximumNestingDepth, index < bytes.count else {
                throw invalid("JSON nesting or length is invalid")
            }
            switch bytes[index] {
            case 0x7B: try parseObject(depth: depth + 1)
            case 0x5B: try parseArray(depth: depth + 1)
            case 0x22: _ = try parseString()
            case 0x74: try consume("true")
            case 0x66: try consume("false")
            case 0x6E: try consume("null")
            case 0x2D, 0x30...0x39: try parseNumber()
            default: throw invalid("JSON contains non-canonical whitespace or a token error")
            }
        }

        mutating func parseObject(depth: Int) throws {
            index += 1
            if consumeIf(0x7D) { return }
            var previousKey: String?
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw invalid("JSON object key is invalid")
                }
                let key = try parseString()
                if let previousKey,
                   !previousKey.utf8.lexicographicallyPrecedes(key.utf8) {
                    throw invalid("JSON object keys are not unique and sorted")
                }
                previousKey = key
                guard consumeIf(0x3A) else { throw invalid("JSON object separator is invalid") }
                try parseValue(depth: depth)
                if consumeIf(0x7D) { return }
                guard consumeIf(0x2C) else { throw invalid("JSON object delimiter is invalid") }
            }
        }

        mutating func parseArray(depth: Int) throws {
            index += 1
            if consumeIf(0x5D) { return }
            while true {
                try parseValue(depth: depth)
                if consumeIf(0x5D) { return }
                guard consumeIf(0x2C) else { throw invalid("JSON array delimiter is invalid") }
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let token = Data(bytes[start..<index])
                    do {
                        return try JSONDecoder().decode(String.self, from: token)
                    } catch {
                        throw invalid("JSON string is invalid")
                    }
                }
                if byte < 0x20 {
                    throw invalid("JSON string contains an unescaped control byte")
                }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else { throw invalid("JSON string escape is truncated") }
                    switch bytes[index] {
                    case 0x22, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        index += 1
                    case 0x75:
                        try parseCanonicalUnicodeControlEscape()
                    default:
                        throw invalid("JSON string escape is not canonical")
                    }
                    continue
                }
                index += 1
            }
            throw invalid("JSON string is truncated")
        }

        mutating func parseCanonicalUnicodeControlEscape() throws {
            guard index + 4 < bytes.count else { throw invalid("JSON Unicode escape is truncated") }
            let digits = bytes[(index + 1)...(index + 4)]
            guard digits.allSatisfy({
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }) else {
                throw invalid("JSON Unicode escape is not lowercase hexadecimal")
            }
            let text = String(bytes: digits, encoding: .ascii) ?? ""
            guard let value = UInt16(text, radix: 16), value < 0x20,
                  ![0x08, 0x09, 0x0A, 0x0C, 0x0D].contains(value) else {
                throw invalid("JSON Unicode escape is not minimal")
            }
            index += 5
        }

        mutating func parseNumber() throws {
            let start = index
            if consumeIf(0x2D), index >= bytes.count {
                throw invalid("JSON number is truncated")
            }
            if consumeIf(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw invalid("JSON number has a leading zero")
                }
            } else {
                guard consumeDigits(requireOne: true) else { throw invalid("JSON number is invalid") }
            }
            let text = String(bytes: bytes[start..<index], encoding: .ascii) ?? ""
            if text == "-0" {
                throw invalid("JSON integer is not shortest-form canonical")
            }
            if index < bytes.count,
               bytes[index] == 0x2E || bytes[index] == 0x65 || bytes[index] == 0x45 {
                throw invalid("JSON floating-point numbers are unsupported")
            }
        }

        mutating func consumeDigits(requireOne: Bool) -> Bool {
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
            return !requireOne || index > start
        }

        mutating func consume(_ value: StaticString) throws {
            let expected = Array(String(describing: value).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw invalid("JSON literal is invalid")
            }
            index += expected.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        func invalid(_ reason: String) -> BikeMapStreamFormatError {
            .invalidManifest(reason)
        }
    }
}

nonisolated enum OfflineMapArtifactFileValidator {
    static func validate(url: URL, artifact: OfflineMapArtifact) throws {
        guard artifact.bytes > 0,
              artifact.sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("artifact identity is invalid")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              Int64(fileSize) == artifact.bytes else {
            throw BikeMapStreamFormatError.invalidArtifactMetadata("local file size does not match")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else {
            throw BikeMapStreamFormatError.artifactHashMismatch
        }
    }
}

extension Data {
    nonisolated init(mapStreamHexLiteral: String) {
        precondition(mapStreamHexLiteral.count.isMultiple(of: 2))
        self.init()
        var index = mapStreamHexLiteral.startIndex
        while index < mapStreamHexLiteral.endIndex {
            let next = mapStreamHexLiteral.index(index, offsetBy: 2)
            guard let value = UInt8(mapStreamHexLiteral[index..<next], radix: 16) else {
                preconditionFailure("generated map stream public key is not hexadecimal")
            }
            append(value)
            index = next
        }
    }
}

private extension Data {
    nonisolated init(hexLiteral: String) {
        self.init(mapStreamHexLiteral: hexLiteral)
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
