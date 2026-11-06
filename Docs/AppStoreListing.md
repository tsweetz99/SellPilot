# App Store listing: SellPilot 1.0

Copy for App Store Connect. Each field shows its limit; `python3 scripts/check_app_store_listing.py` checks them.
It describes the app as it is today: the studio-hosted AI service is live, publishing to eBay is built in and off by default,
the bundle identifier is `com.tidewrightstudios.sellpilot`, and the released version is 1.0 (build 4); the next update, 1.0.1 (build 5), adds App Attest. Re-read it against the app
before pasting if anything changes.

## Fields

### Name (limit 30)
```text
SellPilot: Photo to Listing
```

### Subtitle (limit 30)
```text
Price it, list it, sell it
```

### Promotional text (limit 170)
```text
Snap a few photos and get a suggested title, price and ready-to-post listing. Publish to eBay or export it anywhere. Less typing, fewer guesses.
```

### Description (limit 4000)
```text
Selling what you no longer need shouldn't take an hour of typing, searching and guessing. SellPilot turns a few photos into a priced, ready-to-post listing.

PHOTOGRAPH IT
Take photos with the camera or pick them from your library. SellPilot reads labels and model numbers to suggest a title, brand, model and condition. You always review and correct the details before anything is used.

PRICE IT WITH REAL DATA
See comparable active listings and a suggested price range, with the listings behind each number. Choose a quick-sale, recommended or top-dollar price, or set your own.

BOOKS BY BARCODE
Include a book's barcode in a photo and SellPilot reads the ISBN on your phone, then fills in the title, author and publisher.

PUBLISH OR EXPORT
Publish straight to your eBay seller account after a final review that shows the price, condition, category and your shipping, payment and return policies. Or copy and export the listing for any other marketplace. You can end an eBay listing from the app.

FREE TO TRY
Your first 5 photo analyses are free. After that, choose SellPilot Plus (60 analyses a month) or buy a pack of 25. Entering details yourself, price research and exporting listings are always free.

YOURS TO KEEP
Your items and photos are stored on your phone. There are no accounts, no ads and no tracking. Back up everything to Files or iCloud Drive and restore it any time.

GOOD TO KNOW
- Identification and prices are suggestions. AI can be wrong, so check every detail.
- Prices reflect what similar items are currently asking, which is not the same as what they sell for.
- Publishing to eBay needs an eBay seller account with business policies set up. Real eBay listings are off until you turn them on.
- Photos you choose to analyze are processed by an AI service to identify the item. See the privacy policy for details.
- Designed for large text sizes, VoiceOver and dark mode.

eBay is a trademark of eBay Inc. SellPilot is made by Tidewright Studios and is not affiliated with or endorsed by eBay.

Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://tidewrightstudios.com/sellpilot/privacy/
```

### Keywords (limit 100)
```text
resell,reseller,price,flip,thrift,garage sale,sell used,inventory,isbn,barcode,declutter,secondhand
```

### What's New (limit 4000)
```text
First release.
```

### Copyright
```text
2026 Sweetz Holdings LLC
```

## Settings

| Field | Value |
|---|---|
| Primary category | Shopping |
| Secondary category | Productivity |
| Price | Free to download, with in-app purchases (see Pricing) |
| Support URL | https://tidewrightstudios.com/sellpilot/support/ |
| Marketing URL | https://tidewrightstudios.com/sellpilot/ |
| Privacy policy URL | https://tidewrightstudios.com/sellpilot/privacy/ |
| Age rating | 4+ expected (no objectionable content; answer every questionnaire item "None"). Confirm in the questionnaire. |
| Sign-in required | No |

"eBay" appears in the description only, to say what the app connects to, with the trademark line above. It is deliberately
left out of the name, subtitle and keywords, because Apple can reject listings that use another company's mark there.

## Pricing and in-app purchases

The app is free to download. Photo analysis runs on the studio's AI account, so it is paid for like this (the server counts it; see
`server/ebay-auth/README.md`):

| Product | Type | Price | Id |
|---|---|---|---|
| SellPilot Plus Monthly | Auto-renewable subscription | $4.99 | `com.tidewrightstudios.sellpilot.plus.monthly` |
| SellPilot Plus Yearly | Auto-renewable subscription | $34.99 | `com.tidewrightstudios.sellpilot.plus.yearly` |
| 25 analyses | Consumable | $2.99 | `com.tidewrightstudios.sellpilot.analyses.25` |

Both subscriptions go in one group, "SellPilot Plus", with Yearly ranked above Monthly. Each gives 60 analyses per 30 days.
Everyone gets 5 free analyses once per install; manual entry, price research and export are always free. At about 3 to 6 cents
per analysis (an estimate: check the Anthropic console), 60 analyses cost at most about $3.60 against about $4.24 after Apple's
15% Small Business Program fee on the monthly plan.

Apple needs, for each product: a display name, a description and a review screenshot (the plans screen), plus the Paid
Applications Agreement with bank and tax details. The subscriptions need the privacy policy link and Terms of Use link, which
the plans screen and the listing already show (Apple's standard terms: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).

## App Privacy ("nutrition label")

Answers follow what the app does today and match the privacy manifest inside the app (`SellPilot/PrivacyInfo.xcprivacy`), which a
test keeps in step. Confirm each against Apple's definitions when filling in the form.

| Data type | Collected? | Linked to the user? | Tracking? | Purpose |
|---|---|---|---|---|
| Photos or Videos | Yes, sent to the AI service for identification | No | No | App functionality |
| Other User Content (item descriptions) | Yes, sent with the photos | No | No | App functionality |
| Identifiers | A random install code used to limit abuse. Likely "Device ID" or "Other identifiers" | No | No | App functionality |
| Everything else (contacts, location, health, purchases, browsing, diagnostics, usage) | No | n/a | n/a | n/a |

Notes:
- With purchases, the AI service also receives Apple's signed transaction (product and transaction numbers, no name or payment
  details) to check a subscription or add a pack, and keeps counts against the install code. Apple's form may call that "Purchases"
  (Purchase History), not linked to the user, for App Functionality. Decide before publishing the privacy answers, and update the
  privacy policy page to match.
- The AI service passes photos and descriptions to Anthropic's Claude and keeps nothing: no photos, descriptions or answers are
  stored, and its logs hold counts only. Apple's guidance can treat data that is processed but not retained as not collected;
  the safer choice, and what the manifest does, is to declare it as above.
- The hosting provider (Netlify) keeps ordinary server logs such as IP address and time. If Apple's form asks about that, declare
  it under Identifiers or Diagnostics, not linked to the user, for App Functionality (security and abuse limits).
- eBay sign-in goes to eBay; SellPilot stores the tokens only in the phone's Keychain.
- Declare "Data Not Used to Track You" for every row: there is no advertising or analytics.

## Notes for App Review

```text
SellPilot helps people turn photos of items they want to sell into a priced listing.

No account or sign-in is needed to review the app. From Home, tap "Sell Something", then "Try with a labeled demo photo", then "Analyze photos". The first time, the app asks permission to send photos to its AI service (SellPilot's service, which uses Anthropic's Claude); tap "Allow and analyze". Continue through the steps to the Ready screen. Photo identification needs an internet connection. If you prefer not to allow it, tap "I'll enter the details myself" and the rest of the flow works the same.

Photo analysis includes 5 free analyses, then SellPilot Plus or a pack. To test a purchase, use a Sandbox Apple ID: open Settings (from Home), tap "See plans" and buy any plan. Purchases are verified by SellPilot's service. Restore purchases is on the same screen. Nothing in the app requires a purchase to review it: "I'll enter the details myself" works at any point.

Publishing to eBay is optional and off by default. It needs a real eBay seller account, so reviewers do not need it. To see the screens without publishing, stop at "Ready".

Camera and microphone access are requested only when the user adds a photo with the camera or starts dictating a note. Speech recognition is used for optional dictation.

Support: https://tidewrightstudios.com/sellpilot/support/
```

## Screenshots

Required: 6.9-inch iPhone (1320 x 2868). Apple scales them down for smaller phones. Use real-looking items, not the
built-in "DEMO PHOTO" placeholder. Suggested set, in order:

1. Photograph: "Snap a few photos" (item photos on the capture screen)
2. Confirm: "Check what it found" (suggested title, brand, condition)
3. Price & places: "Price it with real data" (the three price options)
4. Ready: "A listing, ready to post" (generated listing)
5. Books: "Books by barcode" (ISBN lookup filled in)
6. Backup/Settings: "Yours to keep" (backup and privacy)

### Capturing them

The captures come from a UI test that runs the debug-only sample data (`--screenshot-demo`; none of it is in Release builds)
on the iPhone 17 Pro Max simulator (exactly 1320 x 2868). The photos stay out of git (`Screenshots/` is ignored):
put JPEGs named `skates-1`...`skates-6`, `lights-1`, `book-1`...`book-3` in `Screenshots/demo/`, then

```
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3
TEST_RUNNER_SELLPILOT_DEMO_PHOTOS=$PWD/Screenshots/demo TEST_RUNNER_SELLPILOT_SCREENSHOT_DIR=$PWD/Screenshots/appstore \
  xcodebuild test -project SellPilot.xcodeproj -scheme SellPilot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:SellPilotUITests/ScreenshotUITests
```

The files are `01-photograph` to `06-settings` (the set above) plus `00-home`. Prices, comparables and the book lookup in them are sample data.

## Status before submitting

**Done**
- iPhone only for 1.0 (no iPad screenshots needed; iPad would need layout testing first).
- The App Store Connect record exists (SellPilot: Photo to Listing, bundle `com.tidewrightstudios.sellpilot`).
- Hosted AI service live, with spending limits and an off switch; consent prompt and Settings switch in the app.
- Real bundle identifier (`com.tidewrightstudios.sellpilot`), version 1.0 (build 4); 1.0.1 (build 5) is the update with App Attest.
- App icon, privacy manifest, export-compliance setting (HTTPS only), usage descriptions.
- eBay setup built in; publishing off by default; developer fields only in debug builds.
- Backup and restore; accessibility audits (default size, largest size, dark mode).
- Public privacy policy, support page and product page on tidewrightstudios.com.

**Still to do**
0. **Paywall launch steps.** In App Store Connect: sign the Paid Applications Agreement (bank and tax), create the subscription group and
   the three products above with their prices, names, descriptions and a plans-screen review screenshot. Deploy the server (merging to
   main redeploys Netlify). Then buy each product with a Sandbox Apple ID in TestFlight and check: the plans screen shows the prices,
   a subscription raises the allowance to 60, a pack adds 25, Restore purchases works, and a refunded or expired subscription stops
   counting. This is the one thing the tests cannot prove, because only Apple can sign a real transaction.
1. **App Store Connect record.** Create or confirm the app with this exact bundle identifier and a free name ("SellPilot: Photo to Listing" is not guaranteed to be available; names are first-come). Paste the fields above, the URLs, the age rating and the App Privacy answers.
2. **Screenshots** (6.9-inch, 1320 x 2868): see the plan above. They need real item photos.
3. **Archive and upload** a Release build from Xcode (Product, Archive), then add it to TestFlight.
4. **TestFlight** on two or three other phones: the AI consent prompt, eBay connect with someone else's account, backup and restore.
5. **App Attest** is built (app and server) but not released: see "App Attest" in `server/ebay-auth/README.md` for the rollout. It needs an app update after 1.0 (the build in review does not send proof), then `AI_ATTEST=on`, then `AI_REQUIRE_ATTEST=true`.
6. **Review the privacy policy** with someone qualified, and review eBay's API license terms before public release.
7. **Apple Developer account.** The studio site says the enrollment is under Sweetz Holdings LLC. Confirm it is active and, for a free app, that no paid-apps agreement is required.
