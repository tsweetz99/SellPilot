#!/usr/bin/env python3
"""Check eBay Production keys against the Browse API without exposing them.

    SELLPILOT_EBAY_APP_ID=... SELLPILOT_EBAY_CERT_ID=... python3 scripts/ebay_check.py "dewalt dcf887"

Prints status codes and a few listings. Never prints the keys or the access token.
Uses the system `curl` (which trusts the macOS keychain) instead of Python's own TLS stack, and passes
credentials to it on stdin so they never appear in the process list.
"""
import base64, json, os, subprocess, sys, urllib.parse

app, cert = os.environ.get("SELLPILOT_EBAY_APP_ID"), os.environ.get("SELLPILOT_EBAY_CERT_ID")
if not app or not cert:
    sys.exit("Set SELLPILOT_EBAY_APP_ID and SELLPILOT_EBAY_CERT_ID in the environment first.")
query = " ".join(sys.argv[1:]) or "dewalt dcf887"

def call(url, headers, data=None):
    config = [f'url = "{url}"', 'silent', 'show-error', 'max-time = 30', 'write-out = "\\n%{http_code}"']
    config += [f'header = "{h}"' for h in headers]
    if data: config.append(f'data = "{data}"')
    result = subprocess.run(["curl", "--config", "-"], input="\n".join(config), capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"curl failed: {result.stderr.strip()}")
    body, _, status = result.stdout.rpartition("\n")
    try: parsed = json.loads(body or "{}")
    except ValueError: parsed = {}
    return int(status), parsed

basic = base64.b64encode(f"{app}:{cert}".encode()).decode()
status, body = call("https://api.ebay.com/identity/v1/oauth2/token",
    [f"Authorization: Basic {basic}", "Content-Type: application/x-www-form-urlencoded"],
    "grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope")
print(f"1. Token request: HTTP {status}")
if status != 200:
    sys.exit(f"   {body.get('error_description') or body}\n   Check you used the PRODUCTION App ID and Cert ID.")

url = "https://api.ebay.com/buy/browse/v1/item_summary/search?" + urllib.parse.urlencode(
    {"q": query, "limit": 20, "filter": "buyingOptions:{FIXED_PRICE},priceCurrency:USD,conditionIds:{3000}"})
status, body = call(url, [f"Authorization: Bearer {body['access_token']}", "X-EBAY-C-MARKETPLACE-ID: EBAY_US"])
print(f"2. Search '{query}': HTTP {status}")
if status != 200:
    sys.exit(f"   {json.dumps(body.get('errors', body))[:400]}")
items = body.get("itemSummaries", [])
print(f"   {len(items)} used fixed-price listings (of {body.get('total')} total)")
for item in items[:5]:
    print(f"   ${item['price']['value']:>8}  {item['title'][:70]}")
