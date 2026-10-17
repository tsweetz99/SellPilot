import { handleEbayToken } from "../../lib/ebayToken.mjs";

// POST https://<your-site>/api/ebay-token
export default async (request) => {
  const text = await request.text();
  if (text.length > 8000) return json(413, { error: "invalid_request", error_description: "Request too large." });
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { /* handled below as an invalid body */ }
  const { status, body: payload } = await handleEbayToken({ method: request.method, body, env: process.env });
  return json(status, payload);
};

const json = (status, payload) => new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

export const config = { path: "/api/ebay-token" };
