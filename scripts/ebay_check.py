#!/usr/bin/env python3
"""Check eBay Production keys against the Browse API without exposing them.

    SELLPILOT_EBAY_APP_ID=... SELLPILOT_EBAY_CERT_ID=... python3 scripts/ebay_check.py "dewalt dcf887"

Prints status codes and a few listings. Never prints the keys or the access token.
"""
import base64, json, os, sys, urllib.error, urllib.parse, urllib.request

app, cert = os.environ.get("SELLPILOT_EBAY_APP_ID"), os.environ.get("SELLPILOT_EBAY_CERT_ID")
if not app or not cert:
    sys.exit("Set SELLPILOT_EBAY_APP_ID and SELLPILOT_EBAY_CERT_ID in the environment first.")
query = " ".join(sys.argv[1:]) or "dewalt dcf887"

def call(request):
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try: body = json.loads(error.read() or b"{}")
        except ValueError: body = {}
        return error.code, body

basic = base64.b64encode(f"{app}:{cert}".encode()).decode()
status, body = call(urllib.request.Request(
    "https://api.ebay.com/identity/v1/oauth2/token",
    data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": "https://api.ebay.com/oauth/api_scope"}).encode(),
    headers={"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"}))
print(f"1. Token request: HTTP {status}")
if status != 200:
    sys.exit(f"   {body.get('error_description') or body}\n   Check you used the PRODUCTION App ID and Cert ID.")

url = "https://api.ebay.com/buy/browse/v1/item_summary/search?" + urllib.parse.urlencode(
    {"q": query, "limit": 20, "filter": "buyingOptions:{FIXED_PRICE},priceCurrency:USD,conditionIds:{3000}"})
status, body = call(urllib.request.Request(url, headers={"Authorization": f"Bearer {body['access_token']}", "X-EBAY-C-MARKETPLACE-ID": "EBAY_US"}))
print(f"2. Search '{query}': HTTP {status}")
if status != 200:
    sys.exit(f"   {json.dumps(body.get('errors', body))[:400]}")
items = body.get("itemSummaries", [])
print(f"   {len(items)} used fixed-price listings (of {body.get('total')} total)")
for item in items[:5]:
    print(f"   ${item['price']['value']:>8}  {item['title'][:70]}")
