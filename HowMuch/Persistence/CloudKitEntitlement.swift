#if os(macOS)
import Security
#endif
import Foundation

enum CloudKitEntitlement {
    /// True when the running binary is signed with CloudKit iCloud services.
    /// `CKContainer(identifier:)` traps on macOS if this is missing.
    static var isPresent: Bool {
        #if os(macOS)
        macOSEntitlementPresent
        #else
        true
        #endif
    }

    #if os(macOS)
    private static var macOSEntitlementPresent: Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return false }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard copyStatus == errSecSuccess, let information else { return false }

        let dict = information as NSDictionary
        guard let entitlements = dict[kSecCodeInfoEntitlementsDict] as? [String: Any] else {
            return false
        }
        let services = entitlements["com.apple.developer.icloud-services"] as? [String]
        return services?.contains("CloudKit") == true
    }
    #endif
}
