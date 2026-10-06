# SellPilot — Milestone 1

A native SwiftUI selling assistant for casual sellers. iOS 17+, Xcode 15+; validated with Xcode 26.6 and the iOS 26.5 simulator. No API keys, accounts, network services, or third-party dependencies are required.

## Run

Open `SellPilot.xcodeproj`, select the **SellPilot** scheme and an iPhone simulator, and Run. For a physical iPhone, choose your development team in Signing & Capabilities. Camera capture requires an actual camera; the simulator supports Photos import and an explicitly labeled demo photo.

Tap **Sell Something**, add 1–10 photos, analyze, confirm/edit the sample identification, add a typed or dictated note, review the market snapshot, select a price and marketplaces, review simulated photo styles, and generate listings. Edit and export each listing. Confirm you posted the item externally to mark Active. Open it from Home or My Stuff to record its sold price.

## Implemented

- Home with a prominent selling action, Active/Sold/Draft counts, recorded sales, and recent items.
- Camera and multi-photo library import, cover selection, reorder, delete, and optional photo guidance. Originals retained byte-for-byte; separate resized previews for display. 100 MB aggregate original-photo limit per item.
- Structured mock identification, honest confidence labeling, alternate matches, editable product details and condition.
- Typed notes and native Speech/AVAudioEngine dictation with permission handling and graceful typed fallback.
- Separate active asking and sold comparable lists, sold range and medians, with clear simulated-data labeling.
- Three equally presented pricing strategies, a custom asking price, ranked marketplace suggestions, and overrides.
- Per-photo Original/Clean/Studio/Lifestyle simulated presentation; no product retouching. Export retains original images.
- Separate listing templates for eBay, local marketplaces, Mercari, and additional marketplaces. Title, description, price, category, condition, tags, item specifics, shipping/pickup notes, and photo order are editable.
- Clipboard actions, original-photo sharing, and listing-package export (text + JSON + ordered original image files, through the native share sheet).
- Explicit mock eBay publish receipt, external-publication confirmation, and Draft/Ready/Active/Sold/Archived tracking.
- SwiftData autosave between steps and while editing, resumable drafts, on-disk store reopening, and surfaced storage failures.

## Architecture and folders

```
SellPilot/
  App/              App entry and local dependency composition
  Models/           Codable typed domain records and enums
  Persistence/      SwiftData StoredSellItem + ItemStore
  Services/         Protocols, injected mocks, selling workflow, media and export
  Features/         Home/My Stuff, capture, confirm, notes, research, pricing,
                    marketplace choices, photo review, editable listings
  Components/       Reusable cards, buttons, photo and item presentation
SellPilotTests/     Domain, export, validation, full workflow, disk-reopen tests
SellPilotUITests/   Simulator selling flow and relaunch test
```

`SellingWorkflow` owns async transitions, validation, dependent result regeneration, and state changes. Views render and edit its domain item. `AppServices` accepts replacement protocol implementations; no AI provider appears in the views. `ItemStore` owns SwiftData fetch/save and rollback on errors. `ListingExportService` prepares files only; native sharing handles the destination.

### Data model

`SellItem` contains identity/timestamps, product details and condition, notes/confidence, status, selected marketplaces, strategy/asking/sold prices and sold date, cover/order, identification, photos, comparables, recommendations, generated drafts, and the resume step. `SellItemPhoto` preserves original data plus a normalized preview and simulated `PhotoEnhancement`. Related typed records include `ProductIdentification`, `ProductMatch`, `MarketComparable`, `PricingRecommendation`, `MarketplaceRecommendation`, and `ListingDraft`.

One SwiftData `@Model` record stores each complete Codable aggregate using external binary storage and an indexed unique item ID. This deliberately avoids a complex relationship graph for an MVP. Schema evolution and more granular photo storage/querying should be addressed before production or large datasets. Corrupt/incompatible payloads report a load failure rather than deleting saved data.

### Service contracts

| Protocol | Responsibility |
| --- | --- |
| ProductIdentificationService | Photos → structured identification and alternatives |
| MarketResearchService | Confirmed item → distinct active/sold comparables |
| PricingAnalysisService | Item + comparables → strategies, medians, range, rationale |
| MarketplaceRecommendationService | Item → ranked fit, shipping, fee considerations |
| PhotoEnhancementService | Original photo + style → preview metadata |
| ListingGenerationService | Item + marketplace → marketplace-specific editable draft |
| MarketplacePublishingService | Validate, prepare, mock publish, update, mark sold, delist |

Each has a mock implementation and async/throwing boundaries where appropriate. Publishing returns an explicit mock receipt. A mock publish or export never marks an item Active automatically.

## Limitations

Identification is a deterministic DEWALT fixture regardless of photo content. The user must verify/edit it. Research and recommendations are generated fixtures, not observed sales or demand; confidence is illustrative. Prices are estimates from mock inputs, with no guaranteed outcome. Image styles change preview framing/background only; background removal, cropping, studio/lifestyle generation, and exposure correction are deferred. Original images are exported even if a simulated style is selected.

The export package consists of separate shareable files, not a zip archive. Delivery depends on installed share destinations. Speech availability depends on device/language/connectivity and system permissions. No production posting, marketplace status synchronization, delisting, sold-state verification, authentication, cloud sync, accounting, shipping labels, payments, or subscriptions. Data is local to the device. Archived items remain viewable. Editing local Active copy does not update an external listing.

Device camera, speech permissions, and actual share destinations require physical-device validation. iOS 17 deployment is configured, but the available test runtime is iOS 26.5. A device signing team and production app icons/App Store assets are still needed for distribution.

## Build and test

```sh
xcodebuild -project SellPilot.xcodeproj -scheme SellPilot -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath output/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SellPilot.xcodeproj -scheme SellPilot -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath output/DerivedData CODE_SIGNING_ALLOWED=NO test
```

`generate_project.py` regenerates the dependency-free Xcode project and shared scheme when source files are added; the committed/generated project opens directly in Xcode without running Python.

## Milestone 2 proposal — not implemented

Start with a production identification service with OCR/model-label extraction, uncertain-match handling, and consent/error behavior. Add licensed live asking and sold-data sources with timestamps and provenance, then marketplace-specific pricing that accounts for fees/shipping. Introduce production listing generation with factual claim validation and background-only enhancement that preserves defects and originals. Validate every enhancement against the source before accepting it.

Then implement official eBay authentication, listing field mapping, draft validation, and explicit publication consent; retain guided manual Facebook publishing. Add stale-listing and price-drop suggestions after reliable listing status exists. Introduce StoreKit subscriptions/credits only once usage cost and the under-60-second workflow have been measured. Prioritize physical-device testing, accessibility/Dynamic Type, model migration, photo storage performance, and failure/retry coverage before an App Store release.

### Verified result — October 4, 2026

Simulator compilation and all **5 tests passed** (4 unit tests, 1 UI test), with zero failures. The UI test confirms identification editing, research, pricing, marketplace selection, listing generation, explicit Active confirmation, recording a $91 sale, and persisted Sold state after relaunch. It uses an isolated store. The disk-reopen unit test verifies persisted original-photo data, notes, research, pricing, and listings. Final result bundle: `output/VerifiedTests.xcresult`; captured screens: `Docs/home.png` and `Docs/listing-ready.png`.

A separate empty preview store is launched in the iPhone 17 Pro simulator. Physical-device camera/dictation and share destinations remain unverified. The under-60-second target has not been measured with real user photos.
