import { getStore } from "@netlify/blobs";
import { handleEbayToken } from "../../lib/ebayToken.mjs";
import { createLimiter } from "../../lib/rateLimit.mjs";

// POST https://<your-site>/api/ebay-token
export default async (request) => {
  const text = await request.text();
  if (text.length > 8000) return json(413, { error: "invalid_request", error_description: "Request too large." });
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { /* handled below as an invalid body */ }

  const store = getStore("app-token-limits");
  const limiter = createLimiter({
    get: (key) => store.get(key, { type: "json" }),
    set: (key, value) => store.setJSON(key, value),
  }, { perKeyPerHour: Number(process.env.EBAY_APP_TOKENS_PER_INSTALL_PER_HOUR) || 20, globalPerHour: Number(process.env.EBAY_APP_TOKENS_PER_HOUR) || 600 });

  const result = await handleEbayToken({ method: request.method, body, env: process.env, installKey: request.headers.get("x-sellpilot-install"), limiter });
  return json(result.status, result.body, result.retryAfterSeconds ? { "Retry-After": String(result.retryAfterSeconds) } : {});
};

const json = (status, payload, extra = {}) => new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extra } });

export const config = { path: "/api/ebay-token" };
