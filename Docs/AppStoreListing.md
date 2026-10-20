# App Store listing: SellPilot 1.0

Draft copy for App Store Connect. Each field shows its limit; `python3 scripts/check_app_store_listing.py` checks them.
Anything marked **[needs hosted AI]** describes a feature that works only once the studio-hosted AI service exists (see
"Before you submit"). Do not submit copy that promises it until then.

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

YOURS TO KEEP
Your items and photos are stored on your phone. There are no accounts, no ads and no tracking. Back up everything to Files or iCloud Drive and restore it any time.

GOOD TO KNOW
- Identification and prices are suggestions. AI can be wrong, so check every detail.
- Prices reflect what similar items are currently asking, which is not the same as what they sell for.
- Publishing to eBay needs an eBay seller account with business policies set up. Real eBay listings are off until you turn them on.
- Photos you choose to analyze are processed by an AI service to identify the item. See the privacy policy for details.
- Designed for large text sizes, VoiceOver and dark mode.

eBay is a trademark of eBay Inc. SellPilot is made by Tidewright Studios and is not affiliated with or endorsed by eBay.
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
| Price | Free |
| Support URL | https://tidewrightstudios.com/sellpilot/support/ |
| Marketing URL | https://tidewrightstudios.com/sellpilot/ |
| Privacy policy URL | https://tidewrightstudios.com/sellpilot/privacy/ |
| Age rating | 4+ expected (no objectionable content; answer every questionnaire item "None"). Confirm in the questionnaire. |
| Sign-in required | No |

"eBay" appears in the description only, to say what the app connects to, with the trademark line above. It is deliberately
left out of the name, subtitle and keywords, because Apple can reject listings that use another company's mark there.

## App Privacy ("nutrition label")

Answers are for the hosted-AI version and follow what the app does today. Confirm each against Apple's definitions when
filling in the form; the right answer depends on whether the AI service keeps anything.

| Data type | Collected? | Linked to the user? | Tracking? | Purpose |
|---|---|---|---|---|
| Photos or Videos | Yes, sent to the AI service for identification **[needs hosted AI]** | No | No | App functionality |
| Other User Content (item descriptions) | Yes, sent with the photos **[needs hosted AI]** | No | No | App functionality |
| Identifiers | A random install code used to limit abuse. Likely "Device ID" or "Other identifiers" | No | No | App functionality |
| Everything else (contacts, location, health, purchases, browsing, diagnostics, usage) | No | n/a | n/a | n/a |

Notes:
- If the hosted AI service forwards photos to the model and keeps nothing, Apple's guidance can treat that as data that is
  processed but not collected. If it stores anything, even briefly in logs, declare it as above.
- eBay sign-in goes to eBay; SellPilot stores the tokens only in the phone's Keychain.
- Declare "Data Not Used to Track You" for every row: there is no advertising or analytics.

## Notes for App Review

```text
SellPilot helps people turn photos of items they want to sell into a priced listing.

No account or sign-in is needed to review the app. From Home, tap "Sell Something", then "Try with a labeled demo photo", then "Analyze photos" and continue through the steps to the Ready screen. Photo identification uses an AI service and needs an internet connection.

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

## Before you submit

1. **Hosted AI service [blocking].** The app currently needs each user's own Anthropic key. For a free public app, build the
   service the studio will run: it receives the photos, calls Claude, applies per-install limits and returns the result.
   Then update the privacy policy and support page, and the App Privacy answers above.
2. **Bundle identifier [blocking, permanent].** The project uses the placeholder `com.sellpilot.sellpilot`. Pick the real one
   (for example `com.tidewrightstudios.sellpilot`) before the first upload; it cannot change after the app exists in App Store Connect.
3. **Version.** The project says 0.1. Set the marketing version to 1.0 and a build number.
4. **Name availability.** Check that "SellPilot: Photo to Listing" is free in App Store Connect; names are first-come.
5. **Apple Developer account.** The studio site says the enrollment is under Sweetz Holdings LLC. Confirm the account is active
   and the paid-apps and tax forms are not needed for a free app.
6. **Review the privacy policy** with someone qualified, and review eBay's API license terms.
7. **TestFlight** on two or three other phones.
