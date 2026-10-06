# Validation

Date: October 4, 2026. Xcode 26.6, iOS 26.5 Simulator, iPhone 17 Pro.

- Simulator app and both test targets compile.
- `testCompleteWorkflowAndRelaunch`: passed. Exercises all service transitions, preserved photo source, distinct marketplace copy and disclosed defect notes, mock receipt without automatic Active state, actual sale recording, and complete aggregate reopening from a disk-backed SwiftData store.
- `testEmptyCaptureDoesNotAdvance`: passed.
- `testExportOrderAndValidation`: passed. Cover order reflected in exported image files; negative price rejected.
- `testPricingUsesSoldSalesSeparatelyFromAsking`: passed. Tests an even sold median independently of a much higher active asking price.
- `testCreatePublishAndPersistItem`: passed. Real SwiftUI screen flow, product title editing, publication confirmation, relaunch, sold-price entry, and another relaunch. No remaining Active card after the sale. Isolated test store.

Final XCTest result: `output/VerifiedTests.xcresult`. Five tests, zero failures. Xcode's informational AppIntents metadata warning is unrelated to this app; there are no Swift source warnings in the final run.

Screenshots of Home and Listing Ready were inspected for clipping and hierarchy. Device camera capture, system dictation permissions, actual share destinations, iOS 17 runtime behavior, and accessibility with larger text/VoiceOver require further hands-on validation. The speed goal remains a product target, not a measured performance claim.
