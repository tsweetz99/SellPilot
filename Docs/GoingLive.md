# Going live: publishing real eBay listings

Live publishing is **off by default**. Until it is switched on, SellPilot publishes only to the eBay Sandbox.

## What the seller needs on eBay
- An eBay seller account in good standing, with **managed payments** and **business policies** set up (shipping, payment and returns). SellPilot never creates or invents these for a real seller; it lists the seller's own and lets them pick.
- A sign-in through SellPilot's **Production** connection (below).

## One-time setup
1. **eBay developer portal** (Production keyset, User Tokens): set the redirect URL's accepted and declined addresses to the bounce page (`https://<your-site>/ebay/callback/`), OAuth on. Copy its RuName.
2. **Netlify**: add `EBAY_PRODUCTION_RUNAME`, redeploy (see `server/ebay-auth/README.md`).
3. **App > Settings**
   - *eBay market data*: save the **Production App ID** (the Cert ID is not needed when a token server is configured).
   - *Real eBay (live listings)*: save the **Production RuName** and your **ship-from ZIP code**, tap **Connect eBay account**, and sign in as the real seller.
   - Turn on **Publish to real eBay** (it stays disabled until the ZIP is saved and the account is connected).

## What the app does before anything goes live
- The Ready screen names every missing setting instead of hiding the section.
- The seller picks the eBay category, fills the required item specifics, and chooses their shipping, payment and return policies.
- The condition is mapped to one the category accepts (books, for example, have no "Used - Excellent"); if none fits, publishing stops and says what is accepted.
- A review step shows title, price, condition, photos, category and policies, and states plainly that the listing is real and may incur eBay fees. Only the red **Publish live listing** button sends it.
- After publishing, the item is marked Active and **End listing** withdraws it.

## Data rules
eBay's API License Agreement restricts using eBay Content for machine learning and feeding it to outside AI tools. SellPilot therefore:
- matches comparable listings to the item with plain title rules on the device;
- sends Claude only the seller's own description (to extract facts such as voltage or color), never eBay listing titles, categories or allowed values; matching to eBay's item specifics happens on the device.

Review the current agreement before release: https://developer.ebay.com/join/api-license-agreement
