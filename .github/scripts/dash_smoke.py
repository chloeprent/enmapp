"""Dashboard smoke test. Calls every enm_dash_* function the dashboard uses,
as the signed-in admin would (role authenticated + the admin's email in the
JWT claims), and prints a short summary of each answer: numbers and list
sizes only, no personal data. Read-only: the functions only read."""
import json, os, re, sys, urllib.request
from datetime import datetime, timedelta, timezone

ref, admin = sys.argv[1], sys.argv[2]
m = re.search(r"sbp_[A-Za-z0-9_]+", os.environ.get("RAW_TOKEN", ""), re.I)
token = "sbp_" + m.group(0)[4:]
claims = json.dumps({"email": admin, "role": "authenticated"}).replace("'", "''")
launch = "2026-10-13T00:00:00+08:00"
to = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
R = f"'{launch}'::timestamptz, '{to}'::timestamptz"

def call(expr):
    q = (f"set local role authenticated; select set_config('request.jwt.claims', '{claims}', true); "
         f"select ({expr})::jsonb as r;")
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/database/query",
        data=json.dumps({"query": q}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}, method="POST")
    try:
        rows = json.load(urllib.request.urlopen(req, timeout=60))
        return rows[-1]["r"] if rows else None, None
    except urllib.error.HTTPError as e:
        return None, e.read().decode()[:300]

def brief(v, depth=0):
    if isinstance(v, dict):
        return {k: brief(x, depth + 1) for k, x in v.items()} if depth < 2 else f"{{{len(v)} keys}}"
    if isinstance(v, list):
        return f"[{len(v)} items]"
    if isinstance(v, str) and "@" in v:
        return "<email>"
    return v

checks = [
    ("Admin check", "to_jsonb(enm_is_quiz_admin())"),
    ("Overview (since launch, tests hidden)", f"enm_dash_overview({R}, true)"),
    ("Overview (since launch, tests shown)", f"enm_dash_overview({R}, false)"),
    ("Purchases (tests shown)", f"enm_dash_purchases({R}, false)"),
    ("Calls (tests shown)", f"enm_dash_calls({R}, false)"),
    ("Polls (tests shown)", f"enm_dash_polls({R}, false)"),
    ("People page 1 (tests shown)", f"enm_dash_people({R}, false, null, null, null, null, 50, 0, null, null)"),
    ("People who bought (tests shown)", f"enm_dash_people({R}, false, null, null, null, null, 50, 0, 'any', null)"),
    ("People needing attention", f"enm_dash_people({R}, true, null, null, null, null, 50, 0, null, 'attention')"),
    ("Person timeline (testenm81)", "enm_dash_person('chloeprent+testenm81@gmail.com')"),
    ("Feedback page 1", f"enm_dash_feedback({R}, false, null, null, 50, 0)"),
]
failed = 0
for title, expr in checks:
    r, err = call(expr)
    print(f"\n== {title}")
    if err:
        failed += 1; print("  ERROR:", err)
    else:
        print(" ", json.dumps(brief(r), indent=1)[:1500])
    if title == "Person timeline (testenm81)" and r:
        for t in (r.get("timeline") or [])[:20]:
            print("   -", t.get("at"), t.get("what"), (t.get("detail") or "")[:60] if isinstance(t.get("detail"), str) else "")
print(f"\n{len(checks) - failed} of {len(checks)} dashboard calls worked")
sys.exit(1 if failed else 0)
