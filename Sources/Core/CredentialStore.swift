import Foundation
import Security

enum CredentialStore {
    private static let service = "cn.local.WiFiSync.camera"
    static func save(_ credentials: HotspotCredentials, cameraID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: cameraID]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw SyncError.message("无法将相机凭据保存到钥匙串") }
        } else if status != errSecSuccess { throw SyncError.message("无法更新相机钥匙串凭据") }
    }
    static func load(cameraID: String) -> HotspotCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: cameraID, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(HotspotCredentials.self, from: data)
    }
    static var identifier: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "pairingIdentifier") { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: "pairingIdentifier"); return id
    }
}
