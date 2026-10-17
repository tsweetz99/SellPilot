// Exchanges and refreshes eBay tokens on behalf of the SellPilot app, so the Cert ID (client secret) never ships in the app.
// Pure logic with an injectable fetch, so it can be tested without a network.

const HOSTS = { sandbox: "https://api.sandbox.ebay.com", production: "https://api.ebay.com" };
const APP_SCOPE = "https://api.ebay.com/oauth/api_scope";
const MAX_FIELD = 4000;

const reply = (status, body) => ({ status, body });
const fail = (status, error, description) => reply(status, { error, error_description: description });

function form(pairs) {
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

const INSTALL_KEY = /^[0-9a-f]{32,64}$/i;

/**
 * @param {{method: string, body: unknown, env: Record<string, string|undefined>, fetchImpl?: typeof fetch,
 *          installKey?: string|null, limiter?: {check(key: string): Promise<{allowed: boolean, retryAfterSeconds: number}>}}} request
 */
export async function handleEbayToken({ method, body, env, fetchImpl = fetch, installKey = null, limiter = null }) {
  if (method !== "POST") return fail(405, "method_not_allowed", "Use POST.");
  if (!body || typeof body !== "object") return fail(400, "invalid_request", "Send a JSON object.");

  const environment = body.environment;
  if (!(environment in HOSTS)) return fail(400, "invalid_request", "environment must be sandbox or production.");
  const prefix = environment === "sandbox" ? "EBAY_SANDBOX" : "EBAY_PRODUCTION";
  const appID = env[`${prefix}_APP_ID`], certID = env[`${prefix}_CERT_ID`], ruName = env[`${prefix}_RUNAME`];
  if (!appID || !certID) return fail(500, "server_not_configured", `The ${environment} eBay keys are not set on the server.`);

  let pairs;
  switch (body.grant) {
    case "authorization_code":
      if (typeof body.code !== "string" || !body.code || body.code.length > MAX_FIELD) return fail(400, "invalid_request", "code is required.");
      if (!ruName) return fail(500, "server_not_configured", `The ${environment} redirect name (RuName) is not set on the server.`);
      // The redirect name comes from the server's own settings, never from the caller.
      pairs = [["grant_type", "authorization_code"], ["code", body.code], ["redirect_uri", ruName]];
      break;
    case "refresh_token":
      if (typeof body.refreshToken !== "string" || !body.refreshToken || body.refreshToken.length > MAX_FIELD) return fail(400, "invalid_request", "refreshToken is required.");
      pairs = [["grant_type", "refresh_token"], ["refresh_token", body.refreshToken]];
      break;
    case "client_credentials":
      // An application token needs no seller login, so on a public address anyone could ask for one. Off unless explicitly enabled.
      if (env.EBAY_ALLOW_APP_TOKENS !== "true") return fail(403, "forbidden", "Application tokens are not enabled on this server.");
      // Each app install makes up a random key. It proves nothing about who is calling, but it gives every install its own
      // rate-limit bucket and lets a misbehaving one be blocked without affecting the others.
      if (typeof installKey !== "string" || !INSTALL_KEY.test(installKey)) return fail(401, "install_key_required", "Send this app's install key in the X-SellPilot-Install header.");
      if ((env.EBAY_BLOCKED_INSTALL_KEYS ?? "").split(",").map((k) => k.trim().toLowerCase()).includes(installKey.toLowerCase())) return fail(403, "forbidden", "This install is blocked.");
      if (!limiter) return fail(503, "limiter_unavailable", "Rate limiting is not available, so application tokens are paused.");
      try {
        const verdict = await limiter.check(installKey.toLowerCase());
        if (!verdict.allowed) return { status: 429, body: { error: "rate_limited", error_description: "Too many token requests. Try again later." }, retryAfterSeconds: verdict.retryAfterSeconds };
      } catch {
        // Failing closed: if the counts cannot be read, nobody gets an application token until they can.
        return fail(503, "limiter_unavailable", "Rate limiting is not available, so application tokens are paused.");
      }
      pairs = [["grant_type", "client_credentials"], ["scope", APP_SCOPE]];
      break;
    default:
      return fail(400, "invalid_request", "grant must be authorization_code, refresh_token or client_credentials.");
  }

  let upstream;
  try {
    upstream = await fetchImpl(`${HOSTS[environment]}/identity/v1/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${Buffer.from(`${appID}:${certID}`).toString("base64")}` },
      body: form(pairs),
    });
  } catch {
    return fail(502, "upstream_unreachable", "Could not reach eBay.");
  }

  let json;
  try { json = await upstream.json(); } catch { return fail(502, "upstream_invalid", "eBay returned an unreadable response."); }
  if (!upstream.ok) return reply(upstream.status, { error: json.error ?? "ebay_error", error_description: json.error_description ?? "eBay rejected the request." });
  // Only the fields the app needs, so nothing unexpected is ever relayed.
  const { access_token, expires_in, refresh_token, refresh_token_expires_in, token_type } = json;
  return reply(200, { access_token, expires_in, refresh_token, refresh_token_expires_in, token_type });
}
