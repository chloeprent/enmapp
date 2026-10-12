// ENM Style quiz: Kit email steps and polls for the quiz dashboard.
//
// Uses KIT_API_KEY (the key the quiz already uses for Kit).
//
//   discover  (service role only) tag names and counts, existing webhooks and
//             sequences. No subscriber details.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

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

async function kit(path: string, params: Record<string, string> = {}): Promise<any> {
  const key = Deno.env.get("KIT_API_KEY");
  if (!key) throw new Error("KIT_API_KEY is not set");
  const qs = new URLSearchParams(params).toString();
  const res = await fetch(`https://api.kit.com/v4${path}${qs ? `?${qs}` : ""}`, {
    headers: { "X-Kit-Api-Key": key, Accept: "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Kit ${path} ${res.status}: ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

// Walks a Kit cursor list.
async function kitList(path: string, key: string, params: Record<string, string> = {}, max = 2000) {
  const out: any[] = [];
  let after = "";
  while (out.length < max) {
    const r = await kit(path, { per_page: "500", ...params, ...(after ? { after } : {}) });
    out.push(...(r[key] || []));
    if (!r.pagination?.has_next_page) break;
    after = r.pagination.end_cursor;
  }
  return out;
}

async function discover() {
  const tags = await kitList("/tags", "tags");
  const counted = [];
  for (const t of tags) {
    const r = await kit(`/tags/${t.id}/subscribers`, { per_page: "1", include_total_count: "true" }).catch(() => null);
    counted.push({ id: t.id, name: t.name, created: String(t.created_at).slice(0, 10), subscribers: r?.pagination?.total_count ?? null });
  }
  const webhooks = await kitList("/webhooks", "webhooks").catch((e) => [{ error: String(e) }]);
  const sequences = await kitList("/sequences", "sequences").catch((e) => [{ error: String(e) }]);
  const fields = await kitList("/custom_fields", "custom_fields").catch((e) => [{ error: String(e) }]);
  return {
    tags: counted.sort((a, b) => a.name.localeCompare(b.name)),
    webhooks: webhooks.map((w: any) => ({ id: w.id, event: w.event, target: w.target_url ? new URL(w.target_url).pathname : w.error })),
    sequences: sequences.map((s: any) => ({ id: s.id, name: s.name, error: s.error })),
    custom_fields: fields.map((f: any) => ({ key: f.key, label: f.label, error: f.error })),
  };
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: any = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { /* not JSON */ }
  try {
    if (!(await isServiceRole(req))) return json({ error: "Not allowed" }, 401);
    if (body.action === "discover") return json(await discover());
    return json({ error: "Unknown request" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message) }, 500);
  }
});
