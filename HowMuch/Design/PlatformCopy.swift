import Foundation

enum PlatformCopy {
    static var settingsName: String {
        #if os(macOS)
        String(localized: "System Settings", comment: "macOS settings app name")
        #else
        String(localized: "Settings", comment: "iOS settings app name")
        #endif
    }

    static var signInToICloud: String {
        String(
            localized: "Sign in to iCloud with your Apple Account in \(settingsName), then return to HowMuch.",
            comment: "Platform-correct iCloud sign-in guidance"
        )
    }

    static var localOnlyBuildDetail: String {
        #if os(macOS)
        String(localized: "This build keeps data on this Mac. Choose a Team in Xcode and enable CloudKit to turn on iCloud sync.")
        #else
        String(localized: "This build keeps data on this device. Choose a Team in Xcode and enable CloudKit to turn on iCloud sync.")
        #endif
    }

    static var signedOutLocalDetail: String {
        String(
            localized: "Data stays on this device. Sign in to iCloud to sync across your devices and share a family ledger.",
            comment: "Signed-out local data explanation"
        )
    }
}
