import test from "node:test";
import assert from "node:assert/strict";
import { handleEbayToken } from "../lib/ebayToken.mjs";

const env = { EBAY_SANDBOX_APP_ID: "sbx-app", EBAY_SANDBOX_CERT_ID: "sbx-cert", EBAY_SANDBOX_RUNAME: "Name-SBX-ru", EBAY_PRODUCTION_APP_ID: "prd-app", EBAY_PRODUCTION_CERT_ID: "prd-cert", EBAY_PRODUCTION_RUNAME: "Name-PRD-ru" };
const ok = (json, status = 200) => async (url, init) => { ok.calls.push({ url, init }); return { ok: status < 300, status, json: async () => json }; };
ok.calls = [];
const call = (body, fetchImpl, e = env, method = "POST") => handleEbayToken({ method, body, env: e, fetchImpl });
test.beforeEach(() => { ok.calls = []; });

test("exchanges a code using the server's keys and redirect name, in the right environment", async () => {
  const result = await call({ environment: "sandbox", grant: "authorization_code", code: "v^1.1#abc" }, ok({ access_token: "A", expires_in: 7200, refresh_token: "R", refresh_token_expires_in: 47304000, token_type: "User Access Token", extra: "dropped" }));
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { access_token: "A", expires_in: 7200, refresh_token: "R", refresh_token_expires_in: 47304000, token_type: "User Access Token" });
  const { url, init } = ok.calls[0];
  assert.equal(url, "https://api.sandbox.ebay.com/identity/v1/oauth2/token");
  assert.equal(init.headers.Authorization, "Basic " + Buffer.from("sbx-app:sbx-cert").toString("base64"));
  assert.equal(init.body, "grant_type=authorization_code&code=v%5E1.1%23abc&redirect_uri=Name-SBX-ru");
});

test("production uses the production keys and host", async () => {
  await call({ environment: "production", grant: "refresh_token", refreshToken: "RT" }, ok({ access_token: "A", expires_in: 7200 }));
  assert.equal(ok.calls[0].url, "https://api.ebay.com/identity/v1/oauth2/token");
  assert.equal(ok.calls[0].init.headers.Authorization, "Basic " + Buffer.from("prd-app:prd-cert").toString("base64"));
  assert.equal(ok.calls[0].init.body, "grant_type=refresh_token&refresh_token=RT");
});

test("a caller cannot choose the redirect name", async () => {
  await call({ environment: "sandbox", grant: "authorization_code", code: "c", redirect_uri: "https://evil.example", ruName: "evil" }, ok({ access_token: "A" }));
  assert.match(ok.calls[0].init.body, /redirect_uri=Name-SBX-ru$/);
});

test("application tokens are refused unless the server enables them", async () => {
  const result = await call({ environment: "sandbox", grant: "client_credentials" }, ok({ access_token: "APP" }));
  assert.equal(result.status, 403); assert.equal(result.body.error, "forbidden");
  assert.equal(ok.calls.length, 0, "eBay is never contacted");
});

test("client credentials returns an application token with the public scope once enabled", async () => {
  const result = await call({ environment: "sandbox", grant: "client_credentials" }, ok({ access_token: "APP", expires_in: 7200, token_type: "Application Access Token" }), { ...env, EBAY_ALLOW_APP_TOKENS: "true" });
  assert.equal(result.body.access_token, "APP");
  assert.equal(ok.calls[0].init.body, "grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope");
});

test("rejects bad requests without calling eBay", async () => {
  for (const [body, status] of [[null, 400], [{ environment: "staging", grant: "refresh_token", refreshToken: "x" }, 400], [{ environment: "sandbox", grant: "password" }, 400],
    [{ environment: "sandbox", grant: "authorization_code" }, 400], [{ environment: "sandbox", grant: "refresh_token", refreshToken: "x".repeat(5000) }, 400]]) {
    assert.equal((await call(body, ok({}))).status, status);
  }
  assert.equal((await call({ environment: "sandbox", grant: "refresh_token", refreshToken: "x" }, ok({}), env, "GET")).status, 405);
  assert.equal(ok.calls.length, 0);
});

test("reports a missing server configuration without revealing anything", async () => {
  const result = await call({ environment: "sandbox", grant: "refresh_token", refreshToken: "x" }, ok({}), { EBAY_SANDBOX_APP_ID: "only-app" });
  assert.equal(result.status, 500); assert.equal(result.body.error, "server_not_configured");
  assert.equal((await call({ environment: "sandbox", grant: "authorization_code", code: "c" }, ok({}), { EBAY_SANDBOX_APP_ID: "a", EBAY_SANDBOX_CERT_ID: "c" })).body.error, "server_not_configured");
});

test("passes eBay's errors through and never echoes secrets", async () => {
  const result = await call({ environment: "sandbox", grant: "refresh_token", refreshToken: "x" }, ok({ error: "invalid_grant", error_description: "expired", secret: "no" }, 400));
  assert.equal(result.status, 400); assert.deepEqual(result.body, { error: "invalid_grant", error_description: "expired" });
  assert.ok(!JSON.stringify(result).includes("sbx-cert"));
});

test("maps network and parse failures to 502", async () => {
  const enabled = { ...env, EBAY_ALLOW_APP_TOKENS: "true" };
  assert.equal((await call({ environment: "sandbox", grant: "client_credentials" }, async () => { throw new Error("offline"); }, enabled)).status, 502);
  assert.equal((await call({ environment: "sandbox", grant: "client_credentials" }, async () => ({ ok: true, status: 200, json: async () => { throw new Error("bad json"); } }), enabled)).status, 502);
});
