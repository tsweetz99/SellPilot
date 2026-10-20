#!/usr/bin/env python3
"""Sends one photo to SellPilot's AI service and prints what came back.
Usage: python3 scripts/ai_check.py PHOTO.jpg [https://sellpilot-auth.netlify.app/api/ai]
Uses the system curl (this Mac's certificates) and macOS sips to shrink the photo. Prints no keys: the studio's Anthropic key
lives only on the server."""
import base64, json, os, subprocess, sys, tempfile, secrets

if len(sys.argv) < 2:
    sys.exit(__doc__)
photo = os.path.expanduser(sys.argv[1])
endpoint = sys.argv[2] if len(sys.argv) > 2 else "https://sellpilot-auth.netlify.app/api/ai"
with tempfile.TemporaryDirectory() as tmp:
    small = os.path.join(tmp, "small.jpg")
    subprocess.run(["sips", "-Z", "1280", "-s", "format", "jpeg", "-s", "formatOptions", "70", photo, "--out", small], check=True, capture_output=True)
    data = base64.b64encode(open(small, "rb").read()).decode()
    body = os.path.join(tmp, "body.json")
    json.dump({"task": "identify", "photos": [{"data": data}]}, open(body, "w"))
    out = subprocess.run(["curl", "-s", "-o", "-", "-w", "\n%{http_code}", "-X", "POST", endpoint, "-H", "content-type: application/json",
                          "-H", f"X-SellPilot-Install: {secrets.token_hex(16)}", "--data-binary", f"@{body}"], capture_output=True, text=True)
payload, _, status = out.stdout.rpartition("\n")
print(f"HTTP {status}  (photo sent: {len(data) // 1024} KB base64)")
try:
    parsed = json.loads(payload)
except ValueError:
    sys.exit(f"Unreadable reply: {payload[:200]}")
if status == "200":
    answer = parsed["content"][0]["input"]
    for key in ("title", "brand", "model", "category", "condition", "confidence"):
        print(f"  {key}: {answer.get(key)}")
else:
    print(f"  {parsed.get('error')}: {parsed.get('message')}")
