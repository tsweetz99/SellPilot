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

- **Application tokens** (`client_credentials`, used for category lookup and price comps) are **off by default**, because the address is public. To let the app get them from the server instead of holding a Cert ID, add these Netlify variables (scopes: Functions) and redeploy:
  - `EBAY_ALLOW_APP_TOKENS=true`
  - `EBAY_PRODUCTION_APP_ID` and `EBAY_PRODUCTION_CERT_ID` (comps use real eBay listings, so these are the **Production** keys)
  - optional: `EBAY_APP_TOKENS_PER_INSTALL_PER_HOUR` (default 20), `EBAY_APP_TOKENS_PER_HOUR` (default 600, across everyone), `EBAY_BLOCKED_INSTALL_KEYS` (comma-separated keys to refuse)
- **The install key.** Each app install makes up a random key (kept in its Keychain) and sends it as `X-SellPilot-Install`. It is not a login and proves nothing about who is calling; it gives every install its own hourly allowance and lets one misbehaving install be blocked. Counts are kept in Netlify Blobs, one record per key, so the store does not grow. If the counts cannot be read, application tokens pause (503) rather than being handed out unchecked.
- Code exchange and refresh do not need the install key: they need a valid code or refresh token.
- Quick health check that does not use any real token: a refresh with a made-up token should answer `400 invalid_grant`.
  `curl -s -X POST https://<site>/api/ebay-token -H 'content-type: application/json' -d '{"environment":"sandbox","grant":"refresh_token","refreshToken":"x"}'`
  - `401 invalid_client`: the keys are wrong. `500 server_not_configured`: a variable is missing.
- Application-token check (once enabled): same call with `"grant":"client_credentials"` and a header `-H 'X-SellPilot-Install: 0123456789abcdef0123456789abcdef'`. Expect `200` with an `access_token` (do not paste it anywhere); `403` means it is not enabled; `401` means the key header is missing or malformed; `429` means the hourly allowance is used up; `503` means the counter store is unavailable.
- The function only returns the token fields the app needs, never echoes keys, takes the redirect name from its own settings (not from
  the caller), and answers 4xx/5xx with eBay's error text only.
- Tests: `npm test` (Node 18+; no dependencies).
