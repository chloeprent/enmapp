// ENM Style quiz: call bookings for the quiz dashboard.
//
// Reads bookings from TidyCal (TIDYCAL_API_KEY, the key the CRM sync already
// uses) and keeps one clean row per booking in quiz_calls. The CRM's own
// tidycal-sync is left untouched.
//
//   discover  (service role only) counts and field names, no personal data.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const TIDYCAL = "https://tidycal.com/api/bookings";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });

async function isServiceRole(req: Request): Promise<boolean> {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return false;
  if (token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return true;
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/admin/users?per_page=1`, {
    headers: { apikey: token, Authorization: `Bearer ${token}` },
  });
  await res.body?.cancel();
  return res.ok;
}

async function tidycal(params: Record<string, string>): Promise<any> {
  const key = Deno.env.get("TIDYCAL_API_KEY");
  if (!key) throw new Error("TIDYCAL_API_KEY is not set");
  const res = await fetch(`${TIDYCAL}?${new URLSearchParams(params)}`, {
    headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`TidyCal ${res.status}: ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

async function discover() {
  const first = await tidycal({});
  const withCancelled = await tidycal({ cancelled: "true" }).catch((e) => ({ error: String(e) }));
  const old = await tidycal({ starts_at: "2020-01-01T00:00:00Z" }).catch((e) => ({ error: String(e) }));
  const page2 = await tidycal({ page: "2" }).catch((e) => ({ error: String(e) }));
  const sample = (first.data || [])[0] || {};
  const summarise = (r: any) => {
    const d = r?.data || [];
    const created = d.map((b: any) => b.created_at).filter(Boolean).sort();
    const starts = d.map((b: any) => b.starts_at).filter(Boolean).sort();
    const types: Record<string, number> = {};
    for (const b of d) types[b.booking_type?.title || "?"] = (types[b.booking_type?.title || "?"] || 0) + 1;
    return {
      error: r?.error, count: d.length, cancelled: d.filter((b: any) => b.cancelled_at).length,
      with_email: d.filter((b: any) => b.contact?.email).length,
      created_first: created[0], created_last: created[created.length - 1],
      starts_first: starts[0], starts_last: starts[starts.length - 1], booking_types: types,
      top_level_keys: Object.keys(r || {}), meta: r?.meta && { ...r.meta, links: undefined }, links: r?.links,
    };
  };
  return {
    booking_fields: Object.keys(sample), contact_fields: Object.keys(sample.contact || {}),
    booking_type_fields: Object.keys(sample.booking_type || {}),
    default: summarise(first), cancelled_true: summarise(withCancelled),
    starts_at_2020: summarise(old), page_2: summarise(page2),
  };
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: any = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { /* not JSON */ }
  if (!(await isServiceRole(req))) return json({ error: "Not allowed" }, 401);
  try {
    if (body.action === "discover") return json(await discover());
    return json({ error: "Unknown request" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message) }, 500);
  }
});
