"""Call a quiz edge function as the service role and print the JSON reply.
The service role key is fetched with the Supabase access token, masked in the
log, and never printed."""
import json, os, re, sys, urllib.request

ref, fn, payload = sys.argv[1], sys.argv[2], sys.argv[3]
m = re.search(r"sbp_[A-Za-z0-9_]+", os.environ.get("RAW_TOKEN", ""), re.I)
if not m:
    sys.exit("No sbp_ token in SUPABASE_ACCESS_TOKEN")
mgmt = "sbp_" + m.group(0)[4:]

req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/api-keys?reveal=true",
                             headers={"Authorization": f"Bearer {mgmt}"})
keys = json.load(urllib.request.urlopen(req, timeout=60))
print("Project key names:", ", ".join(f"{k.get('name')} ({k.get('type')})" for k in keys))
# Prefer a new-style secret key, fall back to the legacy service_role key.
service = next((k.get("api_key") for k in keys if k.get("type") == "secret" and k.get("api_key")), None) \
    or next((k.get("api_key") for k in keys if k.get("name") == "service_role"), None)
if not service:
    sys.exit("No service_role key found for the project")
print(f"::add-mask::{service}")

req = urllib.request.Request(f"https://{ref}.supabase.co/functions/v1/{fn}", data=payload.encode(),
                             headers={"Authorization": f"Bearer {service}", "Content-Type": "application/json"},
                             method="POST")
try:
    body = urllib.request.urlopen(req, timeout=300).read().decode()
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"HTTP {e.code}")
try:
    print(json.dumps(json.loads(body), indent=2))
except ValueError:
    print(body[:2000])
