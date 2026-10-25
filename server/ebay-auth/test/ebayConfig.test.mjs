import test from "node:test";
import assert from "node:assert/strict";
import { handleEbayConfig } from "../lib/ebayConfig.mjs";

const env = { EBAY_PRODUCTION_APP_ID: "Studio-SellPilo-PRD-abc123-def456", EBAY_PRODUCTION_RUNAME: "Studio-SellPilo-StudioS-xyz", EBAY_PRODUCTION_CERT_ID: "PRD-secret-cert-id", EBAY_SANDBOX_APP_ID: "Studio-SellPilo-SBX-aaa-bbb" };

test("returns the production App ID and redirect name, and nothing else", () => {
  const result = handleEbayConfig({ method: "GET", env });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { production: { appID: "Studio-SellPilo-PRD-abc123-def456", ruName: "Studio-SellPilo-StudioS-xyz" } });
  const text = JSON.stringify(result);
  assert.ok(!text.includes("secret") && !text.includes("SBX"), "never the Cert ID or sandbox values");
});

test("values are trimmed", () => {
  const result = handleEbayConfig({ method: "GET", env: { ...env, EBAY_PRODUCTION_APP_ID: "  Studio-PRD-1  ", EBAY_PRODUCTION_RUNAME: "ru\n" } });
  assert.deepEqual(result.body.production, { appID: "Studio-PRD-1", ruName: "ru" });
});

test("says so when sign-in is not set up", () => {
  for (const missing of [{}, { EBAY_PRODUCTION_APP_ID: env.EBAY_PRODUCTION_APP_ID }, { EBAY_PRODUCTION_RUNAME: "x" }, { EBAY_PRODUCTION_APP_ID: " ", EBAY_PRODUCTION_RUNAME: "x" }]) {
    const result = handleEbayConfig({ method: "GET", env: missing });
    assert.equal(result.status, 503); assert.equal(result.body.error, "not_configured");
  }
});

test("refuses a Sandbox App ID in the Production variable", () => {
  const result = handleEbayConfig({ method: "GET", env: { ...env, EBAY_PRODUCTION_APP_ID: env.EBAY_SANDBOX_APP_ID } });
  assert.equal(result.status, 500); assert.equal(result.body.error, "misconfigured");
  assert.ok(!JSON.stringify(result).includes("SBX"));
});

test("only GET is accepted", () => {
  assert.equal(handleEbayConfig({ method: "POST", env }).status, 405);
});
