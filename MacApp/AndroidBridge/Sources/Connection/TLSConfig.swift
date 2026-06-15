import Foundation
import Network
import Security
import CryptoKit
import os

enum TLSConfig {
    private static let logger = Logger(subsystem: "com.androidbridge.mac", category: "TLS")

    static func createTLSParameters(
        pairedFingerprint: String?,
        queue: DispatchQueue
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )

        sec_protocol_options_append_tls_ciphersuite(
            tlsOptions.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(0x1302))! // TLS_AES_256_GCM_SHA384
        )

        if let fingerprint = pairedFingerprint {
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { metadata, trust, completionHandler in
                    verifyCertificate(metadata: metadata, trust: trust, expectedFingerprint: fingerprint, completion: completionHandler)
                },
                queue
            )
        }

        let identity = loadOrCreateIdentity()
        if let identity {
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                identity
            )
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.connectionTimeout = 5

        return NWParameters(tls: tlsOptions, tcp: tcpOptions)
    }

    private static func verifyCertificate(
        metadata: sec_protocol_metadata_t,
        trust: sec_trust_t,
        expectedFingerprint: String,
        completion: @escaping (Bool) -> Void
    ) {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        SecTrustEvaluateAsyncWithError(secTrust, DispatchQueue.global()) { _, result, error in
            // For self-signed certs, we don't rely on system trust evaluation
            // Instead, we verify the certificate fingerprint matches our paired device

            if let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
               let leaf = certChain.first {
                let certData = SecCertificateCopyData(leaf) as Data
                let hash = SHA256.hash(data: certData)
                let fingerprint = hash.map { String(format: "%02x", $0) }.joined()

                if fingerprint == expectedFingerprint {
                    logger.info("Certificate fingerprint verified")
                    completion(true)
                    return
                } else {
                    logger.error("Certificate fingerprint mismatch — rejecting connection")
                }
            }

            completion(false)
        }
    }

    private static func loadOrCreateIdentity() -> sec_identity_t? {
        let tag = "com.androidbridge.mac.tls"

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: tag,
            kSecReturnRef as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let identity = result {
            return sec_identity_create(identity as! SecIdentity)
        }

        logger.info("No TLS identity found — connection will use anonymous TLS until pairing completes")
        return nil
    }
}
