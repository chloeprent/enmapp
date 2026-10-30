// ENM Style quiz: Kit email steps, unsubscribes and poll answers for the quiz
// dashboard. Uses KIT_API_KEY (the key the quiz already uses for Kit).
//
//   Kit webhook  POST ?t=<QUIZ_KIT_WEBHOOK_TOKEN>&e=<event>[&tag=<name>]
//                with Kit's { subscriber: { email_address } } body. Saves the
//                first time each person reaches each step in quiz_kit_events.
//   setup        (service role only) creates the Kit webhooks this needs, once.
//                They only notify this function; nothing in Kit changes.
//   backfill     (service role only) loads who already has a poll tag.
//   discover     (service role only) tag names and counts, webhooks, sequences.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const SELF = "https://ohcdjvbveokyyilceenf.supabase.co/functions/v1/quiz-kit";
const RESULTS_SEQUENCE = 2856671;   // "ENM Quiz Result" (one email)
const NON_BUYER_SEQUENCE = 2863306; // "ENM Quiz - Non Buyer Follow Up"
const POLL_TAG = /^(stuck|webinar)-[a-z]+$/; // e.g. stuck-jealousy, webinar-agreements
const EVENTS = new Set(["results_sent", "nb_started", "nb_finished", "unsubscribed", "poll"]);

const db = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

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

async function kit(path: string, params: Record<string, string> = {}, init: RequestInit = {}): Promise<any> {
  const key = Deno.env.get("KIT_API_KEY");
  if (!key) throw new Error("KIT_API_KEY is not set");
  const qs = new URLSearchParams(params).toString();
  const res = await fetch(`https://api.kit.com/v4${path}${qs ? `?${qs}` : ""}`, {
    ...init,
    headers: { "X-Kit-Api-Key": key, Accept: "application/json", "Content-Type": "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Kit ${path} ${res.status}: ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

// Walks a Kit cursor list.
async function kitList(path: string, key: string, params: Record<string, string> = {}, max = 20000) {
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

async function save(rows: { email: string; event: string; detail?: string; at?: string }[]) {
  const clean = rows.filter((r) => r.email).map((r) => ({
    email: r.email.trim().toLowerCase(), event: r.event, detail: r.detail || "", at: r.at || new Date().toISOString(),
  }));
  if (!clean.length) return 0;
  // First time counts: existing rows are left as they are.
  const { error } = await db().from("quiz_kit_events")
    .upsert(clean, { onConflict: "email,event,detail", ignoreDuplicates: true });
  if (error) throw new Error(`quiz_kit_events: ${error.message}`);
  return clean.length;
}

// ── Webhooks this dashboard needs ──────────────────────────────────────────
async function wanted(token: string) {
  const url = (e: string, tag = "") =>
    `${SELF}?t=${encodeURIComponent(token)}&e=${e}${tag ? `&tag=${encodeURIComponent(tag)}` : ""}`;
  const list = [
    { target_url: url("results_sent"), event: { name: "subscriber.course_complete", sequence_id: RESULTS_SEQUENCE } },
    { target_url: url("nb_started"), event: { name: "subscriber.course_subscribe", sequence_id: NON_BUYER_SEQUENCE } },
    { target_url: url("nb_finished"), event: { name: "subscriber.course_complete", sequence_id: NON_BUYER_SEQUENCE } },
    { target_url: url("unsubscribed"), event: { name: "subscriber.subscriber_unsubscribe" } },
  ];
  const tags = (await kitList("/tags", "tags")).filter((t: any) => POLL_TAG.test(t.name));
  for (const t of tags) {
    list.push({ target_url: url("poll", t.name), event: { name: "subscriber.tag_add", tag_id: t.id } as any });
  }
  return { list, tags };
}

async function setup() {
  const token = Deno.env.get("QUIZ_KIT_WEBHOOK_TOKEN");
  if (!token) throw new Error("QUIZ_KIT_WEBHOOK_TOKEN is not set");
  const existing = new Set((await kitList("/webhooks", "webhooks")).map((w: any) => w.target_url));
  const { list } = await wanted(token);
  const created: string[] = [];
  for (const w of list) {
    if (existing.has(w.target_url)) continue;
    await kit("/webhooks", {}, { method: "POST", body: JSON.stringify(w) });
    created.push(`${w.event.name} ${new URL(w.target_url).searchParams.get("e")} ${new URL(w.target_url).searchParams.get("tag") || ""}`.trim());
  }
  return { webhooks_needed: list.length, created };
}

async function backfill() {
  const tags = (await kitList("/tags", "tags")).filter((t: any) => POLL_TAG.test(t.name));
  let saved = 0;
  const per: Record<string, number> = {};
  for (const t of tags) {
    const subs = await kitList(`/tags/${t.id}/subscribers`, "subscribers");
    per[t.name] = subs.length;
    saved += await save(subs.map((s: any) => ({
      email: s.email_address, event: "poll", detail: t.name, at: s.tagged_at || s.created_at,
    })));
  }
  return { poll_tags: per, rows_offered: saved };
}

// Past sequence members from Kit, so people who got the results email (or
// started the non-buyer emails) before these webhooks existed are counted.
// Only entries older than 30 minutes count as sent; the results sequence is a
// single email that goes out within minutes of joining.
async function history() {
  const out: Record<string, unknown> = {};
  const cutoff = Date.now() - 30 * 60 * 1000;
  for (const [seq, event] of [[RESULTS_SEQUENCE, "results_sent"], [NON_BUYER_SEQUENCE, "nb_started"]] as const) {
    let subs: any[] = [];
    try { subs = await kitList(`/sequences/${seq}/subscribers`, "subscribers"); }
    catch (e) { out[event] = { error: String((e as Error).message).slice(0, 200) }; continue; }
    const rows = subs
      .map((s: any) => ({ email: s.email_address, at: s.added_at || s.subscribed_at || s.created_at }))
      .filter((r) => r.email && r.at && Date.parse(r.at) < cutoff);
    await save(rows.map((r) => ({ ...r, event })));
    out[event] = { in_sequence: subs.length, saved_or_kept: rows.length,
      sample_fields: subs[0] ? Object.keys(subs[0]) : [] };
  }
  return out;
}

// Read-only: Kit's purchase tags and who got them recently (only test emails in full).
async function inspect() {
  const isTest = (e: string) => /chloeprent|cristinemata25|\+test|test\+|@swoon\.coach$/i.test(e);
  const tags = (await kitList("/tags", "tags")).filter((t: any) => /purchas|bought|buyer|paid/i.test(t.name));
  const out: Record<string, unknown> = {};
  for (const t of tags) {
    const subs = await kitList(`/tags/${t.id}/subscribers`, "subscribers");
    out[t.name] = { total: subs.length, recent: subs
      .filter((x: any) => Date.parse(x.tagged_at || x.created_at || 0) > Date.now() - 3 * 864e5)
      .map((x: any) => ({ at: x.tagged_at || x.created_at,
        email: isTest(x.email_address || "") ? x.email_address : `***@${(x.email_address || "").split("@")[1] || ""}` })) };
  }
  return out;
}

// Support lookup for one subscriber by the SHA-256 of their email: Kit state,
// tags with dates (no email or name returned).
async function lookup(hash: string) {
  const sha = async (t: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t))))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  const tags = await kitList("/tags", "tags");
  const hits: any[] = [];
  let subscriberId: number | null = null;
  for (const t of tags) {
    const subs = await kitList(`/tags/${t.id}/subscribers`, "subscribers", {}, 5000);
    for (const x of subs) {
      if (x.email_address && (await sha(x.email_address.trim().toLowerCase())) === hash) {
        hits.push({ tag: t.name, tagged_at: x.tagged_at || null, state: x.state || null });
        subscriberId = x.id;
      }
    }
  }
  return { found_in_kit: hits.length > 0, subscriber_id_known: !!subscriberId, tags: hits.sort((a, b) => String(a.tagged_at).localeCompare(String(b.tagged_at))) };
}

async function discover() {
  const webhooks = await kitList("/webhooks", "webhooks");
  return {
    webhooks: webhooks.map((w: any) => ({ event: w.event, e: new URL(w.target_url).searchParams.get("e"),
      tag: new URL(w.target_url).searchParams.get("tag"), ours: w.target_url.startsWith(SELF) })),
  };
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const url = new URL(req.url);
  const raw = await req.text();

  // Kit webhook
  if (url.searchParams.has("t")) {
    const token = Deno.env.get("QUIZ_KIT_WEBHOOK_TOKEN");
    if (!token || url.searchParams.get("t") !== token) return json({ error: "Not allowed" }, 401);
    const event = url.searchParams.get("e") || "";
    if (!EVENTS.has(event)) return json({ error: "Unknown event" }, 400);
    let body: any = {};
    try { body = JSON.parse(raw || "{}"); } catch { /* not JSON */ }
    const email = body?.subscriber?.email_address;
    if (!email) return json({ received: true, skipped: "no email" });
    try {
      await save([{ email, event, detail: event === "poll" ? url.searchParams.get("tag") || "" : "" }]);
      return json({ received: true });
    } catch (e) {
      console.error("kit webhook failed", e);
      return json({ error: "Processing failed" }, 500);
    }
  }

  // Admin tasks
  let body: any = {};
  try { body = JSON.parse(raw || "{}"); } catch { /* not JSON */ }
  try {
    if (!(await isServiceRole(req))) return json({ error: "Not allowed" }, 401);
    if (body.action === "setup") return json(await setup());
    if (body.action === "backfill") return json({ polls: await backfill(), sequences: await history() });
    if (body.action === "discover") return json(await discover());
    if (body.action === "inspect") return json(await inspect());
    if (body.action === "lookup") return json(/^[0-9a-f]{64}$/.test(body.hash || "") ? await lookup(body.hash) : { error: "hash required" });
    return json({ error: "Unknown request" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message) }, 500);
  }
});
