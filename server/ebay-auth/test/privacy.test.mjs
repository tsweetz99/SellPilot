import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const page = readFileSync(new URL("../public/privacy/index.html", import.meta.url), "utf8");

test("the privacy page has no unfilled placeholders", () => {
  assert.equal(page.includes("{{"), false);
});

test("the privacy page names every service the app sends data to", () => {
  for (const name of ["Anthropic", "eBay", "Netlify", "Open Library", "Google Books", "Apple"]) assert.ok(page.includes(name), `${name} should be disclosed`);
});

test("the privacy page gives a contact and works under the site's strict content policy", () => {
  assert.match(page, /mailto:[^"@]+@[^"]+/);
  assert.equal(/<script|style=|<style/.test(page), false, "the site's CSP only allows files from the same origin");
});
