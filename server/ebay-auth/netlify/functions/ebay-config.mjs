import { handleEbayConfig } from "../../lib/ebayConfig.mjs";

// GET https://<your-site>/api/ebay-config
export default async (request) => {
  const result = handleEbayConfig({ method: request.method, env: process.env });
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    // Short cache so a corrected value reaches the app quickly.
    headers: { "Content-Type": "application/json", "Cache-Control": result.status === 200 ? "public, max-age=300" : "no-store" },
  });
};

export const config = { path: "/api/ebay-config" };
