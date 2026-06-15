import Foundation
import os

/// Stores small non-secret identifiers (device IDs, paired-device IDs, cert
/// fingerprints) in UserDefaults rather than the macOS Keychain.
///
/// The app is ad-hoc signed and rebuilt frequently, so every launch macOS
/// treated the binary as "new" and prompted for Keychain access — once per item,
/// which is why the user saw 4–5 password prompts on every start. These values
/// are identifiers/public fingerprints, not secrets, so UserDefaults is the
/// appropriate (and prompt-free) place for them.
enum KeychainHelper {
    private static let logger = Logger(subsystem: "com.androidbridge.mac", category: "Storage")
    private static let defaults = UserDefaults.standard
    private static let prefix = "abridge_secure_"

    static func save(key: String, value: String) {
        defaults.set(value, forKey: prefix + key)
    }

    static func load(key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    static func delete(key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}
