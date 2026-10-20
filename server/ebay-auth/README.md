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

## Going live (real eBay)

Real listings use the **Production** keyset. In addition to the Sandbox setup above:

1. eBay developer portal → Application Keys → **Production** → User Tokens: edit the redirect URL entry so its accepted and declined URLs are `https://<your-site>/ebay/callback/`, with OAuth enabled (the same bounce page serves both). Note its **RuName**.
2. Netlify variables: `EBAY_PRODUCTION_RUNAME` (that RuName). `EBAY_PRODUCTION_APP_ID` and `EBAY_PRODUCTION_CERT_ID` are already there if app tokens are enabled. Redeploy.
3. In the app, see `Docs/GoingLive.md`.

## The AI service (`/api/ai`)

The same site also runs SellPilot's hosted AI, so people do not need their own Anthropic key. The app sends photos (or the
seller's own item description) to `POST /api/ai`; the function calls Claude on the studio's account and returns the answer.

**How it protects the account**
- **The server owns the instructions.** Callers send only `{"task":"identify","photos":[{"data":"<base64 JPEG>"}]}` or
  `{"task":"facts","description":"..."}`. The prompt, tool, model and token limit are fixed in `lib/aiPrompts.mjs` and `lib/ai.mjs`, so
  the endpoint cannot be used as a general-purpose Claude proxy. A test in the app's suite fails if the app's copy of the
  instructions and this one drift apart.
- **Three spending allowances**, counted in units (an identification costs 3, a fact lookup 1) and checked together, with the
  counts kept in Netlify Blobs: per install per day, per network address per hour, and one for the whole service per day. The
  whole-service one is the cap on your bill. If the counts cannot be read, nothing is spent (503).
- **An off switch.** Nothing runs unless `AI_ENABLED=true`. Set it to anything else and every call answers "paused".
- **Photos are checked** before anything is spent: at most 6, JPEG only, 1.2 MB each and 3.5 MB together (Netlify allows a 6 MB
  request body and 60 seconds per call; neither can be raised).
- **Nothing is stored or logged** except counts: `{"event":"ai","task":"identify","status":200,"photos":2,"ms":4100}`. No photos,
  descriptions, answers or keys. A test checks this.

**Setup (Site configuration → Environment variables, then redeploy)**

| Variable | Needed | Meaning |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes | The studio's key. Mark it as a secret value. Never paste it into chat or commit it. |
| `AI_ENABLED` | yes | `true` to switch the service on. |
| `AI_UNITS_PER_DAY` | no (1500) | Whole-service daily cap. 1500 is about 500 identifications a day. **This is your spending dial.** |
| `AI_UNITS_PER_INSTALL_PER_DAY` | no (60) | About 20 identifications per install per day. |
| `AI_UNITS_PER_ADDRESS_PER_HOUR` | no (90) | Per network address, so inventing install codes does not help. |
| `AI_MODEL_IDENTIFY` / `AI_MODEL_FACTS` | no | Defaults `claude-sonnet-5-5` and `claude-haiku-4-5-20251001`. |
| `AI_TIMEOUT_MS` | no (45000) | Stay under Netlify's 60 seconds. |
| `AI_BLOCKED_INSTALL_KEYS` | no | Comma-separated install codes to refuse. |

Also set a **monthly spend limit** in the Anthropic console (Settings, then Limits). The daily cap bounds the worst case; the
console limit is the backstop.

**Checking it works** (uses one real identification; the script never prints the key):

```bash
python3 scripts/ai_check.py ~/Pictures/some-item.jpg
```

Expected: `200` and a title, brand and category. `503 "paused"` means `AI_ENABLED` is not `true` or the key is missing; `429` means an
allowance is used up; `422` means Claude rejected the photo.

**Not in this version:** proof that a request comes from a genuine SellPilot (Apple App Attest). The install code and the address
and global allowances limit the damage a script can do, but they do not stop one. Add App Attest before the app is widely
used or if the service-wide cap is ever hit by traffic that is not real.
