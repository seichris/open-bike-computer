//
//  DeviceTransferSecurity.swift
//  BikeComputer
//
//  BLE-pinned TLS policy for the device-local transfer server.
//

import CryptoKit
import Foundation
import Security

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
        guard challenge.protectionSpace.authenticationMethod ==
                NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard challenge.protectionSpace.host.caseInsensitiveCompare(
                expectedHost
              ) == .orderedSame,
              let expected = normalizedCertificateSHA256(
                certificateSHA256
              ),
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let certificate = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: certificate)
            .map { String(format: "%02x", $0) }
            .joined()
        guard constantTimeEqual(actual, expected) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
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
    private let certificateSHA256: String

    init?(baseURL: URL, certificateSHA256: String) {
        guard DeviceTransferSecurityPolicy.isSecureBaseURL(baseURL),
              let expectedHost = baseURL.host,
              let certificateSHA256 = DeviceTransferSecurityPolicy
                .normalizedCertificateSHA256(certificateSHA256) else {
            return nil
        }
        self.expectedHost = expectedHost
        self.certificateSHA256 = certificateSHA256
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
        let result = DeviceTransferSecurityPolicy.evaluate(
            challenge: challenge,
            expectedHost: expectedHost,
            certificateSHA256: certificateSHA256
        )
        completionHandler(result.0, result.1)
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
        certificateSHA256: String
    ) -> URLSession? {
        guard let delegate = DeviceTransferPinnedSessionDelegate(
            baseURL: baseURL,
            certificateSHA256: certificateSHA256
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
