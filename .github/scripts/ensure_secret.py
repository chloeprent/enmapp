"""Make sure a random Supabase Edge Function secret exists (never prints it).
Used for the token that Kit webhooks must carry."""
import json, os, re, secrets, sys, urllib.request

ref, name = sys.argv[1], sys.argv[2]
m = re.search(r"sbp_[A-Za-z0-9_]+", os.environ.get("RAW_TOKEN", ""), re.I)
if not m:
    sys.exit("No sbp_ token in SUPABASE_ACCESS_TOKEN")
auth = {"Authorization": "Bearer sbp_" + m.group(0)[4:], "Content-Type": "application/json"}
base = f"https://api.supabase.com/v1/projects/{ref}/secrets"
names = {s["name"] for s in json.load(urllib.request.urlopen(urllib.request.Request(base, headers=auth), timeout=60))}
if name in names:
    print(f"{name}: already set")
else:
    body = json.dumps([{"name": name, "value": secrets.token_urlsafe(32)}]).encode()
    urllib.request.urlopen(urllib.request.Request(base, data=body, headers=auth, method="POST"), timeout=60).read()
    print(f"{name}: created")
