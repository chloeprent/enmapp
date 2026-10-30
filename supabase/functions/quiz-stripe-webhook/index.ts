// ENM Style quiz: Stripe purchases for the quiz dashboard.
//
// Read-only towards Stripe: it uses STRIPE_API_KEY, a restricted key with read
// access only, and never creates, changes or refunds anything. Purchases are
// written to quiz_purchases with the service role.
//
//   Stripe webhook   checkout.session.completed / async_payment_succeeded save
//                    the paid line items; charge.refunded marks them refunded.
//                    Signed with QUIZ_STRIPE_WEBHOOK_SECRET.
//   backfill         (service role only) load every past paid checkout.
//   sync             reload checkouts from the last 2 days, in case a webhook
//                    was missed. Open to the cron job (counts only, at most
//                    once a minute).
//
// Checkouts paid with a 100% discount ($0) are kept as purchases with $0
// revenue, so tests and free copies show; test emails are hidden by the
// dashboard's Exclude tests. Anything before the launch is skipped
// (QUIZ_PURCHASES_FROM, default Tue 13 Oct 2026).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const STRIPE = "https://api.stripe.com/v1";
const PURCHASES_FROM = Date.parse(Deno.env.get("QUIZ_PURCHASES_FROM") || "2026-10-13T00:00:00Z");
const beforeLaunch = (session: any) => session.created * 1000 < PURCHASES_FROM;
// Stripe marks a fully discounted checkout "paid" or "no_payment_required".
const isPaid = (session: any) => session.status === "complete" &&
  (session.payment_status === "paid" || session.payment_status === "no_payment_required");

const db = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });

async function stripeGet(path: string, params: Record<string, string> = {}): Promise<any> {
  const key = Deno.env.get("STRIPE_API_KEY");
  if (!key) throw new Error("STRIPE_API_KEY is not set");
  const qs = new URLSearchParams(params).toString();
  const res = await fetch(`${STRIPE}${path}${qs ? `?${qs}` : ""}`, { headers: { Authorization: `Bearer ${key}` } });
  const body = await res.json();
  if (!res.ok) throw new Error(`Stripe ${path}: ${body?.error?.message || res.status}`);
  return body;
}

// Walks a Stripe list endpoint, newest first, up to `max` items.
async function stripeList(path: string, params: Record<string, string> = {}, max = 5000): Promise<any[]> {
  const out: any[] = [];
  let after = "";
  while (out.length < max) {
    const page = await stripeGet(path, { limit: "100", ...params, ...(after ? { starting_after: after } : {}) });
    out.push(...page.data);
    if (!page.has_more || !page.data.length) break;
    after = page.data[page.data.length - 1].id;
  }
  return out;
}

// Admin tasks need the project's service role (or secret) key. Asking Supabase
// Auth's admin API is the check, so it works whichever key format is in use.
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

// ── Stripe signature (https://stripe.com/docs/webhooks/signatures) ─────────
async function verifySignature(raw: string, header: string | null, secret: string): Promise<boolean> {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(",").map((p) => p.trim().split("=", 2)) as [string, string][]);
  const t = parts.t;
  const sigs = header.split(",").map((p) => p.trim()).filter((p) => p.startsWith("v1=")).map((p) => p.slice(3));
  if (!t || !sigs.length || Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${raw}`)));
  const expected = Array.from(mac).map((b) => b.toString(16).padStart(2, "0")).join("");
  return sigs.some((s) => s.length === expected.length &&
    [...s].reduce((d, c, i) => d | (c.charCodeAt(0) ^ expected.charCodeAt(i)), 0) === 0);
}

// ── Product mapping ────────────────────────────────────────────────────────
// Stripe names look like "Polyamory Roadmap", "Polyamory Bundle (3 Roadmaps)"
// and "7 Essential Conversations"; older ones are just the style name.
const STYLES: [string, string][] = [
  ["Still Exploring", "r_z1_KbCVyDt"], ["Open Relationship", "r_Q23t28UcGsm"],
  ["Polyamory", "r_zSSpoo1B8J"], ["Swinging / The Lifestyle", "r_a_57itxla3f"],
  ["Hotwife / Stag & Vixen", "r_twVl5hnSB3Y"], ["Cuckolding", "r_xGAqpa2lp0c"],
  ["Monogamish", "r_vBMS3JX76g"], ["Hierarchical Polyamory", "r_IlnWBruy-C"],
  ["Relationship Anarchy", "r_lsP7N-LvTv"], ["Solo Polyamory", "r_aPwM1WGTMl"],
  ["Mono/Poly", "r_wo9ZhTvshw"],
];
const squash = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

function classify(name: string): { kind: string; result_uid: string | null; label: string } {
  const n = squash(name);
  if (n.startsWith("7essentialconversations")) return { kind: "conversations", result_uid: null, label: "7 Essential Conversations" };
  // Longest style that starts the name, so "Solo Polyamory" wins over "Polyamory".
  const style = STYLES.filter(([t]) => n.startsWith(squash(t))).sort((a, b) => b[0].length - a[0].length)[0];
  if (!style) return { kind: "other", result_uid: null, label: name };
  const bundle = /bundle|3\s*roadmaps/i.test(name);
  return { kind: bundle ? "bundle" : "solo", result_uid: style[1], label: `${style[0]} ${bundle ? "Bundle" : "Roadmap"}` };
}

// Adds products we have not seen yet. Existing rows keep their mapping, so a
// manual correction in quiz_products is never overwritten; only names refresh.
async function syncProducts(products: any[]) {
  if (!products.length) return;
  const supabase = db();
  const { data: known } = await supabase.from("quiz_products").select("product_id")
    .in("product_id", products.map((p) => p.id));
  const have = new Set((known || []).map((k: any) => k.product_id));
  const fresh = products.filter((p) => !have.has(p.id))
    .map((p) => ({ product_id: p.id, name: p.name, ...classify(p.name) }));
  if (fresh.length) {
    const { error } = await supabase.from("quiz_products").insert(fresh);
    if (error) throw new Error(`quiz_products: ${error.message}`);
  }
  for (const p of products.filter((p) => have.has(p.id))) {
    await supabase.from("quiz_products").update({ name: p.name, updated_at: new Date().toISOString() }).eq("product_id", p.id);
  }
}

// ── Purchases ──────────────────────────────────────────────────────────────
const intentId = (pi: any) => (typeof pi === "string" ? pi : pi?.id) || null;

// Paid line items of one completed checkout, ready for quiz_purchases.
function rowsFor(session: any, lineItems: any[], source: "webhook" | "backfill", refunded = false) {
  if (!isPaid(session) || beforeLaunch(session)) return [];
  return lineItems.map((li) => ({
    id: `${session.id}:${li.id}`,
    session_id: session.id,
    payment_intent: intentId(session.payment_intent),
    email: (session.customer_details?.email || session.customer_email || "").toLowerCase() || null,
    name: session.customer_details?.name || null,
    product_id: typeof li.price?.product === "string" ? li.price.product : li.price?.product?.id || null,
    product_name: li.description || null,
    quantity: li.quantity || 1,
    amount_cents: li.amount_total || 0,
    currency: li.currency || session.currency,
    refunded,
    purchased_at: new Date(session.created * 1000).toISOString(),
    source,
    updated_at: new Date().toISOString(),
  }));
}

async function savePurchases(rows: any[]) {
  if (!rows.length) return;
  const productIds = [...new Set(rows.map((r) => r.product_id).filter(Boolean))];
  const { data: known } = await db().from("quiz_products").select("product_id").in("product_id", productIds);
  const have = new Set((known || []).map((k: any) => k.product_id));
  const missing = [];
  for (const id of productIds.filter((id) => !have.has(id))) missing.push(await stripeGet(`/products/${id}`));
  await syncProducts(missing);
  const { error } = await db().from("quiz_purchases").upsert(rows, { onConflict: "id" });
  if (error) throw new Error(`quiz_purchases: ${error.message}`);
}

async function backfill(sinceMs = PURCHASES_FROM) {
  const since = String(Math.floor(Math.max(sinceMs, PURCHASES_FROM) / 1000));
  const sessions = await stripeList("/checkout/sessions",
    { status: "complete", "created[gte]": since, "expand[]": "data.payment_intent.latest_charge" });
  // Checkouts already saved (usually by the webhook) are left as they are,
  // apart from a refund Stripe reports later.
  const { data: known } = await db().from("quiz_purchases").select("session_id")
    .in("session_id", sessions.map((s: any) => s.id));
  const have = new Set((known || []).map((k: any) => k.session_id));
  let paid = 0, free = 0, early = 0, saved = 0, refunded = 0, already = 0;
  for (const s of sessions) {
    if (!isPaid(s)) continue;
    if (beforeLaunch(s)) { early++; continue; }
    if (!s.amount_total) free++; else paid++;
    const charge = s.payment_intent?.latest_charge;
    const isRefunded = !!(charge && typeof charge === "object" && charge.refunded);
    if (isRefunded) refunded++;
    if (have.has(s.id)) {
      already++;
      if (isRefunded) await db().from("quiz_purchases").update({ refunded: true, updated_at: new Date().toISOString() })
        .eq("session_id", s.id).eq("refunded", false);
      continue;
    }
    const items = await stripeList(`/checkout/sessions/${s.id}/line_items`, {}, 100);
    const rows = rowsFor(s, items, "backfill", isRefunded);
    await savePurchases(rows);
    saved += rows.length;
  }
  return { checkouts_seen: sessions.length, paid_checkouts: paid, free_checkouts: free,
           skipped_before_launch: early, already_saved: already, rows_saved: saved, refunded };
}

let lastSync = 0;
async function sync() {
  if (Date.now() - lastSync < 60_000) return { skipped: "synced less than a minute ago" };
  lastSync = Date.now();
  return await backfill(Date.now() - 2 * 864e5);
}

// Read-only look at checkouts since launch, to explain why one is or is not on
// the dashboard. Only test emails are shown in full.
const isTest = (e: string) => /chloeprent|cristinemata25|\+test|test\+|@swoon\.coach$/i.test(e);
const mask = (e: string) => (!e ? "" : isTest(e) ? e : `***@${e.split("@")[1] || ""}`);

async function inspect() {
  const since = String(Math.floor(PURCHASES_FROM / 1000));
  const sessions = await stripeList("/checkout/sessions", { "created[gte]": since }, 300);
  const out = [];
  for (const s of sessions) {
    let items: any[] = [];
    try { items = await stripeList(`/checkout/sessions/${s.id}/line_items`, {}, 20); } catch { /* ignore */ }
    out.push({
      created: new Date(s.created * 1000).toISOString(), status: s.status, payment_status: s.payment_status,
      amount_total: s.amount_total, livemode: s.livemode, payment_link: s.payment_link || null,
      email: mask((s.customer_details?.email || s.customer_email || "").toLowerCase()),
      items: items.map((li) => `${li.description} x${li.quantity} = ${li.amount_total}`),
      would_save: rowsFor(s, items, "backfill").length,
    });
  }
  const { data: saved } = await db().from("quiz_purchases").select("purchased_at, email, product_name, amount_cents, source")
    .gte("purchased_at", new Date(PURCHASES_FROM).toISOString()).order("purchased_at");
  let events: unknown = null;
  try {
    const ev = await stripeGet("/events", { limit: "20", "created[gte]": since });
    events = ev.data.map((e: any) => ({ type: e.type, created: new Date(e.created * 1000).toISOString(),
      pending_webhooks: e.pending_webhooks }));
  } catch (e) { events = String((e as Error).message); }
  return { key_mode: (Deno.env.get("STRIPE_API_KEY") || "").slice(0, 8), checkouts_since_launch: out,
    saved_since_launch: (saved || []).map((r: any) => ({ ...r, email: mask(r.email || "") })), recent_events: events };
}

// Notes each webhook call in quiz_stripe_events. Never blocks the webhook.
async function note(eventId: string | null, type: string | null, result: string) {
  try { await db().from("quiz_stripe_events").insert({ event_id: eventId, type, result }); }
  catch (e) { console.error("note failed", e); }
}

// Support lookup for one customer, found by the SHA-256 of their email so the
// email itself never travels or prints. Returns dates, statuses, products and
// amounts only.
async function sha256(text: string) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(d).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function lookup(hash: string, days = 14) {
  const since = String(Math.floor((Date.now() - days * 864e5) / 1000));
  const sessions = await stripeList("/checkout/sessions", { "created[gte]": since }, 1000);
  const mine = [];
  for (const s of sessions) {
    const email = (s.customer_details?.email || s.customer_email || "").trim().toLowerCase();
    if (!email || (await sha256(email)) !== hash) continue;
    let items: any[] = [];
    try { items = await stripeList(`/checkout/sessions/${s.id}/line_items`, {}, 20); } catch { /* ignore */ }
    let pi: any = null;
    if (s.payment_intent) {
      try { pi = await stripeGet(`/payment_intents/${typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent.id}`); } catch { /* ignore */ }
    }
    mine.push({
      created: new Date(s.created * 1000).toISOString(), session_status: s.status, payment_status: s.payment_status,
      amount_total: s.amount_total, currency: s.currency, payment_link: s.payment_link || null,
      after_completion: s.after_completion?.type || null,
      redirect: s.after_completion?.redirect?.url ? new URL(s.after_completion.redirect.url).host + new URL(s.after_completion.redirect.url).pathname : null,
      items: items.map((li) => `${li.description} x${li.quantity} = ${li.amount_total}`),
      payment_intent_status: pi?.status || null, last_error: pi?.last_payment_error?.code || null,
      receipt_email_set: !!pi?.receipt_email,
    });
  }
  const { data: saved } = await db().from("quiz_purchases").select("session_id, email, product_name, amount_cents, purchased_at, source, refunded")
    .gte("purchased_at", new Date(Date.now() - days * 864e5).toISOString());
  const savedMine = [];
  for (const r of saved || []) if (r.email && (await sha256(r.email.trim().toLowerCase())) === hash)
    savedMine.push({ purchased_at: r.purchased_at, product: r.product_name, amount_cents: r.amount_cents, source: r.source, refunded: r.refunded });
  return { checkouts_seen_last_days: sessions.length, customer_checkouts: mine, saved_on_dashboard: savedMine };
}

async function handleEvent(event: any) {
  const obj = event.data?.object || {};
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      if (!isPaid(obj)) return "skipped (not paid yet)";
      if (beforeLaunch(obj)) return "skipped (before launch)";
      const items = await stripeList(`/checkout/sessions/${obj.id}/line_items`, {}, 100);
      const rows = rowsFor(obj, items, "webhook");
      await savePurchases(rows);
      return `saved ${rows.length}`;
    }
    case "charge.refunded": {
      if (!obj.refunded || !obj.payment_intent) return "partial refund, kept";
      const { error } = await db().from("quiz_purchases")
        .update({ refunded: true, updated_at: new Date().toISOString() })
        .eq("payment_intent", intentId(obj.payment_intent));
      if (error) throw new Error(error.message);
      return "marked refunded";
    }
    default:
      return "ignored";
  }
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const raw = await req.text();

  // Stripe webhook
  const signature = req.headers.get("Stripe-Signature");
  if (signature) {
    const secret = Deno.env.get("QUIZ_STRIPE_WEBHOOK_SECRET");
    if (!secret) return json({ error: "Webhook secret not set" }, 500);
    if (!(await verifySignature(raw, signature, secret))) {
      await note(null, null, "bad signature");
      return json({ error: "Bad signature" }, 400);
    }
    let event: any = {};
    try {
      event = JSON.parse(raw);
      const result = await handleEvent(event);
      console.log("stripe", event.type, event.id, result);
      await note(event.id, event.type, result);
      return json({ received: true, result });
    } catch (e) {
      console.error("stripe webhook failed", e);
      await note(event.id, event.type, `failed: ${String((e as Error).message).slice(0, 200)}`);
      return json({ error: "Processing failed" }, 500); // Stripe retries
    }
  }

  // Admin tasks
  let body: any = {};
  try { body = JSON.parse(raw || "{}"); } catch { /* not JSON */ }
  if (body.action === "sync") {
    try { return json(await sync()); } catch (e) { console.error("sync failed", e); return json({ error: "Sync failed" }, 500); }
  }
  if (body.action === "lookup") {
    if (!(await isServiceRole(req))) return json({ error: "Not allowed" }, 401);
    if (!/^[0-9a-f]{64}$/.test(body.hash || "")) return json({ error: "hash required" }, 400);
    try { return json(await lookup(body.hash)); } catch (e) { return json({ error: String((e as Error).message) }, 500); }
  }
  if (body.action === "inspect") {
    if (!(await isServiceRole(req))) return json({ error: "Not allowed" }, 401);
    try { return json(await inspect()); } catch (e) { return json({ error: String((e as Error).message) }, 500); }
  }
  if (body.action === "backfill") {
    if (!(await isServiceRole(req))) return json({ error: "Not allowed" }, 401);
    try { return json(await backfill()); } catch (e) { return json({ error: String((e as Error).message) }, 500); }
  }

  return json({ error: "Unknown request" }, 400);
});
