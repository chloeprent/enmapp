"""Print recent calls to one edge function (time, method, status, action hint).
Read-only, uses the Supabase access token. No request bodies are printed."""
import json, os, re, sys, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

ref, fn = sys.argv[1], sys.argv[2]
hours = int(sys.argv[3]) if len(sys.argv) > 3 else 24
m = re.search(r"sbp_[A-Za-z0-9_]+", os.environ.get("RAW_TOKEN", ""), re.I)
token = "sbp_" + m.group(0)[4:]
end = datetime.now(timezone.utc)
start = end - timedelta(hours=hours)
sql = f"""select timestamp, request.method, response.status_code, request.url
from function_edge_logs cross join unnest(metadata) as m cross join unnest(m.request) as request
cross join unnest(m.response) as response
where request.url like '%/{fn}%' order by timestamp desc limit 60"""
qs = urllib.parse.urlencode({"sql": sql, "iso_timestamp_start": start.isoformat(), "iso_timestamp_end": end.isoformat()})
req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/analytics/endpoints/logs.all?{qs}",
                             headers={"Authorization": f"Bearer {token}"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=60))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:300]}")
rows = data.get("result") or []
print(f"{len(rows)} calls to {fn} in the last {hours}h")
for r in rows:
    ts = datetime.fromtimestamp(int(r["timestamp"]) / 1e6, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    url = re.sub(r"([?&]t=)[^&]+", r"\1***", r.get("url") or "")
    print(ts, r.get("method"), r.get("status_code"), url.split("/functions/v1/")[-1][:60])
if data.get("error"):
    print("error:", json.dumps(data["error"])[:300])
