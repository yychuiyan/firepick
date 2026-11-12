import FirepickBridge
import Foundation
import Security

final class AppPersistence {
    private enum Key {
        static let configurationBaseURL = "configurationBaseURL"
        static let selectedSiteKey = "selectedSiteKey"
        static let simulatorBridgeCredentials = "simulatorBridgeCredentials"
    }

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let directory: URL
    private let configurationURL: URL

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directory = support.appending(path: "Firepick", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        configurationURL = directory.appending(path: "configuration.json")
    }

    var configurationData: Data? {
        try? Data(contentsOf: configurationURL)
    }

    var configurationBaseURL: URL? {
        defaults.string(forKey: Key.configurationBaseURL).flatMap(URL.init(string:))
    }

    var selectedSiteKey: String? {
        defaults.string(forKey: Key.selectedSiteKey)
    }

    func saveConfiguration(_ data: Data, baseURL: URL?) throws {
        try data.write(to: configurationURL, options: .atomic)
        if let baseURL {
            defaults.set(baseURL.absoluteString, forKey: Key.configurationBaseURL)
        } else {
            defaults.removeObject(forKey: Key.configurationBaseURL)
        }
    }

    func clearConfiguration() {
        try? fileManager.removeItem(at: configurationURL)
        defaults.removeObject(forKey: Key.configurationBaseURL)
        defaults.removeObject(forKey: Key.selectedSiteKey)
    }

    func saveSelectedSiteKey(_ key: String?) {
        if let key {
            defaults.set(key, forKey: Key.selectedSiteKey)
        } else {
            defaults.removeObject(forKey: Key.selectedSiteKey)
        }
    }

    func loadBridgeCredentials() throws -> BridgeCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecMissingEntitlement {
#if targetEnvironment(simulator)
            guard let data = defaults.data(forKey: Key.simulatorBridgeCredentials) else {
                return nil
            }
            return try JSONDecoder().decode(BridgeCredentials.self, from: data)
#endif
        }
        guard status == errSecSuccess, let data = result as? Data else {
            NSLog("Firepick Keychain read failed: %d", status)
            throw PersistenceError.keychain(status)
        }
        return try JSONDecoder().decode(BridgeCredentials.self, from: data)
    }

    func saveBridgeCredentials(_ credentials: BridgeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
#if targetEnvironment(simulator)
            defaults.set(data, forKey: Key.simulatorBridgeCredentials)
            return
#endif
        }
        guard status == errSecSuccess else {
            NSLog("Firepick Keychain write failed: %d", status)
            throw PersistenceError.keychain(status)
        }
    }

    func clearBridgeCredentials() {
        SecItemDelete(baseQuery as CFDictionary)
        defaults.removeObject(forKey: Key.simulatorBridgeCredentials)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.firepick.app.bridge",
            kSecAttrAccount as String: "default",
        ]
    }
}

enum PersistenceError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "无法访问钥匙串（\(status)）"
        }
    }
}
