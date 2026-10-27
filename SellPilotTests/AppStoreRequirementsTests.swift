import XCTest
@testable import SellPilot

/// Things App Store Connect checks at upload, so a mistake shows up here instead of as a rejected build.
final class AppStoreRequirementsTests: XCTestCase {
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "the privacy manifest must be inside the app")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    func testThePrivacyManifestDeclaresNoTrackingAndTheOneRequiredReasonAPIUsed() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        let apis = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.count, 1)
        XCTAssertEqual(apis[0]["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(apis[0]["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"], "UserDefaults read only by the app itself")
    }

    func testTheManifestMatchesWhatTheAppSendsAndTheListingSays() throws {
        let collected = try XCTUnwrap(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }),
                       ["NSPrivacyCollectedDataTypePhotosorVideos", "NSPrivacyCollectedDataTypeOtherUserContent", "NSPrivacyCollectedDataTypeDeviceID"])
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false); XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }

    func testTheAppSaysItUsesOnlyExemptEncryptionSoUploadsSkipThePrompt() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false, "HTTPS only")
    }

    func testIdentifierAndVersionAreTheFinalOnes() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.tidewrightstudios.sellpilot")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0")
    }

    func testTheAppDeclaresEveryUsageDescriptionItNeeds() {
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").isEmpty, key)
        }
    }
}
