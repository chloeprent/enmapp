"""Run the SELECT-only queries in a .sql file against Supabase via the
Management API and print each result as a small table. Refuses anything
that is not a SELECT, so it cannot change data."""
import json, os, re, sys, urllib.request

ref, path = sys.argv[1], sys.argv[2]
raw = os.environ.get("RAW_TOKEN", "")
m = re.search(r"sbp_[A-Za-z0-9_]+", raw, re.I)
if not m:
    sys.exit("No sbp_ token in SUPABASE_ACCESS_TOKEN")
token = "sbp_" + m.group(0)[4:]

blocks = re.split(r"^-- == ", open(path).read(), flags=re.M)[1:]
for block in blocks:
    title, _, body = block.partition("\n")
    print(f"\n== {title.strip()}")
    for stmt in [q.strip() for q in body.split(";") if q.strip()]:
        stmt = "\n".join(l for l in stmt.splitlines() if not l.strip().startswith("--")).strip()
        if not stmt:
            continue
        if not re.match(r"(?is)^\s*select\b", stmt):
            print("  skipped (not a SELECT)"); continue
        req = urllib.request.Request(
            f"https://api.supabase.com/v1/projects/{ref}/database/query",
            data=json.dumps({"query": stmt}).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="POST")
        try:
            rows = json.load(urllib.request.urlopen(req, timeout=60))
        except urllib.error.HTTPError as e:
            print("  error:", e.read().decode()[:300]); continue
        if not rows:
            print("  (no rows)"); continue
        cols = list(rows[0].keys())
        print("  " + " | ".join(cols))
        for r in rows:
            print("  " + " | ".join(str(r.get(c)) for c in cols))
