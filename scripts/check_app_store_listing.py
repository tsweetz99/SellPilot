#!/usr/bin/env python3
"""Checks Docs/AppStoreListing.md against App Store Connect's field limits."""
import re, sys, pathlib

limits = {"Name": 30, "Subtitle": 30, "Promotional text": 170, "Description": 4000, "Keywords": 100, "What's New": 4000}
text = (pathlib.Path(__file__).resolve().parent.parent / "Docs" / "AppStoreListing.md").read_text()
problems = []
for field, limit in limits.items():
    match = re.search(rf"### {re.escape(field)} \(limit {limit}\)\n```text\n(.*?)\n```", text, re.S)
    if not match:
        problems.append(f"{field}: block not found"); continue
    value = match.group(1)
    status = "ok" if len(value) <= limit else "TOO LONG"
    print(f"{field:18} {len(value):5} / {limit:<5} {status}")
    if len(value) > limit: problems.append(f"{field} is {len(value)} characters, limit {limit}")
    if field == "Keywords":
        if ", " in value: problems.append("Keywords: no spaces after commas (they waste characters)")
        name_words = set(re.findall(r"[a-z]+", re.search(r"### Name .*?```text\n(.*?)\n```", text, re.S).group(1).lower()))
        repeated = [w for w in value.lower().split(",") if w in name_words]
        if repeated: problems.append(f"Keywords repeat words already in the name: {repeated}")
        if "ebay" in value.lower(): problems.append("Keywords must not contain a trademark (eBay)")
for field in ("Name", "Subtitle", "Keywords"):
    block = re.search(rf"### {field} .*?```text\n(.*?)\n```", text, re.S)
    if block and "ebay" in block.group(1).lower(): problems.append(f"{field} must not contain a trademark (eBay)")
if "not affiliated with or endorsed by eBay" not in text: problems.append("Description lacks the eBay trademark disclaimer")
if problems:
    print("\nProblems:"); [print(" -", p) for p in problems]; sys.exit(1)
print("\nAll fields are within App Store Connect's limits.")
