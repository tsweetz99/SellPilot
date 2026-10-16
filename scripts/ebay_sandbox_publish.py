#!/usr/bin/env python3
"""Walk the whole eBay *sandbox* listing flow, to verify the API calls SellPilot will make.

    export SELLPILOT_EBAY_SANDBOX_APP_ID=...    # Sandbox App ID (client ID, contains SBX)
    export SELLPILOT_EBAY_SANDBOX_CERT_ID=...   # Sandbox Cert ID
    export SELLPILOT_EBAY_SANDBOX_USER_TOKEN=...  # Sandbox seller user access token (scopes: sell.inventory, sell.account)
    python3 scripts/ebay_sandbox_publish.py [--category-id ID] [--cleanup]

Steps: category lookup -> required item specifics -> business-policy opt-in -> policies -> inventory location ->
photo upload -> inventory item -> offer -> publish. Prints each step's HTTP status and what eBay said.
Never prints the keys or tokens. Uses system curl so macOS keychain certificates are trusted.
It only talks to api.sandbox.ebay.com / apim.sandbox.ebay.com and creates a TEST listing in the sandbox.
"""
import base64, json, os, struct, subprocess, sys, tempfile, time, urllib.parse, zlib

API, MEDIA = "https://api.sandbox.ebay.com", "https://apim.sandbox.ebay.com"
app, cert = os.environ.get("SELLPILOT_EBAY_SANDBOX_APP_ID"), os.environ.get("SELLPILOT_EBAY_SANDBOX_CERT_ID")
user = os.environ.get("SELLPILOT_EBAY_SANDBOX_USER_TOKEN")
if not (app and cert and user):
    sys.exit("Set SELLPILOT_EBAY_SANDBOX_APP_ID, SELLPILOT_EBAY_SANDBOX_CERT_ID and SELLPILOT_EBAY_SANDBOX_USER_TOKEN first.")
if "SBX" not in app.upper():
    sys.exit("This App ID doesn't look like a Sandbox key (no SBX). This script must never run against Production.")
args = sys.argv[1:]
category_override = args[args.index("--category-id") + 1] if "--category-id" in args else None
cleanup = "--cleanup" in args
stamp = str(int(time.time()))
SKU, LOCATION = f"SELLPILOT-TEST-{stamp}", "SELLPILOT_HOME"

def call(method, url, token, body=None, form=None, headers=()):
    """Returns (status, response headers dict, parsed JSON or {}). Credentials go to curl on stdin."""
    dump, payload = tempfile.mkstemp(), None
    config = [f'url = "{url}"', f'request = "{method}"', "silent", "show-error", "max-time = 60", f'dump-header = "{dump[1]}"', 'write-out = "\\n%{http_code}"']
    config += [f'header = "{h}"' for h in ((f"Authorization: Bearer {token}",) if token else ()) + tuple(headers)]
    if body is not None:
        payload = tempfile.mkstemp(); os.write(payload[0], json.dumps(body).encode()); os.close(payload[0])
        config += ['header = "Content-Type: application/json"', 'header = "Content-Language: en-US"', f'data-binary = "@{payload[1]}"']
    if body is None and not form and method in ("POST", "PUT"):
        # eBay's edge rejects body-less POSTs (publish, withdraw) with 411, so send an explicit empty body.
        config += ['header = "Content-Type: application/json"', 'data = ""']
    if form: config.append(f'form = "{form}"')
    try:
        out = subprocess.run(["curl", "--config", "-"], input="\n".join(config), capture_output=True, text=True)
        if out.returncode != 0: sys.exit(f"curl failed: {out.stderr.strip()}")
        text, _, status = out.stdout.rpartition("\n")
        raw = open(dump[1]).read().replace("\r", "").strip().split("\n\n")[-1]
        hdrs = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in raw.split("\n")[1:] if ":" in l}
        try: parsed = json.loads(text) if text.strip() else {}
        except ValueError: parsed = {"raw": text[:300]}
        return int(status), hdrs, parsed
    finally:
        os.close(dump[0]); os.remove(dump[1])
        if payload: os.remove(payload[1])

def errors(body):
    items = body.get("errors") or body.get("warnings") or []
    return "; ".join(f"[{e.get('errorId')}] {e.get('message')}" + (f" ({', '.join(str(p.get('value')) for p in e.get('parameters', []))})" if e.get("parameters") else "") for e in items[:3]) or json.dumps(body)[:300]

def step(n, title): print(f"\n{n}. {title}")
def fail(msg): sys.exit(f"   STOPPED: {msg}")

# --- app token (for Taxonomy)
basic = base64.b64encode(f"{app}:{cert}".encode()).decode()
cfg = ['url = "%s/identity/v1/oauth2/token"' % API, "silent", "show-error", 'write-out = "\\n%{http_code}"', f'header = "Authorization: Basic {basic}"',
       'header = "Content-Type: application/x-www-form-urlencoded"', 'data = "grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope"']
out = subprocess.run(["curl", "--config", "-"], input="\n".join(cfg), capture_output=True, text=True)
text, _, code = out.stdout.rpartition("\n")
step(0, f"Sandbox application token: HTTP {code}")
if code != "200": fail("Sandbox App ID / Cert ID rejected. Use the SANDBOX keyset.")
app_token = json.loads(text)["access_token"]

# --- 1. category
step(1, "Category suggestion (Taxonomy)")
category = category_override
if not category:
    status, _, body = call("GET", f"{API}/commerce/taxonomy/v1/category_tree/0/get_category_suggestions?" + urllib.parse.urlencode({"q": "cordless impact driver"}), app_token)
    print(f"   HTTP {status}")
    suggestions = body.get("categorySuggestions", [])
    for s in suggestions[:3]: print(f"   {s['category']['categoryId']:>8}  {s['category']['categoryName']}")
    if not suggestions: fail("No suggestions from the sandbox. Re-run with --category-id <a leaf category id>.")
    category = suggestions[0]["category"]["categoryId"]
print(f"   using category {category}")

# --- 2. required aspects
step(2, "Required item specifics for that category")
status, _, body = call("GET", f"{API}/commerce/taxonomy/v1/category_tree/0/get_item_aspects_for_category?category_id={category}", app_token)
print(f"   HTTP {status}")
aspects = {}
for a in body.get("aspects", []):
    if a.get("aspectConstraint", {}).get("aspectRequired"):
        name, values = a["localizedAspectName"], [v["localizedValue"] for v in a.get("aspectValues", [])]
        aspects[name] = "DEWALT" if name == "Brand" else "DCF887B" if name in ("Model", "MPN") else (values[0] if values else "Does not apply")
print("   required:", ", ".join(aspects) or "(none)")
aspects.setdefault("Brand", "DEWALT")

# --- 3. business policies opt-in
step(3, "Opt in to business policies (Account API)")
status, _, body = call("POST", f"{API}/sell/account/v1/program/opt_in", user, {"programType": "SELLING_POLICY_MANAGEMENT"})
already = any(e.get("errorId") == 25804 for e in body.get("errors", []))   # eBay answers 409/25804 when already opted in
print(f"   HTTP {status}" + ("  (already opted in, fine)" if already else "" if status in (200, 204) else f"  {errors(body)}"))

# --- 4. policies
step(4, "Fulfillment, payment and return policies")
ids = {}
kinds = {"fulfillment_policy": ("fulfillmentPolicies", "fulfillmentPolicyId"), "payment_policy": ("paymentPolicies", "paymentPolicyId"), "return_policy": ("returnPolicies", "returnPolicyId")}
category_types = [{"name": "ALL_EXCLUDING_MOTORS_VEHICLES", "default": True}]
creators = {
    "fulfillment_policy": {"name": f"SellPilot shipping {stamp}", "marketplaceId": "EBAY_US", "categoryTypes": category_types, "handlingTime": {"value": 3, "unit": "DAY"},
        "shippingOptions": [{"optionType": "DOMESTIC", "costType": "FLAT_RATE", "shippingServices": [{"sortOrder": 1, "shippingCarrierCode": "USPS", "shippingServiceCode": "USPSPriority", "freeShipping": False, "shippingCost": {"value": "8.00", "currency": "USD"}}]}]},
    "payment_policy": {"name": f"SellPilot payment {stamp}", "marketplaceId": "EBAY_US", "categoryTypes": category_types},
    "return_policy": {"name": f"SellPilot returns {stamp}", "marketplaceId": "EBAY_US", "categoryTypes": category_types, "returnsAccepted": False},
}
for kind, (listKey, idKey) in kinds.items():
    status, _, body = call("GET", f"{API}/sell/account/v1/{kind}?marketplace_id=EBAY_US", user)
    existing = body.get(listKey, []) if status == 200 else []
    if existing: ids[idKey] = existing[0][idKey]; print(f"   {kind}: using existing ({len(existing)} found)"); continue
    status, _, body = call("POST", f"{API}/sell/account/v1/{kind}", user, creators[kind])
    if status in (200, 201) and idKey in body: ids[idKey] = body[idKey]; print(f"   {kind}: created (HTTP {status})")
    else: fail(f"{kind}: HTTP {status} {errors(body)}")

# --- 5. location
step(5, "Inventory location")
status, _, body = call("GET", f"{API}/sell/inventory/v1/location/{LOCATION}", user)
if status == 200:
    print("   HTTP 200  (already exists, fine)")
else:
    status, _, body = call("POST", f"{API}/sell/inventory/v1/location/{LOCATION}", user,
        {"location": {"address": {"city": "San Jose", "stateOrProvince": "CA", "postalCode": "95125", "country": "US"}}, "locationTypes": ["WAREHOUSE"], "name": "SellPilot test location", "merchantLocationStatus": "ENABLED"})
    exists = any(e.get("errorId") == 25803 for e in body.get("errors", []))   # 400/25803: merchantLocationKey already exists
    print(f"   HTTP {status}" + ("  (already exists, fine)" if exists else "" if status in (200, 201, 204) else f"  {errors(body)}"))
    if status not in (200, 201, 204) and not exists: fail("could not create a location")

# --- 6. photo
step(6, "Upload a photo (Media API)")
def png(size=800):
    row = b"\x00" + bytes([40, 120, 90]) * size
    raw = b"".join(row for _ in range(size))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
image = tempfile.NamedTemporaryFile(suffix=".png", delete=False); image.write(png()); image.close()
status, hdrs, body = call("POST", f"{MEDIA}/commerce/media/v1_beta/image/create_image_from_file", user, form=f"image=@{image.name}")
os.remove(image.name)
print(f"   HTTP {status}  location: {hdrs.get('location', '(none)')}" + ("" if status in (200, 201) else f"  {errors(body)}"))
image_url = None
if status in (200, 201) and hdrs.get("location"):
    status, _, body = call("GET", hdrs["location"].replace("https://apim.ebay.com", MEDIA), user)
    image_url = body.get("imageUrl"); print(f"   get image: HTTP {status}  imageUrl: {image_url}")
if not image_url: fail("no hosted image URL; publishing needs one. Check the Media API output above.")

# --- 7. inventory item
step(7, "Create inventory item")
status, _, body = call("PUT", f"{API}/sell/inventory/v1/inventory_item/{SKU}", user, {
    "availability": {"shipToLocationAvailability": {"quantity": 1}}, "condition": "USED_EXCELLENT", "conditionDescription": "Sandbox test item.",
    "product": {"title": "SellPilot sandbox test: DEWALT DCF887B impact driver (tool only)", "description": "Sandbox test listing created by SellPilot.", "aspects": {k: [v] for k, v in aspects.items()}, "imageUrls": [image_url]}})
print(f"   HTTP {status}" + ("" if status in (200, 204) else f"  {errors(body)}"))
if status not in (200, 204): fail("inventory item rejected")

# --- 8. offer
step(8, "Create offer")
status, _, body = call("POST", f"{API}/sell/inventory/v1/offer", user, {
    "sku": SKU, "marketplaceId": "EBAY_US", "format": "FIXED_PRICE", "availableQuantity": 1, "categoryId": str(category), "merchantLocationKey": LOCATION,
    "listingDescription": "<p>Sandbox test listing created by SellPilot.</p>", "pricingSummary": {"price": {"value": "49.99", "currency": "USD"}}, "listingPolicies": ids})
offer = body.get("offerId")
print(f"   HTTP {status}  offerId: {offer}" + ("" if offer else f"  {errors(body)}"))
if not offer: fail("offer rejected")

# --- 9. publish
step(9, "Publish offer")
status, _, body = call("POST", f"{API}/sell/inventory/v1/offer/{offer}/publish", user)
listing = body.get("listingId")
print(f"   HTTP {status}  listingId: {listing}" + ("" if listing else f"  {errors(body)}"))
if listing: print(f"   View: https://sandbox.ebay.com/itm/{listing}")
if cleanup and listing:
    step(10, "Cleanup: withdraw the test offer")
    status, _, body = call("POST", f"{API}/sell/inventory/v1/offer/{offer}/withdraw", user)
    print(f"   HTTP {status}")
print("\nDone." if listing else "\nPublish did not succeed; send me the output above (no secrets are printed).")
