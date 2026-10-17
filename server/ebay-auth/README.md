# SellPilot: Sign in with eBay (web side)

Two small pieces the iPhone app needs for "Connect eBay":

1. **A bounce page** (`public/ebay/callback/`). eBay can only redirect a seller's browser to a web address. This page receives
   `?code=…&state=…` and immediately forwards it to the app through its `sellpilot://ebay/callback` link. It must be hosted on the web.
2. **A token function** (`netlify/functions/ebay-token.mjs`, served at `/api/ebay-token`). It exchanges the sign-in code for tokens and
   refreshes them, using the **Cert ID kept on the server**, so the secret never ships inside the app.

## Deploy (Netlify, free tier)

A separate site from your marketing site is recommended, so that site stays purely static.

1. Netlify → **Add new site → Import from Git** → pick the SellPilot repo.
2. **Base directory:** `server/ebay-auth` (the build settings come from `netlify.toml`; no build command needed).
3. **Site configuration → Environment variables**, add (Sandbox first; add the `EBAY_PRODUCTION_*` trio later):
   - `EBAY_SANDBOX_APP_ID` (the App ID / Client ID from the Sandbox keyset)
   - `EBAY_SANDBOX_CERT_ID` (the Cert ID / Client Secret)
   - `EBAY_SANDBOX_RUNAME` (the redirect name eBay generated, see below)
4. Note the site address, e.g. `https://sellpilot-auth.netlify.app`.

## eBay developer portal

Application Keys → **User Tokens (eBay Sign-In)** for the matching keyset → edit your redirect URL entry:

- **Your auth accepted URL:** `https://<your-site>/ebay/callback/`
- **Your auth declined URL:** `https://<your-site>/ebay/callback/` (eBay then sends `?error=access_denied`)
- **OAuth enabled:** on

Keep the generated **RuName**; the server needs it (`EBAY_SANDBOX_RUNAME`) and so does the app.

## In the app

Settings → **eBay Sandbox sign-in**: enter the RuName and the token server URL (`https://<your-site>/api/ebay-token`), save, then
**Connect eBay Sandbox account**. Sign in as a sandbox test seller. Tokens are stored in the Keychain and refreshed automatically.

Without a token server URL the app exchanges the code itself using the Cert ID saved on the device. That is only acceptable for your own
testing; the bounce page still has to be hosted either way.

## Notes

- `client_credentials` (application tokens for category lookup and comps) is supported but **off by default**, because the function's address is public and an application token needs no seller login. Set `EBAY_ALLOW_APP_TOKENS=true` only when the app is switched over to use it. Code exchange and refresh need a valid code or refresh token, so they are not open to abuse the same way.
- Quick health check that does not need that grant: send a refresh with a made-up token. `{"environment":"sandbox","grant":"refresh_token","refreshToken":"x"}` should answer `400 invalid_grant` (eBay accepted the server's keys and rejected the token). `401 invalid_client` means the keys are wrong; `500` means a variable is missing.
- The function only returns the token fields the app needs, never echoes keys, takes the redirect name from its own settings (not from
  the caller), and answers 4xx/5xx with eBay's error text only.
- Tests: `npm test` (Node 18+; no dependencies).
