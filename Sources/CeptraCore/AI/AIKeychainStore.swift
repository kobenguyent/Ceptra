import Foundation
import Security

public protocol AISecretStore: Sendable {
    func saveSecret(_ secret: String, forProfileID profileID: UUID) throws
    func loadSecret(forProfileID profileID: UUID) -> String?
    func deleteSecret(forProfileID profileID: UUID) throws
    func hasSecret(forProfileID profileID: UUID) -> Bool
}

public extension AISecretStore {
    func hasSecret(forProfileID profileID: UUID) -> Bool {
        guard let value = loadSecret(forProfileID: profileID) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum AIKeychainError: LocalizedError, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case encodingFailure

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "macOS Keychain error (\(status)): \(message)"
            }
            return "macOS Keychain error (\(status))"
        case .encodingFailure:
            return "Failed to encode API key for macOS Keychain."
        }
    }
}

/// Production macOS Keychain store using `Security.framework`.
/// Secrets are restricted to this device after first unlock and never serialized to UserDefaults.
public final class MacOSKeychainSecretStore: AISecretStore, @unchecked Sendable {
    public static let defaultService = "com.kobenguyent.Ceptra.ai-providers"

    private let service: String

    public init(service: String = MacOSKeychainSecretStore.defaultService) {
        self.service = service
    }

    private func account(for profileID: UUID) -> String {
        "profile.\(profileID.uuidString)"
    }

    public func saveSecret(_ secret: String, forProfileID profileID: UUID) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteSecret(forProfileID: profileID)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw AIKeychainError.encodingFailure
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profileID)
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw AIKeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrLabel as String] = "Ceptra AI Provider Key"

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIKeychainError.unexpectedStatus(addStatus)
        }
    }

    public func loadSecret(forProfileID profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profileID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public func deleteSecret(forProfileID profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profileID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIKeychainError.unexpectedStatus(status)
        }
    }
}

/// Deterministic in-memory secret store for headless unit tests (zero macOS Keychain prompts).
public final class InMemoryAISecretStore: AISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    public init(initial: [UUID: String] = [:]) {
        self.storage = initial
    }

    public func saveSecret(_ secret: String, forProfileID profileID: UUID) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if trimmed.isEmpty {
                storage.removeValue(forKey: profileID)
            } else {
                storage[profileID] = trimmed
            }
        }
    }

    public func loadSecret(forProfileID profileID: UUID) -> String? {
        lock.withLock {
            storage[profileID]
        }
    }

    public func deleteSecret(forProfileID profileID: UUID) throws {
        _ = lock.withLock {
            storage.removeValue(forKey: profileID)
        }
    }
}
