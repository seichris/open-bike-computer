//
//  DeviceTransferSecurity.swift
//  BikeComputer
//
//  BLE-pinned TLS policy for the device-local transfer server.
//

import CryptoKit
import Foundation
import Security

nonisolated enum DeviceTransferTLSChallengeOutcome: String, Equatable, Sendable {
    case defaultHandling = "default_handling"
    case hostMismatch = "host_mismatch"
    case invalidExpectedFingerprint = "invalid_expected_fingerprint"
    case missingServerTrust = "missing_server_trust"
    case certificateMismatch = "certificate_mismatch"
    case accepted
}

nonisolated struct DeviceTransferTLSChallengeEvaluation {
    let disposition: URLSession.AuthChallengeDisposition
    let credential: URLCredential?
    let outcome: DeviceTransferTLSChallengeOutcome
}

nonisolated struct DeviceTransferPinnedSessionSnapshot: Equatable, Sendable {
    var tlsChallengeOutcome: DeviceTransferTLSChallengeOutcome? = nil
    var waitedForConnectivity = false
    var connectStarted = false
    var connectCompleted = false
    var tlsStarted = false
    var tlsCompleted = false
    var connectDurationMilliseconds: Int? = nil
    var tlsDurationMilliseconds: Int? = nil
    var remoteEndpointMatched: Bool? = nil
    var localAddressInAccessorySubnet: Bool? = nil
    var networkProtocolName: String? = nil
    var reusedConnection = false
    var proxyConnection = false

    var diagnosticFields: [String: String] {
        var fields = [
            "tlsChallenge": tlsChallengeOutcome?.rawValue ?? "not_seen",
            "waitedForConnectivity": String(waitedForConnectivity),
            "connectStarted": String(connectStarted),
            "connectCompleted": String(connectCompleted),
            "tlsStarted": String(tlsStarted),
            "tlsCompleted": String(tlsCompleted),
            "connectionReused": String(reusedConnection),
            "proxyConnection": String(proxyConnection),
        ]
        if let connectDurationMilliseconds {
            fields["connectDurationMs"] = String(connectDurationMilliseconds)
        }
        if let tlsDurationMilliseconds {
            fields["tlsDurationMs"] = String(tlsDurationMilliseconds)
        }
        if let remoteEndpointMatched {
            fields["remoteEndpointMatched"] = String(remoteEndpointMatched)
        }
        if let localAddressInAccessorySubnet {
            fields["localAccessorySubnet"] =
                String(localAddressInAccessorySubnet)
        }
        if let networkProtocolName, !networkProtocolName.isEmpty {
            fields["networkProtocol"] = networkProtocolName
        }
        return fields
    }
}

nonisolated final class DeviceTransferPinnedSessionDiagnostics:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var current = DeviceTransferPinnedSessionSnapshot()

    func reset() {
        lock.lock()
        current = DeviceTransferPinnedSessionSnapshot()
        lock.unlock()
    }

    func snapshot() -> DeviceTransferPinnedSessionSnapshot {
        lock.lock()
        let result = current
        lock.unlock()
        return result
    }

    func record(challenge outcome: DeviceTransferTLSChallengeOutcome) {
        lock.lock()
        current.tlsChallengeOutcome = outcome
        lock.unlock()
    }

    func recordWaitingForConnectivity() {
        lock.lock()
        current.waitedForConnectivity = true
        lock.unlock()
    }

    func record(
        metrics: URLSessionTaskMetrics,
        expectedHost: String,
        expectedPort: Int
    ) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        let remoteEndpointMatched: Bool?
        if let remoteAddress = transaction.remoteAddress,
           let remotePort = transaction.remotePort {
            remoteEndpointMatched =
                remoteAddress.caseInsensitiveCompare(expectedHost) == .orderedSame &&
                remotePort == expectedPort
        } else {
            remoteEndpointMatched = nil
        }
        let localAddressInAccessorySubnet: Bool?
        if expectedHost == "192.168.4.1",
           let localAddress = transaction.localAddress {
            localAddressInAccessorySubnet = localAddress.hasPrefix("192.168.4.")
        } else {
            localAddressInAccessorySubnet = nil
        }

        lock.lock()
        current.connectStarted = transaction.connectStartDate != nil
        current.connectCompleted = transaction.connectEndDate != nil
        current.tlsStarted = transaction.secureConnectionStartDate != nil
        current.tlsCompleted = transaction.secureConnectionEndDate != nil
        current.connectDurationMilliseconds = Self.durationMilliseconds(
            from: transaction.connectStartDate,
            to: transaction.connectEndDate
        )
        current.tlsDurationMilliseconds = Self.durationMilliseconds(
            from: transaction.secureConnectionStartDate,
            to: transaction.secureConnectionEndDate
        )
        current.remoteEndpointMatched = remoteEndpointMatched
        current.localAddressInAccessorySubnet = localAddressInAccessorySubnet
        current.networkProtocolName = transaction.networkProtocolName
        current.reusedConnection = transaction.isReusedConnection
        current.proxyConnection = transaction.isProxyConnection
        lock.unlock()
    }

    private static func durationMilliseconds(
        from start: Date?,
        to end: Date?
    ) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}

nonisolated enum DeviceTransferSecurityPolicy {
    static func normalizedTransferToken(_ value: String) -> String? {
        guard value.utf8.count == 32,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }
        return value
    }

    static func normalizedCertificateSHA256(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    static func isSecureBaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host?.isEmpty == false &&
            url.user == nil &&
            url.password == nil &&
            url.query == nil &&
            url.fragment == nil &&
            (url.path.isEmpty || url.path == "/")
    }

    static func validate(
        baseURL: URL,
        certificateSHA256: String,
        identityVersion: UInt32,
        transferGeneration: UInt32,
        secureTransferV1: Bool
    ) -> Bool {
        isSecureBaseURL(baseURL) &&
            normalizedCertificateSHA256(certificateSHA256) != nil &&
            identityVersion > 0 &&
            transferGeneration > 0 &&
            secureTransferV1
    }

    static func evaluate(
        challenge: URLAuthenticationChallenge,
        expectedHost: String,
        certificateSHA256: String
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let evaluation = evaluateWithOutcome(
            challenge: challenge,
            expectedHost: expectedHost,
            certificateSHA256: certificateSHA256
        )
        return (evaluation.disposition, evaluation.credential)
    }

    static func evaluateWithOutcome(
        challenge: URLAuthenticationChallenge,
        expectedHost: String,
        certificateSHA256: String
    ) -> DeviceTransferTLSChallengeEvaluation {
        guard challenge.protectionSpace.authenticationMethod ==
                NSURLAuthenticationMethodServerTrust else {
            return DeviceTransferTLSChallengeEvaluation(
                disposition: .performDefaultHandling,
                credential: nil,
                outcome: .defaultHandling
            )
        }
        guard challenge.protectionSpace.host.caseInsensitiveCompare(
                expectedHost
              ) == .orderedSame else {
            return DeviceTransferTLSChallengeEvaluation(
                disposition: .cancelAuthenticationChallenge,
                credential: nil,
                outcome: .hostMismatch
            )
        }
        guard let expected = normalizedCertificateSHA256(
                certificateSHA256
              ) else {
            return DeviceTransferTLSChallengeEvaluation(
                disposition: .cancelAuthenticationChallenge,
                credential: nil,
                outcome: .invalidExpectedFingerprint
            )
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return DeviceTransferTLSChallengeEvaluation(
                disposition: .cancelAuthenticationChallenge,
                credential: nil,
                outcome: .missingServerTrust
            )
        }
        let certificate = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: certificate)
            .map { String(format: "%02x", $0) }
            .joined()
        guard constantTimeEqual(actual, expected) else {
            return DeviceTransferTLSChallengeEvaluation(
                disposition: .cancelAuthenticationChallenge,
                credential: nil,
                outcome: .certificateMismatch
            )
        }
        return DeviceTransferTLSChallengeEvaluation(
            disposition: .useCredential,
            credential: URLCredential(trust: trust),
            outcome: .accepted
        )
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        let count = max(leftBytes.count, rightBytes.count)
        var difference = leftBytes.count ^ rightBytes.count
        for index in 0..<count {
            let leftByte = index < leftBytes.count ? leftBytes[index] : 0
            let rightByte = index < rightBytes.count ? rightBytes[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

final class DeviceTransferPinnedSessionDelegate: NSObject,
                                                 URLSessionTaskDelegate,
                                                 @unchecked Sendable {
    private let expectedHost: String
    private let expectedPort: Int
    private let certificateSHA256: String
    private let diagnostics: DeviceTransferPinnedSessionDiagnostics?

    init?(
        baseURL: URL,
        certificateSHA256: String,
        diagnostics: DeviceTransferPinnedSessionDiagnostics? = nil
    ) {
        guard DeviceTransferSecurityPolicy.isSecureBaseURL(baseURL),
              let expectedHost = baseURL.host,
              let certificateSHA256 = DeviceTransferSecurityPolicy
                .normalizedCertificateSHA256(certificateSHA256) else {
            return nil
        }
        self.expectedHost = expectedHost
        self.expectedPort = baseURL.port ?? 443
        self.certificateSHA256 = certificateSHA256
        self.diagnostics = diagnostics
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        complete(challenge: challenge, with: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        complete(challenge: challenge, with: completionHandler)
    }

    private func complete(
        challenge: URLAuthenticationChallenge,
        with completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        let result = DeviceTransferSecurityPolicy.evaluateWithOutcome(
            challenge: challenge,
            expectedHost: expectedHost,
            certificateSHA256: certificateSHA256
        )
        // This deliberately records only the classification. Certificate
        // fingerprints, transfer tokens, hotspot credentials, and trust
        // objects never enter the log.
        diagnostics?.record(challenge: result.outcome)
        print("Device transfer TLS challenge: \(result.outcome.rawValue)")
        completionHandler(result.disposition, result.credential)
    }

    func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        diagnostics?.recordWaitingForConnectivity()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        diagnostics?.record(
            metrics: metrics,
            expectedHost: expectedHost,
            expectedPort: expectedPort
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated enum DeviceTransferPinnedSessionFactory {
    static func make(
        configuration: URLSessionConfiguration,
        baseURL: URL,
        certificateSHA256: String,
        diagnostics: DeviceTransferPinnedSessionDiagnostics? = nil
    ) -> URLSession? {
        guard let delegate = DeviceTransferPinnedSessionDelegate(
            baseURL: baseURL,
            certificateSHA256: certificateSHA256,
            diagnostics: diagnostics
        ) else {
            return nil
        }
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }
}
