"""Apply one migration file to Supabase via the Management API, as a single
transaction. Used only for the quiz dashboard migration; the file is written
to be safe to run more than once."""
import json, os, re, sys, urllib.request

ref, path = sys.argv[1], sys.argv[2]
m = re.search(r"sbp_[A-Za-z0-9_]+", os.environ.get("RAW_TOKEN", ""), re.I)
if not m:
    sys.exit("No sbp_ token in SUPABASE_ACCESS_TOKEN")
token = "sbp_" + m.group(0)[4:]

sql = "BEGIN;\n" + open(path).read() + "\nCOMMIT;"
req = urllib.request.Request(
    f"https://api.supabase.com/v1/projects/{ref}/database/query",
    data=json.dumps({"query": sql}).encode(),
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    method="POST")
try:
    urllib.request.urlopen(req, timeout=120).read()
except urllib.error.HTTPError as e:
    sys.exit("Migration failed, nothing was changed: " + e.read().decode()[:1000])
print(f"Applied {path}")
