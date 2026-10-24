// The two public values the app needs to start "Sign in with eBay": the Production App ID (client ID) and the redirect name (RuName).
// Neither is a secret: both appear in the sign-in address eBay shows. The Cert ID (the secret) is never returned. Serving them from
// here means the app has nothing to type in and they can change without an app update.

const reply = (status, body) => ({ status, body });

/** @param {{method: string, env: Record<string, string|undefined>}} request */
export function handleEbayConfig({ method, env }) {
  if (method !== "GET") return reply(405, { error: "method_not_allowed", message: "Use GET." });
  const appID = (env.EBAY_PRODUCTION_APP_ID ?? "").trim(), ruName = (env.EBAY_PRODUCTION_RUNAME ?? "").trim();
  if (!appID || !ruName) return reply(503, { error: "not_configured", message: "eBay sign-in is not set up on the server yet." });
  // A Sandbox ID in the Production variable would send every seller to a sign-in page that cannot work.
  if (!appID.toUpperCase().includes("-PRD-")) return reply(500, { error: "misconfigured", message: "The server's eBay App ID is not a Production ID." });
  return reply(200, { production: { appID, ruName } });
}
