"""Print the names (never the values) of the Supabase Edge Function secrets,
so we can see which keys are already set."""
import json, os, re, sys, urllib.request

ref = sys.argv[1]
m = re.search(r"sbp_[A-Za-z0-9_]+", os.environ.get("RAW_TOKEN", ""), re.I)
if not m:
    sys.exit("No sbp_ token in SUPABASE_ACCESS_TOKEN")
req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/secrets",
                             headers={"Authorization": "Bearer sbp_" + m.group(0)[4:]})
names = sorted(s["name"] for s in json.load(urllib.request.urlopen(req, timeout=60)))
print("Secret names:")
for n in names:
    print("  " + n)
